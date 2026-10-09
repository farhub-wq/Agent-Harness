"""
沙箱创建 + 安全防护 + 多语言运行时初始化

Harness 核心思想：
1. 文件系统只读 (--read-only) + tmpfs 可写区域
2. 内存/CPU 资源限制
3. 网络隔离 (--network none 或受限网络)
4. Linux Capability 全部移除
5. seccomp 系统调用白名单
6. 可扩展多语言运行时（Python / Go / Node.js）

沙箱由 SandboxManager 统一管理，不直接暴露给 Agent。
"""
from dataclasses import dataclass, field
from pathlib import Path

import docker
from docker.types import Mount

from ..config import (
    ALLOW_LOCAL_SHELL_FALLBACK,
    SANDBOX_EXECUTE_TIMEOUT_SECONDS,
    SANDBOX_IMAGE,
    SANDBOX_WORK_DIR,
)
from ..log_utils import sandbox_logger
from .custom_opensandbox import CustomOpenSandbox
from .docker_client import get_docker_client

# 项目根目录（用于定位本地文件同步到沙箱）
PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent

# 第三方依赖安装目录（``PIP_TARGET`` / ``PYTHONPATH``）。
#
# 必须挂在一个独立 volume 上，不能放在 tmpfs 里：Docker Desktop 与 dind 都会
# 把容器内的 tmpfs 强制挂成 noexec（即使显式请求 ``exec`` 也一样），而
# numpy / matplotlib 这类包的 ``.so`` 需要可执行映射，落在 tmpfs 上会以
# ``failed to map segment from shared object`` 加载失败 —— pip 装得进去，
# import 就炸。volume 落在 daemon 的真实文件系统上，不受此限制。
#
# 用匿名 volume（``Mount`` 不带 source）而不是具名 volume，是为了让
# ``container.remove(v=True)`` 在删容器时顺带回收它，不必再维护一套
# 「容器名 → volume 名」的映射。
SANDBOX_PACKAGE_DIR = "/workspace/python-packages"

# 传输中转目录（``upload_files`` / ``upload_directory`` 的落地点）。
#
# 只读 rootfs 下 Docker daemon 会拒绝 archive 接口往**任何 tmpfs** 上写：
#     PUT /containers/{id}/archive?path=/tmp
#     → 500 "container rootfs is marked read-only"
# 实测（erp-verify/v13_put_archive.py）：/tmp、/workspace、/skills 三个 tmpfs
# 全部 400，只有 volume 上的路径能写成功；把 read_only 关掉后 /tmp 就能写，
# 说明判定依据是 ReadonlyRootfs，与目标目录是否可写无关。
#
# 所以凡是走 Docker archive API 的上传都必须落在 volume 上（exec 写文件不受
# 影响，任何可写目录都行）。
SANDBOX_TRANSFER_DIR = "/workspace/.transfer"


# ============================================================
# 沙箱配置数据类
# ============================================================

@dataclass
class SandboxConfig:
    """沙箱创建配置（可扩展）"""

    # --- 基础 ---
    image: str = SANDBOX_IMAGE
    name: str = "erp-sandbox"
    work_dir: str = SANDBOX_WORK_DIR

    # --- 安全防护 ---
    read_only: bool = True
    memory_limit: str = "512m"
    cpu_limit: float = 1.0
    network_mode: str = "bridge"          # "none" = 完全隔离, "bridge" = 受限
    tmpfs_size: str = "512m"
    drop_all_caps: bool = True
    use_seccomp: bool = True
    seccomp_path: str = ""                # 空则使用内置 seccomp.json

    # --- 多语言运行时 ---
    # 指定需要安装的运行时列表: ["python", "go", "node"]
    runtimes: list[str] = field(default_factory=lambda: ["python"])

    # --- 环境变量注入 ---
    env_vars: dict[str, str] = field(default_factory=dict)

    # --- /etc/hosts 注入 ---
    # 沙箱容器跑在 dind 自己的 bridge 网络里，解析不了 compose 的服务名。
    # 需要在沙箱内按名字访问某个 compose 服务时，在这里写死 name → IP。
    extra_hosts: dict[str, str] = field(default_factory=dict)


# ============================================================
# 内置 seccomp 路径
# ============================================================

_BUILTIN_SECCOMP = str(Path(__file__).parent / "seccomp.json")


# ============================================================
# tmpfs 配额
# ============================================================

# tmpfs 的页**计入容器的 memory cgroup**，所以几个 tmpfs 的 size 之和必须明显
# 小于 mem_limit —— 差值是留给容器内进程（Python 解释器、pip、matplotlib）本身
# 的内存。默认配置里 /tmp 512m + /workspace 1g + /skills 256m = 1.75g，而
# mem_limit 只有 512m，于是 Agent 往 /workspace 写一个几百 MB 的导出文件时，
# 触发的不是干净的 ENOSPC（磁盘满），而是整个容器被 OOM killer 杀掉：本轮所有
# 中间结果全丢，还会连锁触发 SandboxHealthMiddleware 重建容器。
#
# 所以这里不硬编码尺寸，而是按 mem_limit 推导并等比缩放，保证不变量成立 ——
# 无论调用方把 mem_limit 配成多少，都不可能配出一个"写自己的 tmpfs 就把自己
# 写死"的容器。
# 0.5：留一半给进程。matplotlib + numpy + pandas 常驻 RSS 在 200MB 量级，
# 512m 的 mem_limit 下如果没有这一半空档，正常绘图任务自己就会顶到上限。
_TMPFS_BUDGET_RATIO = 0.5

# 期望配额（未超预算时原样使用）。打包进 tmpfs 的中间产物是图表 PNG、CSV、
# HTML/Markdown 报告这类，1g 的 /workspace 是够的。
_TMPFS_DESIRED = (
    ("/tmp", 512 * 1024 * 1024),
    ("/workspace", 1024 * 1024 * 1024),
    ("/skills", 256 * 1024 * 1024),
)

_SIZE_SUFFIXES = {"": 1, "b": 1, "k": 1024, "m": 1024**2, "g": 1024**3}


def _parse_size(value: str | int) -> int:
    """把 Docker 风格的尺寸串（"512m" / "1g" / 逗号分隔的字节数）解析成字节。"""
    if isinstance(value, int):
        return value
    text = str(value).strip().lower().replace(",", "")
    for suffix, factor in sorted(_SIZE_SUFFIXES.items(), key=lambda kv: -len(kv[0])):
        if suffix and text.endswith(suffix):
            return int(float(text[: -len(suffix)]) * factor)
    return int(float(text))


def _human(num_bytes: int) -> str:
    for unit, factor in (("g", 1024**3), ("m", 1024**2), ("k", 1024)):
        if num_bytes >= factor and num_bytes % factor == 0:
            return f"{num_bytes // factor}{unit}"
    return str(num_bytes)


def build_tmpfs_spec(memory_limit: str | int, tmp_size: str | int) -> dict[str, str]:
    """按 mem_limit 推导各个 tmpfs 的挂载参数。

    ``/tmp`` 用调用方给的 ``tmp_size``，``/workspace`` 与 ``/skills`` 用
    :data:`_TMPFS_DESIRED`；三者之和超过 ``mem_limit * _TMPFS_BUDGET_RATIO``
    时等比缩放，并记一条 warning —— 缩放在"用户配了个小 mem_limit"时是静默
    的容量变化，必须能从日志里看出来。
    """
    desired = {"/tmp": _parse_size(tmp_size)}
    for path, size in _TMPFS_DESIRED:
        desired.setdefault(path, size)

    budget = int(_parse_size(memory_limit) * _TMPFS_BUDGET_RATIO)
    total = sum(desired.values())
    if total > budget:
        scale = budget / total
        desired = {path: max(16 * 1024 * 1024, int(size * scale)) for path, size in desired.items()}
        sandbox_logger.warning(
            f"tmpfs quota {_human(total)} exceeds {_TMPFS_BUDGET_RATIO:.0%} of "
            f"mem_limit {memory_limit}; scaled to {_human(sum(desired.values()))} "
            f"({', '.join(f'{p}={_human(s)}' for p, s in desired.items())}) — "
            "tmpfs pages count against the container cgroup, so the sum must stay "
            "below mem_limit or a large write OOM-kills the sandbox"
        )

    # 除 /skills 外都保持 noexec：/skills 只放文本文件，不需要 exec 位。
    # noexec 是被 daemon 强制的（见 SANDBOX_PACKAGE_DIR 注释），这里写出来是为了
    # 让配置本身自解释。
    return {
        "/tmp": f"rw,noexec,nosuid,size={desired['/tmp']}",
        "/workspace": f"rw,noexec,nosuid,size={desired['/workspace']}",
        "/skills": f"rw,nosuid,nodev,size={desired['/skills']}",
    }


# ============================================================
# 安全沙箱创建（Docker SDK）
# ============================================================

def create_secure_sandbox(config: SandboxConfig | None = None) -> CustomOpenSandbox:
    """
    创建安全加固的 Docker 沙箱容器

    七层安全防护：
    1. --read-only           文件系统只读
    2. --tmpfs /tmp          可写区域限制大小
    3. --memory / --cpus     资源上限
    4. --network none        网络隔离（或受限）
    5. --cap-drop ALL        移除所有 Linux Capability
    6. --security-opt seccomp  系统调用白名单
    7. --pids-limit          进程数上限

    Returns:
        CustomOpenSandbox 实例（已连接到新建容器）
    """
    if config is None:
        config = SandboxConfig()

    seccomp_path = config.seccomp_path or _BUILTIN_SECCOMP
    seccomp_profile = None
    if config.use_seccomp and Path(seccomp_path).exists():
        with open(seccomp_path, "r") as f:
            seccomp_profile = f.read()

    client = get_docker_client()

    # 检查容器是否已存在，存在则先移除
    try:
        existing = client.containers.get(config.name)
        sandbox_logger.info(f"Removing existing container: {config.name}")
        existing.stop(timeout=3)
        # v=True 一并回收依赖目录的匿名 volume，否则同名容器重建会漏 volume
        existing.remove(force=True, v=True)
    except docker.errors.NotFound:
        pass

    # 构建安全参数
    host_config_kwargs = {
        "read_only": config.read_only,
        "mem_limit": config.memory_limit,
        "nano_cpus": int(config.cpu_limit * 1e9),
        "pids_limit": 256,
        # 配额按 mem_limit 推导，避免"写自己的 tmpfs 把容器写 OOM"（见
        # build_tmpfs_spec）。/workspace 放图表、CSV 等中间产物，第三方依赖不走
        # 这里（见 SANDBOX_PACKAGE_DIR）；/skills 是因为 --read-only 会让根目录下
        # 的 /skills 不可写，Skills 同步与用户 Skills 恢复必须有独立可写挂载点。
        "tmpfs": build_tmpfs_spec(config.memory_limit, config.tmpfs_size),
        # 依赖目录单独挂匿名 volume：tmpfs 被 daemon 强制 noexec，
        # 编译型扩展模块在那里无法 dlopen（详见 SANDBOX_PACKAGE_DIR 注释）。
        # 传输目录同理必须是 volume：只读 rootfs 下 archive API 写不进 tmpfs
        # （详见 SANDBOX_TRANSFER_DIR 注释）。
        "mounts": [
            Mount(target=SANDBOX_PACKAGE_DIR, source="", type="volume"),
            Mount(target=SANDBOX_TRANSFER_DIR, source="", type="volume"),
        ],
    }

    # 网络模式
    if config.network_mode == "none":
        host_config_kwargs["network_mode"] = "none"
    else:
        host_config_kwargs["network_mode"] = config.network_mode

    # /etc/hosts 注入（沙箱内按名字访问 compose 服务，见 SANDBOX_MCP_* 配置）
    if config.extra_hosts:
        host_config_kwargs["extra_hosts"] = dict(config.extra_hosts)

    # Capability 安全
    if config.drop_all_caps:
        host_config_kwargs["cap_drop"] = ["ALL"]
        # 仅添加运行必需的最小 Capability
        host_config_kwargs["cap_add"] = ["CHOWN", "SETUID", "SETGID", "DAC_OVERRIDE"]

    # seccomp 安全策略
    security_opts = []
    if seccomp_profile:
        # daemon 期望 seccomp= 后跟 profile 的 JSON 内容，不是文件路径
        security_opts.append(f"seccomp={seccomp_profile}")
    security_opts.append("no-new-privileges:true")
    host_config_kwargs["security_opt"] = security_opts

    # 环境变量
    environment = {
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONUNBUFFERED": "1",
        # 根文件系统保持只读时，第三方依赖安装到工作区而非 /usr/local。
        "PIP_TARGET": SANDBOX_PACKAGE_DIR,
        "PYTHONPATH": SANDBOX_PACKAGE_DIR,
        # 默认的 ~/.config/matplotlib 落在只读根文件系统上，import matplotlib
        # 每次都会警告 "mkdir -p failed ... Read-only file system" 再退回 /tmp。
        # 直接指到可写的 tmpfs，省掉这次失败尝试和噪音日志。
        "MPLCONFIGDIR": "/tmp/matplotlib",
    }
    environment.update(config.env_vars)

    try:
        sandbox_logger.info(
            f"Creating secure sandbox: {config.name} "
            f"(image={config.image}, memory={config.memory_limit}, "
            f"cpu={config.cpu_limit}, network={config.network_mode})"
        )

        container = client.containers.run(
            image=config.image,
            name=config.name,
            command="sleep infinity",
            detach=True,
            working_dir=config.work_dir,
            environment=environment,
            **host_config_kwargs,
        )

        sandbox_logger.info(
            f"Secure sandbox created: {config.name} ({container.id[:12]})"
        )

    except Exception as e:
        if not ALLOW_LOCAL_SHELL_FALLBACK:
            # 基础模式丢掉 read_only / cap_drop / seccomp / 资源限制，
            # 等于把无隔离容器交给模型生成的代码。容器部署宁可直接失败，
            # 让 HealthMiddleware 走重建，也不要静默降级。
            sandbox_logger.error(
                f"Secure sandbox creation failed ({e}); basic-mode fallback "
                f"disabled (ALLOW_LOCAL_SHELL_FALLBACK=false)"
            )
            raise

        # 安全创建失败时，回退到基础模式
        sandbox_logger.warning(
            f"Secure sandbox creation failed ({e}), falling back to basic mode"
        )
        try:
            existing = client.containers.get(config.name)
            existing.stop(timeout=3)
            existing.remove(force=True, v=True)
        except docker.errors.NotFound:
            pass

        container = client.containers.run(
            image=config.image,
            name=config.name,
            command="sleep infinity",
            detach=True,
            working_dir=config.work_dir,
            environment=environment,
        )
        sandbox_logger.info(
            f"Basic sandbox created (fallback): {config.name} ({container.id[:12]})"
        )

    # client 是进程级共享的，不在这里关闭（见 docker_client 模块）。

    # 创建 CustomOpenSandbox 实例连接到新容器。
    # 显式给默认超时：SDK 的 DEFAULT_EXECUTE_TIMEOUT 是 120s，而这个默认值在
    # execute() 学会真正使用 timeout 之前一直是空转的，现在会真的下发到容器内的
    # timeout(1)。本项目 AGENTS.md 明确要求脚本开头 `pip install -q mcp`，加上
    # 按需装 matplotlib/numpy，120s 在慢网络下会被直接 SIGTERM，模型看到的是
    # exit 124 而不知道是自己超时。见 config.SANDBOX_EXECUTE_TIMEOUT_SECONDS。
    sandbox = CustomOpenSandbox(
        container_name=config.name,
        timeout=SANDBOX_EXECUTE_TIMEOUT_SECONDS,
    )

    # 初始化运行时环境
    _init_runtimes(sandbox, config.runtimes)

    return sandbox


# ============================================================
# 多语言运行时初始化
# ============================================================

def _init_runtimes(sandbox: CustomOpenSandbox, runtimes: list[str]):
    """
    根据配置初始化多语言运行时

    支持的运行时：
    - python: 预装在 python:3.11-slim 镜像中
    - go:     通过二进制包安装（轻量）
    - node:   通过 NodeSource 安装
    - java:   通过 OpenJDK 安装
    - rust:   通过 rustup 安装
    """
    for runtime in runtimes:
        try:
            if runtime == "python":
                _init_python_runtime(sandbox)
            elif runtime == "go":
                _init_go_runtime(sandbox)
            elif runtime == "node":
                _init_node_runtime(sandbox)
            elif runtime == "java":
                _init_java_runtime(sandbox)
            elif runtime == "rust":
                _init_rust_runtime(sandbox)
            else:
                sandbox_logger.warning(f"Unknown runtime: {runtime}")
        except Exception as e:
            sandbox_logger.error(f"Failed to init runtime '{runtime}': {e}")


def _init_python_runtime(sandbox: CustomOpenSandbox):
    """初始化 Python 运行时（预装常用包）"""
    resp = sandbox.execute("python3 --version")
    if resp.exit_code == 0:
        sandbox_logger.info(f"Python runtime: {resp.output.strip()}")
    else:
        sandbox_logger.warning("Python not available in sandbox")

    # 预装镜像（erp-sandbox:3.11，见 deploy/sandbox/Dockerfile）已自带这三个包；
    # 只有裸 python:3.11-slim 才需要现装（实测冷装 matplotlib+pandas+numpy 要
    # 2 分 24 秒，网络波动下更久）。先探测再装，别让每次冷建容器都白等一遍。
    check = sandbox.execute(
        "python3 -c 'import matplotlib, pandas, numpy' "
        "2>/dev/null && echo INSTALLED || echo MISSING",
        timeout=30,
    )
    if "INSTALLED" in check.output:
        sandbox_logger.info("Python packages already present (prebuilt sandbox image)")
        return

    resp = sandbox.execute(
        f"mkdir -p {SANDBOX_PACKAGE_DIR} && "
        f"python3 -m pip install --no-cache-dir --target {SANDBOX_PACKAGE_DIR} "
        "matplotlib pandas numpy -q 2>&1 | tail -5",
        timeout=900,
    )
    if resp.exit_code == 0:
        sandbox_logger.info("Python packages installed: matplotlib, pandas, numpy")
    else:
        sandbox_logger.warning(
            f"Python packages install failed (exit {resp.exit_code}): "
            f"{resp.output[:200]}. Chart generation will need on-demand install."
        )


def _init_go_runtime(sandbox: CustomOpenSandbox):
    """安装 Go 运行时"""
    resp = sandbox.execute("go version 2>/dev/null || echo NOT_INSTALLED")
    if "NOT_INSTALLED" not in resp.output:
        sandbox_logger.info(f"Go runtime: {resp.output.strip()}")
        return

    sandbox_logger.info("Installing Go runtime...")
    resp = sandbox.execute(
        "wget -q https://go.dev/dl/go1.22.4.linux-amd64.tar.gz -O /tmp/go.tar.gz "
        "&& tar -C /usr/local -xzf /tmp/go.tar.gz "
        "&& rm /tmp/go.tar.gz "
        "&& export PATH=$PATH:/usr/local/go/bin "
        "&& go version",
        timeout=600,
    )
    if resp.exit_code == 0:
        sandbox_logger.info(f"Go installed: {resp.output.strip()}")
    else:
        sandbox_logger.warning(f"Go install failed: {resp.output}")


def _init_node_runtime(sandbox: CustomOpenSandbox):
    """安装 Node.js 运行时"""
    resp = sandbox.execute("node --version 2>/dev/null || echo NOT_INSTALLED")
    if "NOT_INSTALLED" not in resp.output:
        sandbox_logger.info(f"Node runtime: {resp.output.strip()}")
        return

    sandbox_logger.info("Installing Node.js runtime...")
    resp = sandbox.execute(
        "apt-get update -qq && apt-get install -y -qq nodejs npm 2>&1 | tail -3 "
        "&& node --version",
        timeout=600,
    )
    if resp.exit_code == 0:
        sandbox_logger.info(f"Node installed: {resp.output.strip()}")
    else:
        sandbox_logger.warning(f"Node install failed: {resp.output}")


def _init_java_runtime(sandbox: CustomOpenSandbox):
    """安装 Java (OpenJDK) 运行时"""
    resp = sandbox.execute("java --version 2>/dev/null || echo NOT_INSTALLED")
    if "NOT_INSTALLED" not in resp.output:
        sandbox_logger.info(f"Java runtime: {resp.output.strip()}")
        return

    sandbox_logger.info("Installing Java runtime...")
    resp = sandbox.execute(
        "apt-get update -qq && apt-get install -y -qq default-jdk-headless 2>&1 | tail -3 "
        "&& java --version",
        timeout=600,
    )
    if resp.exit_code == 0:
        sandbox_logger.info(f"Java installed: {resp.output.strip()}")


def _init_rust_runtime(sandbox: CustomOpenSandbox):
    """安装 Rust 运行时"""
    resp = sandbox.execute("rustc --version 2>/dev/null || echo NOT_INSTALLED")
    if "NOT_INSTALLED" not in resp.output:
        sandbox_logger.info(f"Rust runtime: {resp.output.strip()}")
        return

    sandbox_logger.info("Installing Rust runtime...")
    resp = sandbox.execute(
        "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | tail -5 "
        "&& source $HOME/.cargo/env && rustc --version",
        timeout=600,
    )
    if resp.exit_code == 0:
        sandbox_logger.info(f"Rust installed: {resp.output.strip()}")


# ============================================================
# 向后兼容的便捷函数
# ============================================================

def create_and_setup_sandbox(
    user_id: str = "default",
    runtimes: list[str] | None = None,
) -> CustomOpenSandbox:
    """
    创建沙箱并初始化环境（向后兼容接口）

    Args:
        user_id: 用户ID（用于容器命名）
        runtimes: 运行时列表，默认 ["python"]

    Returns:
        CustomOpenSandbox 实例
    """
    sandbox_logger.info(f"Creating sandbox for user: {user_id}")

    # 生成用户隔离的容器名
    safe_user_id = "".join(c if c.isalnum() else "_" for c in user_id)
    container_name = f"erp-sandbox-{safe_user_id}"

    config = SandboxConfig(
        name=container_name,
        runtimes=runtimes or ["python"],
    )

    sandbox = create_secure_sandbox(config)

    # 初始化标准目录结构
    sandbox.execute(
        "mkdir -p /workspace /workspace/data /workspace/analysis "
        "/workspace/output /skills"
    )

    # === 关键：将项目文件同步到沙箱（实现真正的隔离测试）===
    _sync_project_files(sandbox)

    sandbox_logger.info(f"Sandbox created and initialized for user: {user_id}")
    return sandbox


# ============================================================
# 项目文件同步到沙箱（Harness 隔离性核心）
# ============================================================

def _sync_project_files(sandbox: CustomOpenSandbox):
    """
    将项目关键文件同步到沙箱内，确保沙箱内可以独立测试和运行代码。

    同步内容：
    1. src/skills/       → /skills/       （技能文件）
    2. requirements.txt  → /workspace/requirements.txt （依赖）
    3. src/mcp_server/   → /workspace/mcp_server/ （MCP 工具，可测试调用）
    4. src/agent/tools/  → /workspace/agent_tools/ （Agent 工具脚本）

    不复制 .env、私钥或生产配置，避免将宿主机凭据暴露给可执行代码。

    这样沙箱内不仅有工作空间，还有完整的测试环境。
    """
    sync_map = [
        # (本地路径, 沙箱目标路径, 描述)
        (PROJECT_ROOT / "src" / "skills", "/skills", "Skills"),
        (PROJECT_ROOT / "requirements.txt", "/workspace/requirements.txt", "requirements.txt"),
        (PROJECT_ROOT / "src" / "mcp_server", "/workspace/mcp_server", "MCP Server"),
        (PROJECT_ROOT / "src" / "agent" / "tools", "/workspace/agent_tools", "Agent Tools"),
        (PROJECT_ROOT / "src" / "agent" / "schema.py", "/workspace/schema.py", "Schema"),
    ]

    synced = 0
    for local_path, remote_path, desc in sync_map:
        try:
            if local_path.is_dir():
                # 目录：tar 打包上传
                result = sandbox.upload_directory(str(local_path), remote_path)
                if result.startswith("OK"):
                    sandbox_logger.info(f"Synced {desc}: {local_path} -> {remote_path}")
                    synced += 1
                else:
                    sandbox_logger.warning(f"Sync {desc} failed: {result}")
            elif local_path.is_file():
                # 单文件：直接写入
                content = local_path.read_bytes()
                sandbox.upload_files([(remote_path, content)])
                sandbox_logger.info(f"Synced {desc}: {local_path} -> {remote_path}")
                synced += 1
            else:
                sandbox_logger.debug(f"Skip sync {desc}: {local_path} not found")
        except Exception as e:
            sandbox_logger.warning(f"Sync {desc} error: {e}")

    sandbox_logger.info(f"Project files synced: {synced}/{len(sync_map)} items")
