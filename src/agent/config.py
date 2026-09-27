"""
全局配置模块
LLM、Store、Checkpointer、沙箱连接参数
"""
import os
from langchain_deepseek import ChatDeepSeek
from .env_utils import get_env, get_env_int

# ============ LLM 配置 ============
LLM_MODEL = get_env("LLM_MODEL", "deepseek-flash")
LLM_BASE_URL = get_env("LLM_BASE_URL", "https://api.deepseek.com")
LLM_API_KEY = get_env("DEEPSEEK_API_KEY", "")
LLM_TEMPERATURE = 0.1
LLM_MAX_TOKENS = 4096
LLM_REASONING_EFFORT = get_env("LLM_REASONING_EFFORT", "high")


def get_llm(*, thinking: bool = True, timeout: float | None = None,
            max_retries: int = 2, max_tokens: int = LLM_MAX_TOKENS) -> ChatDeepSeek:
    """获取 DeepSeek 模型实例。

    主 Agent 使用思考模式；需要强制结构化输出的内部评审器使用
    非思考模式，避免 DeepSeek 拒绝 ``tool_choice`` 参数。
    """
    common_kwargs = {
        "model": LLM_MODEL,
        "base_url": LLM_BASE_URL,
        "api_key": LLM_API_KEY,
        "max_tokens": max_tokens,
        "max_retries": max_retries,
    }
    if timeout is not None:
        common_kwargs["timeout"] = timeout
    if thinking:
        return ChatDeepSeek(
            **common_kwargs,
            reasoning_effort=LLM_REASONING_EFFORT,
            extra_body={"thinking": {"type": "enabled"}},
        )
    return ChatDeepSeek(
        **common_kwargs,
        temperature=LLM_TEMPERATURE,
        extra_body={"thinking": {"type": "disabled"}},
    )


# ============ MongoDB 配置 ============
MONGODB_URI = get_env("MONGODB_URI", "mongodb://localhost:27017")
MONGODB_DB_NAME = get_env("MONGODB_DB_NAME", "erp_agent")

# ============ MCP Server 配置 ============
MCP_SERVER_URL = get_env("MCP_SERVER_URL", "http://localhost:9000")
MCP_SSE_URL = f"{MCP_SERVER_URL}/sse"

# ============ Docker 连接配置 ============
# 客户端连接哪个 daemon 由 docker SDK 自己从环境变量读取，这里不重复解析：
#   - 容器部署指向 dind：DOCKER_HOST=tcp://dind:2375
#     （docker:dind 必须同时设 DOCKER_TLS_CERTDIR="" 才会监听明文 2375）
#   - 接外部远程 daemon：DOCKER_HOST=tcp://host:2376，并同时提供
#     DOCKER_TLS_VERIFY=1 与 DOCKER_CERT_PATH=/certs/client
# 两组取值互斥：对着 dind 的明文端口带 TLS 变量会握手失败。
#
# docker SDK 默认单次 API 调用超时 60s，扛不住 dind 冷启动时 containers.run
# 里夹着的镜像 pull，会直接 ReadTimeout。
#
# 这个值同时是沙箱内 timeout(1) 的上限：exec_run 是同步 HTTP 请求，容器内的
# 超时必须先触发，否则这里先 ReadTimeout，失败就丢了原因（见
# custom_opensandbox.execute 的 clamp）。sandbox_setup 里最长的单命令超时是
# 900s（Go 运行时安装），所以默认值必须明显大于 900 —— 300 会让那些安装永远
# 只能跑 270s 就被 socket 超时打断。
DOCKER_TIMEOUT_SECONDS = get_env_int("DOCKER_TIMEOUT_SECONDS", 1200)

# ============ 对外访问配置 ============
# 生成给用户看的下载链接用的根地址。必须是浏览器可达的地址，
# 不是容器内部的 http://backend:8000。
PUBLIC_BASE_URL = get_env("PUBLIC_BASE_URL", "http://localhost:8000")
# 逗号分隔的 CORS 白名单。走 nginx 同源后本项是 no-op，只在直连后端时生效。
CORS_ALLOW_ORIGINS = [
    origin.strip()
    for origin in get_env("CORS_ALLOW_ORIGINS", "http://localhost:3000").split(",")
    if origin.strip()
]
# 沙箱不可用时是否允许退回到 LocalShellBackend / 无安全参数的容器。
# 本机开发可开；容器部署必须为 false —— local shell 会在 backend 进程环境
# （含 DEEPSEEK_API_KEY、可写的 skills 挂载）里执行模型生成的代码。
ALLOW_LOCAL_SHELL_FALLBACK = get_env(
    "ALLOW_LOCAL_SHELL_FALLBACK", "true"
).lower() in ("1", "true", "yes")

# ============ 认证 ============
# none  = 不认人，user_id 完全由客户端提供（本机开发，行为与改造前一致）
# proxy = 信任反向代理注入的身份头，头缺失即 401（容器部署）
#
# 容器部署由 nginx 的 auth_basic 认人，然后把 $remote_user 注入
# AUTH_USER_HEADER。backend 在 proxy 模式下会**丢弃**请求体/查询串里的
# user_id，改用认证身份 —— 否则前端随手改一个字符串就能读到别人的会话
# 和沙箱。
#
# 只在 backend 不对宿主机发布端口时成立：backend 直接可达的话，任何人都能
# 伪造这个头。compose 里 backend 没有 ports，只有 nginx 能连。
#
# 但"只有 nginx 能连 backend"这条前提在容器网络里并不成立：dind 与 backend
# 同在 sandbox 网络上（backend 要用 DOCKER_HOST=tcp://dind:2375），而沙箱容器
# 跑在 dind 自己的 daemon 里，出口流量经 dind MASQUERADE 转发后就落在同一张
# 网络上 —— 也就是说沙箱里模型生成的代码可以直连 backend，并自己伪造
# X-Authenticated-User，从而读到任意其他用户的会话。
#
# 堵法：nginx 额外注入一个只有它和后端知道的共享密钥头，backend 在 proxy 模式
# 下校验它。沙箱代码拿不到这个值（它只存在于 nginx 配置与 backend 进程环境里）。
#
# 留空 = 不校验，行为与改造前一致（本机已验证的拓扑不变）。为空时 backend 启动
# 会打一条警告，提醒这条通路仍然敞开。新服务器部署请务必设置。
AUTH_MODE = get_env("AUTH_MODE", "none").strip().lower()
AUTH_USER_HEADER = get_env("AUTH_USER_HEADER", "X-Authenticated-User")
INTERNAL_AUTH_TOKEN = get_env("INTERNAL_AUTH_TOKEN", "").strip()
INTERNAL_AUTH_HEADER = get_env("INTERNAL_AUTH_HEADER", "X-Internal-Auth")

# ============ 沙箱配置 ============
SANDBOX_IMAGE = get_env("SANDBOX_IMAGE", "python:3.11-slim")#Docker 镜像名称，具体是 Python 3.11 的 slim（精简）版本
SANDBOX_WORK_DIR = "/workspace"
SANDBOX_SKILLS_DIR = "/skills"
SANDBOX_MEMORIES_DIR = "/memories"
SANDBOX_WARM_POOL_SIZE = get_env_int("SANDBOX_WARM_POOL_SIZE", 1)

# 单条沙箱命令的默认超时（模型可以按次覆盖）。SDK 自己的 DEFAULT_EXECUTE_TIMEOUT
# 是 120s，但这个默认值在我们的 execute() 学会真正下发 timeout(1) 之前一直是
# 空转的，所以它从"形同虚设"变成了硬上限。本项目 AGENTS.md 要求脚本开头
# `pip install -q mcp`，图表任务还要装 matplotlib/numpy，慢网络下 120s 不够。
# 上限仍是 DOCKER_TIMEOUT_SECONDS（见 custom_opensandbox.execute 的 clamp）。
SANDBOX_EXECUTE_TIMEOUT_SECONDS = get_env_int("SANDBOX_EXECUTE_TIMEOUT_SECONDS", 300)
SANDBOX_IDLE_TIMEOUT_MINUTES = get_env_int("SANDBOX_IDLE_TIMEOUT_MINUTES", 30)
SANDBOX_MAINTENANCE_INTERVAL_SECONDS = get_env_int(
    "SANDBOX_MAINTENANCE_INTERVAL_SECONDS", 60
)
SANDBOX_HEALTH_CHECK_INTERVAL_SECONDS = get_env_int(
    "SANDBOX_HEALTH_CHECK_INTERVAL_SECONDS", 30
)

# 沙箱内访问 MCP Server 的地址。两个都为空 = 不注入，沙箱内无 MCP 能力
# （本机开发、或不想开放这条通路时就是这么用的）。
#
# 为什么需要 HOST_IP 这种别扭的东西：沙箱容器跑在 dind 自己的 bridge 网络
# 里，既解析不了 compose 的服务名（dind 的内嵌 DNS 不认识 `mcp`），也和 mcp
# 不在同一个二层网络。所以由 backend 把 mcp 在 mcp-sandbox 网络上的**静态
# IP** 写进沙箱容器的 /etc/hosts，流量经 dind 转发 + MASQUERADE 出去。
# 用静态 IP 而不是每次解析，是为了避免 mcp 容器重建换 IP 后沙箱里的地址失效。
SANDBOX_MCP_URL = get_env("SANDBOX_MCP_URL", "")
SANDBOX_MCP_HOST_IP = get_env("SANDBOX_MCP_HOST_IP", "")

# ============ Store 命名空间 ============
SKILLS_STORE_NAMESPACE = ("persisted-skills",)
PREFERENCES_STORE_NAMESPACE = ("user-preferences",)


def skills_store_namespace(user_id: str) -> tuple[str, str]:
    """Return the isolated Store namespace for one user's custom Skills."""
    return (*SKILLS_STORE_NAMESPACE, user_id)

# ============ Agent 配置 ============
MAX_MODEL_CALLS = get_env_int("MAX_MODEL_CALLS", 50)
MAX_TOOL_CALLS = get_env_int("MAX_TOOL_CALLS", 30)
SUMMARIZATION_THRESHOLD = 0.85  # 85% 上下文窗口时触发摘要

# ============ 中断配置 ============
INTERRUPT_ON_TOOLS = {
    "order_create": {"allowed_decisions": ["approve", "reject"]},
    "order_update": {"allowed_decisions": ["approve", "reject"]},
}
