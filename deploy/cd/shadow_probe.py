#!/usr/bin/env python3
"""影子启动的断言集 —— 在**影子容器内部**跑，由 deploy/cd/lib.sh 的 cd_shadow() 调起。

影子容器用的是新镜像、接的是真实的 edge + data 网络、读的是真实的 deploy/.env，
但它**不接 sandbox 网络、不设 DOCKER_HOST、不挂 /var/run/docker.sock**。这是刻意的：
让它碰到 dind 就会触发 sandbox_manager.prune_orphans()，而那个函数启动时无条件删掉
所有 erp-sandbox-warm-*（见 README 的架构约束 B）—— 影子启动会把生产的预热池清空。

它验什么（方案 5.5）：
  1. /health 200                       进程能起、Mongo 连得上
  2. mcp:9000 可连                      依赖链在
  3. /api/history 带身份头 + 正确内部令牌 → 200
  4. 同一个请求去掉内部令牌 → 401       证明共享密钥校验**是开着的**
  5. 镜像内 src/skills 可读
  6. 一次真实的 LLM 调用                Key / 模型名 / LLM_BASE_URL 三者都真的可用

它**验不到**什么（必须说清楚，免得被当成全量验收）：
  - 沙箱执行链路（刻意不碰，见上）
  - SSE 长连接的稳定性
  - 真实流量下的行为
沙箱链路由换版后的冒烟 + 仓库里的集成测试覆盖。

只依赖标准库：影子容器里不一定装 curl，而 requests 有没有是 requirements.txt 说了算，
不该把探针的可用性建立在它上面。
"""
import json
import os
import socket
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("CD_SHADOW_BASE", "http://127.0.0.1:8000")
TOKEN = os.environ.get("INTERNAL_AUTH_TOKEN", "")
PROBE_USER = "shadow-probe"
RUN_LLM = os.environ.get("CD_SHADOW_LLM", "1") == "1"

failures = []


def ok(name, detail=""):
    print(f"    [OK]   {name}{('  ' + detail) if detail else ''}", flush=True)


def bad(name, detail=""):
    print(f"    [FAIL] {name}{('  ' + detail) if detail else ''}", flush=True)
    failures.append(name)


def http_get(path, headers=None, timeout=10):
    """返回 (status, body)。HTTP 错误也当结果返回，不抛。"""
    req = urllib.request.Request(BASE + path, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(4096).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read(1024).decode("utf-8", "replace")


# ---------------------------------------------------------------- 1. /health
try:
    code, body = http_get("/health")
    if code == 200:
        ok("/health 200", body[:80])
    else:
        bad("/health", f"期望 200，实际 {code}：{body[:120]}")
except Exception as e:  # noqa: BLE001 —— 探针要把任何异常都变成一条失败，不能崩
    bad("/health", f"{type(e).__name__}: {e}")

# ---------------------------------------------------------------- 2. mcp:9000
try:
    socket.create_connection(("mcp", 9000), 5).close()
    ok("mcp:9000 可连")
except Exception as e:  # noqa: BLE001
    bad("mcp:9000", f"{type(e).__name__}: {e}")

# ---------------------------------------------------------------- 3/4. 共享密钥
if not TOKEN:
    bad("内部令牌", "容器里 INTERNAL_AUTH_TOKEN 为空 —— 前置检查本该拦住这个")
else:
    hdr = {"X-Authenticated-User": PROBE_USER, "X-Internal-Auth": TOKEN}
    try:
        code, body = http_get("/api/history", hdr, timeout=15)
        if code == 200:
            ok("/api/history 带正确令牌 200", body[:80])
        else:
            bad("/api/history（正确令牌）", f"期望 200，实际 {code}：{body[:160]}")
    except Exception as e:  # noqa: BLE001
        bad("/api/history（正确令牌）", f"{type(e).__name__}: {e}")

    # 负向：这一条才是真正钉住"共享密钥校验生效"的断言。如果去掉令牌仍然 200，
    # 说明 backend 根本没在校验 —— 那正是线上曾经出现过的失效形态。
    try:
        code, _ = http_get("/api/history", {"X-Authenticated-User": PROBE_USER}, timeout=15)
        if code == 401:
            ok("去掉内部令牌 → 401（校验确实生效）")
        else:
            bad("/api/history（缺令牌）", f"期望 401，实际 {code} —— 共享密钥校验没生效")
    except Exception as e:  # noqa: BLE001
        bad("/api/history（缺令牌）", f"{type(e).__name__}: {e}")

# ---------------------------------------------------------------- 5. src/skills
try:
    names = os.listdir("/app/src/skills")
    if names:
        ok("镜像内 src/skills 可读", f"{len(names)} 项")
    else:
        bad("src/skills", "目录存在但是空的")
except Exception as e:  # noqa: BLE001
    bad("src/skills", f"{type(e).__name__}: {e}")


# ---------------------------------------------------------------- 6. 真实 LLM 调用
def llm_probe():
    """直接打 LLM_BASE_URL —— 不比走 agent 链路差，反而更精确地定位到
    「Key 无效 / 模型名不存在 / base_url 不可达」这三件事中的哪一件。"""
    sys.path.insert(0, "/app")
    from src.agent.config import LLM_API_KEY, LLM_BASE_URL, LLM_MODEL  # noqa: PLC0415

    if not LLM_API_KEY:
        return False, "DEEPSEEK_API_KEY 为空"
    url = LLM_BASE_URL.rstrip("/") + "/chat/completions"
    payload = json.dumps({
        "model": LLM_MODEL,
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 1,
        "stream": False,
    }).encode()
    req = urllib.request.Request(url, data=payload, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {LLM_API_KEY}",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            r.read(2048)
        return True, f"{LLM_MODEL} @ {LLM_BASE_URL}"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}: {e.read(400).decode('utf-8', 'replace')}"
    except Exception as e:  # noqa: BLE001
        return False, f"{type(e).__name__}: {e}"


if RUN_LLM:
    last = ""
    for attempt in (1, 2):
        good, last = llm_probe()
        if good:
            ok("真实 LLM 调用成功", last)
            break
        if attempt == 1:
            print(f"    ... LLM 第 1 次失败（{last}），重试一次", flush=True)
    else:
        bad("真实 LLM 调用", f"{last}（确认这是持续故障而不是一次网络抖动；"
                             f"确实无法从这里调 LLM 时可在闸门上设 CD_SHADOW_LLM=0 降级）")
else:
    print("    [SKIP] 真实 LLM 调用（CD_SHADOW_LLM=0）", flush=True)

# ----------------------------------------------------------------
if failures:
    print(f"\n影子启动失败：{len(failures)} 项 —— {', '.join(failures)}", flush=True)
    sys.exit(1)
print("\n影子启动全部通过", flush=True)
