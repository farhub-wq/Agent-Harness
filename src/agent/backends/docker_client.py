"""
Docker 客户端工厂

三个沙箱模块原先各自 ``docker.from_env()``，带来两个问题：

1. 连接池不共享。``SandboxManager._restore_from_mongodb`` 甚至只为了查一次容器
   状态就建一个 client 然后关掉，紧接着 ``CustomOpenSandbox`` 又建第二个。
2. 各自承担超时默认值。SDK 默认单次调用 60s，dind 冷启动时 ``containers.run``
   里夹着一次镜像 pull，会直接 ReadTimeout。

统一从这里取，保证连接配置与超时只定义一处。

**daemon 地址仍由 docker SDK 从环境变量读取**（``DOCKER_HOST`` /
``DOCKER_TLS_VERIFY`` / ``DOCKER_CERT_PATH``），所以指向 dind 与指向外部远程
daemon 用的是同一份代码，切换只改环境变量。
"""
import atexit
import threading
from typing import Optional

import docker

from ..config import DOCKER_TIMEOUT_SECONDS
from ..log_utils import sandbox_logger

_client: Optional[docker.DockerClient] = None
_lock = threading.Lock()


def get_docker_client(*, timeout: int | None = None) -> docker.DockerClient:
    """返回进程级共享的 Docker 客户端。

    共享带来的约束：调用方**不得**对其调用 ``close()``，否则会连带关掉其它
    用户正在使用的连接池。``CustomOpenSandbox.destroy()`` /
    ``destroy_container()`` 只断开自己持有的容器引用。

    Args:
        timeout: 单次 API 调用超时（秒）。None 时用 ``DOCKER_TIMEOUT_SECONDS``。

    Raises:
        Exception: 连接 daemon 失败时原样抛出，避免把错误推迟到首次创建容器。
    """
    global _client
    if _client is None:
        with _lock:
            if _client is None:
                client = docker.from_env(timeout=timeout or DOCKER_TIMEOUT_SECONDS)
                try:
                    client.ping()
                except Exception:
                    # ping 失败就丢掉，否则会把一个坏 client 缓存整个进程生命周期。
                    client.close()
                    raise
                _client = client
                sandbox_logger.info(
                    f"Docker client connected: {client.api.base_url}"
                )
    elif timeout is not None and timeout != _client.api.timeout:
        # 缓存命中时 timeout 被忽略。以前是静默忽略 —— 调用方会以为自己的超时
        # 生效了（正是排查"长命令为什么先 ReadTimeout"时最容易踩的坑），所以
        # 这里明说。真要改超时得先 reset_docker_client()。
        sandbox_logger.warning(
            f"get_docker_client(timeout={timeout}) ignored — reusing the cached "
            f"client (timeout={_client.api.timeout}). Call reset_docker_client() "
            f"first if the change is intended."
        )
    return _client


def reset_docker_client() -> None:
    """丢弃缓存的客户端。

    dind 重启或连接池失效后调用；下次 :func:`get_docker_client` 会重建。
    """
    global _client
    with _lock:
        if _client is not None:
            try:
                _client.close()
            except Exception:
                pass
            _client = None
            sandbox_logger.info("Docker client reset")


@atexit.register
def _shutdown_docker_client() -> None:
    reset_docker_client()
