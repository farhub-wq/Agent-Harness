"""
身份解析

容器部署走 nginx 的 HTTP Basic：nginx 认人后把 ``$remote_user`` 注入
``X-Authenticated-User``，backend 只信这个头。

关键点：在 ``AUTH_MODE=proxy`` 下，请求体 / 查询串里的 ``user_id`` 一律被
**丢弃**。改造前 ``user_id`` 完全由客户端提供且前端硬编码成 ``user-001``，
意味着所有浏览器共享同一份会话历史、同一个沙箱；而 ``/api/chat/{id}/history``
和 ``DELETE /api/history/{id}`` 连归属校验都没有，知道 thread_id 就能读写
别人的会话。身份必须来自认证层，不能来自请求体。

``AUTH_MODE=none``（本机开发默认）不校验，行为与改造前完全一致。
"""
import hashlib
import re
import secrets
from typing import Optional

from fastapi import Header, HTTPException

from ..agent.config import (
    AUTH_MODE,
    AUTH_USER_HEADER,
    INTERNAL_AUTH_HEADER,
    INTERNAL_AUTH_TOKEN,
)
from ..agent.log_utils import web_logger

# Basic Auth 的用户名允许出现空格、冒号、非 ASCII 等字符，而 user_id 会进入
# Mongo 查询条件、Store 命名空间和沙箱容器名（容器名有字符集限制），
# 所以不能原样透传。
_UNSAFE_CHARS = re.compile(r"[^A-Za-z0-9_-]")

DEFAULT_USER_ID = "default_user"


def derive_user_id(username: str) -> str:
    """把 Basic Auth 用户名映射成稳定的 user_id。

    保留可读前缀便于排障（日志里能看出是谁），后缀哈希保证不同用户名的映射
    不撞车 —— 只做字符替换的话 ``a.b`` 和 ``a-b`` 会合并成同一个人。
    """
    digest = hashlib.sha256(username.encode("utf-8")).hexdigest()[:8]
    safe = _UNSAFE_CHARS.sub("", username)[:24]
    return f"{safe}_{digest}" if safe else f"user_{digest}"


async def current_user_id(
    authenticated_user: Optional[str] = Header(default=None, alias=AUTH_USER_HEADER),
    internal_auth: Optional[str] = Header(default=None, alias=INTERNAL_AUTH_HEADER),
) -> Optional[str]:
    """FastAPI 依赖：返回认证身份。

    - ``AUTH_MODE=proxy`` 且头存在 → 返回派生的 user_id
    - ``AUTH_MODE=proxy`` 但头缺失 → 401（说明请求绕过了 nginx）
    - ``AUTH_MODE=none``          → 返回 None，调用方回退到请求里的 user_id

    配了 ``INTERNAL_AUTH_TOKEN`` 时，还要求 ``X-Internal-Auth`` 匹配。这道校验
    挡的是"沙箱代码直连 backend 伪造身份头"（见 config.py 里该变量的注释）。
    """
    if AUTH_MODE != "proxy":
        return None
    if not authenticated_user or not authenticated_user.strip():
        web_logger.warning(
            f"Rejected unauthenticated request: missing {AUTH_USER_HEADER} header "
            f"(AUTH_MODE=proxy). The request did not come through nginx."
        )
        raise HTTPException(status_code=401, detail="未认证")
    if INTERNAL_AUTH_TOKEN and not _token_matches(internal_auth):
        web_logger.warning(
            f"Rejected request with a valid {AUTH_USER_HEADER} but a bad/missing "
            f"{INTERNAL_AUTH_HEADER}: it did not come from nginx."
        )
        raise HTTPException(status_code=401, detail="未认证")
    return derive_user_id(authenticated_user.strip())


def _token_matches(provided: Optional[str]) -> bool:
    """定长比较，避免按字符提前返回泄露密钥前缀。"""
    return secrets.compare_digest((provided or "").encode("utf-8"),
                                  INTERNAL_AUTH_TOKEN.encode("utf-8"))


def resolve_user_id(authenticated: Optional[str], requested: Optional[str]) -> str:
    """决定本次请求用哪个 user_id。

    认证身份优先，且会显式记录被丢弃的客户端取值 —— 如果日志里出现这行，
    说明有客户端在试图指定别人的身份。
    """
    if authenticated:
        if requested and requested != authenticated:
            web_logger.info(
                f"Ignoring client-supplied user_id {requested!r}, "
                f"using authenticated identity {authenticated!r}"
            )
        return authenticated
    return requested or DEFAULT_USER_ID


def assert_thread_owner(thread_id: str, owner: Optional[str], user_id: Optional[str]) -> None:
    """校验会话归属。

    ``user_id`` 为 None 表示没开认证（AUTH_MODE=none），此时不做校验以保持
    本机开发行为不变。开启认证后 ``owner`` 为空（会话记录不存在）也一律拒绝 ——
    放行会变成"随便报一个 thread_id 就能读"。
    """
    if user_id is None:
        return
    if not owner or owner != user_id:
        web_logger.warning(
            f"Denied cross-user access to thread {thread_id}: owner={owner!r}, requester={user_id!r}"
        )
        raise HTTPException(status_code=403, detail="该会话不属于当前用户")
