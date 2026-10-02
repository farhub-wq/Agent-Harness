#!/usr/bin/env bash
# auth-path job 的断言脚本：起一套栈，然后**从外面**按 HTTP 敲它。
#
#   bash deploy/ci/prepare-stack.sh     # 先造 deploy/.env / nginx.env / htpasswd
#   bash deploy/ci/smoke-edge.sh
#
# 它证明的是「同一件事抄在几个地方、改一处忘了另一处」这类问题的**运行时**那一半。
# 结构那一半在 src/test/test_static_config.py（纯读文件、不起栈）—— 两者都要：
# 结构断言能抓住"删了一行 header"，抓不住"proxy_pass 指到了错的端口"（语法正确、
# 结构完好、运行 502）。反过来，运行时断言不会告诉你"这个头是哪个文件里漏的"。
#
# 栈的形状：mongo + mock-erp + mcp + backend + frontend + nginx 全是真的，
# 只有 dind 与 sandbox-image-loader 是替身（见 deploy/ci/compose.ci.yml）。
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/ci/lib-ci.sh
. "$CI_DIR/lib-ci.sh"

CI_OVERRIDE="deploy/ci/compose.ci.yml"
CRED_FILE="$CI_REPO_ROOT/deploy/ci/.ci-credentials.sh"
NGINX_ENV="$CI_REPO_ROOT/deploy/nginx.env"

[ -f "$CRED_FILE" ] || ci_die "找不到 $CRED_FILE —— 先跑 bash deploy/ci/prepare-stack.sh"
# shellcheck source=/dev/null
. "$CRED_FILE"

BASE="${CI_BASE_URL:-http://127.0.0.1}"
AUTH=(-u "$CI_BASIC_USER:$CI_BASIC_PASSWORD")
FAILED=0

# 断言登记簿。每条都写出**它钉住的失效模式** —— 一个说不出失效模式的断言，
# 迟早会被人为了让 CI 变绿而删掉。
check_code() {
    local desc="$1" expect="$2" actual="$3"
    if [ "$expect" = "$actual" ]; then
        ci_info "ok    $desc → $actual"
    else
        ci_warn "FAIL  $desc → 期望 $expect，实际 $actual"
        FAILED=$((FAILED + 1))
    fi
}

# ---------------------------------------------------------------- 负向验证的收尾
# 负向验证会临时改 deploy/nginx.env。用 trap 兜住：断言中途炸了也要把文件还回去，
# 否则本机重跑时会带着一个错的令牌，第二次运行会以一种莫名其妙的方式红。
NGINX_ENV_BACKUP=""
restore_nginx_env() {
    [ -n "$NGINX_ENV_BACKUP" ] && [ -f "$NGINX_ENV_BACKUP" ] || return 0
    mv "$NGINX_ENV_BACKUP" "$NGINX_ENV"
    NGINX_ENV_BACKUP=""
    ci_compose up -d --no-build --force-recreate --no-deps nginx >/dev/null 2>&1 || true
    ci_warn "已还原 deploy/nginx.env 并重建 nginx"
}
trap restore_nginx_env EXIT

# ---------------------------------------------------------------- 起栈
ci_log "起栈（真 : mongo/mock-erp/mcp/backend/frontend/nginx ｜ 替身 : dind/loader）"
ci_up
if ! ci_wait_healthy 420; then
    ci_dump
    exit 1
fi

# ---------------------------------------------------------------- 探活（不认证）
ci_log "探活端点：必须免认证，且与认证层无关"
BODY="$(curl -sS --max-time 10 "$BASE/healthz" 2>/dev/null || true)"
if [ "$BODY" = "ok" ]; then
    ci_info "ok    GET /healthz（无凭据）→ 200 ok"
else
    ci_warn "FAIL  GET /healthz（无凭据）→ 期望 'ok'，实际 '$BODY'"
    FAILED=$((FAILED + 1))
fi

# 带**错误**凭据也必须是 200：auth_basic off 是关掉整个认证，不是"接受任何密码"。
# 这条同时证明云监控那种带缓存凭据的探针不会被认证挡住。
check_code "GET /healthz（错误凭据）" 200 \
    "$(ci_http_code -u "probe:wrong-password" "$BASE/healthz")"

check_code "GET /health（无凭据，nginx→backend→mongo）" 200 \
    "$(ci_http_code "$BASE/health")"

# ---------------------------------------------------------------- 认证边界
ci_log "认证边界：/ 与 /api/ 都不能漏 location"
check_code "GET /（带凭据）" 200 "$(ci_http_code "${AUTH[@]}" "$BASE/")"
check_code "GET /（无凭据）" 401 "$(ci_http_code "$BASE/")"
check_code "GET /api/history（无凭据）" 401 "$(ci_http_code "$BASE/api/history")"

# ---------------------------------------------------------------- 共享密钥链路
ci_log "共享密钥链路：nginx 注入 → backend 校验"
check_code "GET /api/history（带凭据，nginx 注入正确令牌）" 200 \
    "$(ci_http_code "${AUTH[@]}" "$BASE/api/history")"

# 客户端自己塞一个**错的** X-Internal-Auth 仍然是 200 —— 这证明 nginx 的
# proxy_set_header 是覆盖而不是透传。如果哪天有人把 proxy_set_header 改成
# $http_x_internal_auth 这类"尊重客户端"的写法，这条立刻红，而结构断言看不见。
check_code "GET /api/history（带凭据 + 客户端伪造内部令牌，应被 nginx 覆盖）" 200 \
    "$(ci_http_code "${AUTH[@]}" -H "X-Internal-Auth: forged-by-client" "$BASE/api/history")"

check_code "GET /api/history（带凭据 + 客户端伪造身份头，应被 nginx 覆盖）" 200 \
    "$(ci_http_code "${AUTH[@]}" -H "X-Authenticated-User: someone-else" "$BASE/api/history")"

# ---------------------------------------------------------------- 绕过 nginx
# 计划里的断言矩阵写了「带 Basic Auth、不带 X-Internal-Auth → 401」。**这一条
# 走 nginx 是不可能成立的**：nginx 的 proxy_set_header 无条件覆盖该头，客户端
# 带不带都一样，backend 永远收到正确的令牌。要真的验证"共享密钥在强制"，必须
# 绕过 nginx —— 这也正是这道校验防的那个场景（沙箱里模型生成的代码直连 backend，
# 自己填一个别人的用户名）。
#
# 用一个一次性容器挂在 edge 网络上模拟它：backend 与 dind 同网，沙箱容器能这么走。
ci_log "绕过 nginx 直连 backend（模拟沙箱代码伪造身份）"
NET="$(docker network ls --format '{{.Name}}' | grep -x "${CI_PROJECT}_edge" | head -1 || true)"
[ -n "$NET" ] || ci_die "找不到网络 ${CI_PROJECT}_edge —— 栈没起来？"
ci_info "探针网络：$NET"

# 复用 backend 自己那个镜像跑 python（它一定已在本地；不额外拉任何东西）。
# 两条请求只差一个头，所以 401/200 的差异只可能来自共享密钥校验。
DIRECT="$(docker run --rm --network "$NET" --entrypoint python \
    -e TOK="$CI_INTERNAL_TOKEN" erp-agent-app:local -c '
import os, urllib.request, urllib.error

def code(token):
    headers = {"X-Authenticated-User": "attacker-probe"}
    if token:
        headers["X-Internal-Auth"] = token
    req = urllib.request.Request("http://backend:8000/api/history", headers=headers)
    try:
        return urllib.request.urlopen(req, timeout=15).status
    except urllib.error.HTTPError as exc:
        return exc.code

print("no-token=%d with-token=%d" % (code(None), code(os.environ["TOK"])))
' 2>&1 || true)"
ci_info "直连探针结果：${DIRECT:-（无输出）}"

if printf '%s' "$DIRECT" | grep -q 'no-token=401 with-token=200'; then
    ci_info "ok    直连 backend：无令牌 401（伪造身份被拒），有令牌 200"
else
    ci_warn "FAIL  直连 backend 期望 'no-token=401 with-token=200'，实际 '${DIRECT:-（空）}'"
    ci_warn "      若 no-token=200：共享密钥根本没在 backend 侧强制（就是线上曾出现过的失效形态）"
    FAILED=$((FAILED + 1))
fi

# ---------------------------------------------------------------- 负向验证
# 故意让 nginx 与 backend 的令牌不一致，带正确凭据的 /api/history 必须变 401。
# 这是唯一能证明"密钥校验真的在跑"的断言 —— 上面那些 200 也可能来自"根本没校验"。
ci_log "负向验证：故意让两处令牌不一致，必须 401"
NGINX_ENV_BACKUP="$NGINX_ENV.smoke-backup"
cp -p "$NGINX_ENV" "$NGINX_ENV_BACKUP"
ci_set_var "$NGINX_ENV" INTERNAL_AUTH_TOKEN "$(openssl rand -hex 24)"
# env_file 在容器**创建**时注入，restart 不重读，所以必须 --force-recreate。
ci_compose up -d --no-build --force-recreate --no-deps nginx >/dev/null
ci_wait_healthy 120

check_code "GET /api/history（带凭据 + nginx/backend 令牌不一致）" 401 \
    "$(ci_http_code "${AUTH[@]}" "$BASE/api/history")"

restore_nginx_env
ci_wait_healthy 120
check_code "还原令牌后 GET /api/history（带凭据）" 200 \
    "$(ci_http_code "${AUTH[@]}" "$BASE/api/history")"

# ---------------------------------------------------------------- 结论
if [ "$FAILED" -eq 0 ]; then
    ci_log "edge 冒烟全部通过"
    exit 0
fi
ci_dump
ci_die "$FAILED 条断言失败" 1
