"""
FastAPI 应用入口
CORS 全开、路由注册、startup/shutdown 事件
"""
import asyncio
import os
import sys
from contextlib import asynccontextmanager, suppress
from pathlib import Path

# 确保项目根目录在 path 中
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..'))

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse

from ..agent.backends.sandbox_manager import sandbox_manager
from ..agent.config import (
    AUTH_MODE,
    AUTH_USER_HEADER,
    CORS_ALLOW_ORIGINS,
    INTERNAL_AUTH_HEADER,
    INTERNAL_AUTH_TOKEN,
    SANDBOX_MAINTENANCE_INTERVAL_SECONDS,
)
from ..agent.log_utils import web_logger
from .api.chat import router as chat_router
from .api.history import router as history_router
from .auth import current_user_id
from .web_config import close_mongo_client


async def _sandbox_maintenance(stop_event: asyncio.Event) -> None:
    """后台补齐预热池、回收空闲容器。

    主请求中的 HealthMiddleware 才负责“重建 + Proxy 热替换 + 文件回填”；此处
    绝不直接调用 ``health_check_all``，否则 Agent 仍会持有旧后端引用。
    """
    while not stop_event.is_set():
        try:
            await asyncio.to_thread(sandbox_manager.cleanup_idle_sandboxes)
            await asyncio.to_thread(sandbox_manager.ensure_warm_pool)
        except Exception as exc:
            web_logger.warning(f"Sandbox maintenance iteration failed: {exc}")

        try:
            await asyncio.wait_for(
                stop_event.wait(), timeout=SANDBOX_MAINTENANCE_INTERVAL_SECONDS
            )
        except TimeoutError:
            pass


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期管理"""
    web_logger.info("Starting ERP Agent Web Server...")
    if AUTH_MODE == "proxy" and not INTERNAL_AUTH_TOKEN:
        web_logger.warning(
            f"AUTH_MODE=proxy without INTERNAL_AUTH_TOKEN: backend trusts "
            f"{AUTH_USER_HEADER} from anyone who can reach it. Sandbox code runs "
            f"inside dind, which shares a Docker network with this container, so it "
            f"can forge that header and read other users' conversations. Set "
            f"INTERNAL_AUTH_TOKEN (and inject {INTERNAL_AUTH_HEADER} from nginx) to close it."
        )
    stop_event = asyncio.Event()
    maintenance_task = None
    try:
        # 先清扫上次进程遗留的孤儿容器，再补预热池。否则重启一次就多留一批
        # 随机命名的暖容器，它们在内存里没有对应 entry，永远不会被空闲回收。
        await asyncio.to_thread(sandbox_manager.prune_orphans)
        # 预热失败不阻止 Web 服务启动；首个请求仍会按需创建。
        await asyncio.to_thread(sandbox_manager.ensure_warm_pool)
        maintenance_task = asyncio.create_task(
            _sandbox_maintenance(stop_event), name="sandbox-maintenance"
        )
        yield
    finally:
        web_logger.info("Shutting down ERP Agent Web Server...")
        stop_event.set()
        if maintenance_task is not None:
            maintenance_task.cancel()
            with suppress(asyncio.CancelledError):
                await maintenance_task
        # 不销毁已认领容器：Manager 会把 user → container 映射持久化，重启后可恢复。
        await close_mongo_client()


app = FastAPI(
    title="DeepAgent 智能采购助手",
    description="基于 Harness Engineering 架构的摩托车零部件采购智能助手 API",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS 白名单来自 CORS_ALLOW_ORIGINS。容器部署下前端与后端同源（都在 nginx
# 后面），跨域不再发生，本项只服务直连后端本地开发的场景。
# 不用 allow_credentials：本服务不依赖 cookie，而 "*" + credentials 是浏览器
# 明确拒绝的非法组合。
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ALLOW_ORIGINS,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Prometheus 指标：/metrics 端点由 instrumentator 自动挂载，暴露
# http_request_duration_seconds / http_requests_total 等，供 Prometheus 抓取。
# 指标路径不认证（Prometheus 从 data 网络内抓取，带不了 Basic Auth），
# 但只暴露聚合计数，不含请求体或用户标识。
#
# 参数名必须与安装到的大版本对齐：requirements 是 >=7，pip 会解析到 8.x。
# 8.x 没有 should_gauge（传了在构造期 TypeError，backend 直接起不来——CI 集成
# 栈因此 unhealthy）；默认就不建 per-handler gauge，只输出按 handler 名分桶的
# counter/histogram，基数由路由模板（而非实际 URL）控制。expose 的 OpenAPI
# 开关叫 include_in_schema，不是 include_render_schema；tags 是 OpenAPI 的
# List[str]，与 Prometheus relabel 无关（relabel 在 prometheus.yml 做）。
from prometheus_fastapi_instrumentator import Instrumentator

Instrumentator().instrument(app).expose(
    app,
    endpoint="/metrics",
    include_in_schema=False,  # 不把 /metrics 写进 OpenAPI 文档，减少攻击面
)

# 注册路由
app.include_router(chat_router)
app.include_router(history_router)

# 文件下载目录（图表等生成文件）
DOWNLOAD_DIR = Path(__file__).resolve().parent.parent / "download"
# parents=True：容器里 src/download 可能整个目录都不存在（它在 .gitignore 里），
# 单层 mkdir 会直接崩在 import 期。
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

_DOWNLOAD_ROOT = DOWNLOAD_DIR.resolve()


@app.get("/api/download/{filename}")
async def download_file(filename: str, _: str | None = Depends(current_user_id)):
    """提供生成文件（图表PNG等）的HTTP下载

    注意：下载目录是全局共享的，认证只挡住匿名访问，挡不住"另一个已登录用户
    拿着文件名来取"。文件名是 ``<名称>_<时间戳>.md`` 这类可猜格式。要做严格
    隔离得让生成工具按 user_id 分目录，那是另一轮改动。
    """
    # 路由是单段匹配，但 Starlette 先按原始 path 匹配、之后才做 percent-decode，
    # 所以 /api/download/..%2F..%2Fetc%2Fpasswd 会匹配上并把 filename 解成
    # ../../etc/passwd。必须在这里重新限定在下载目录内。
    file_path = (DOWNLOAD_DIR / filename).resolve()
    if not file_path.is_relative_to(_DOWNLOAD_ROOT):
        raise HTTPException(status_code=400, detail="非法文件名")
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail=f"文件不存在: {filename}")
    return FileResponse(
        path=str(file_path),
        filename=file_path.name,
        media_type="application/octet-stream",
    )


@app.get("/")
async def root():
    return {"message": "DeepAgent 智能采购助手 API", "version": "1.0.0"}


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    # workers 必须为 1：SandboxManager / sandbox_holder / AgentLoader 都是进程内
    # 单例状态，多 worker 会各自认领同一个暖容器并互相覆盖 MongoDB 里的映射。
    uvicorn.run(app, host="0.0.0.0", port=8000, workers=1, proxy_headers=True)
