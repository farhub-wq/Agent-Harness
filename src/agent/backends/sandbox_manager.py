"""
沙箱生命周期管理（Harness 五态模型）

五态流转：
┌─────────┐    认领     ┌─────────┐    持久化    ┌────────────┐
│  预热池  │ ──────────→ │  已认领  │ ──────────→ │ MongoDB缓存 │
│ (WARM)  │             │ (CLAIMED)│             │  (CACHED)  │
└─────────┘             └─────────┘             └────────────┘
     ↑                       │
     │ 补充预热               │ 故障/超时
     │                       ↓
┌─────────┐             ┌─────────┐
│  新建    │ ←────────── │  销毁    │
│ (CREATE)│   预热池空    │(DESTROY)│
└─────────┘             └─────────┘

设计要点：
- 预热池保持 N 个空闲容器，认领时 < 100ms
- MongoDB 持久化 user→container 映射，服务重启不丢失
- 健康检查 + 自动重建故障容器
- 超时回收闲置沙箱（默认 30 分钟）
"""
import threading
import uuid
from datetime import datetime, timedelta
from typing import Dict, Optional
from urllib.parse import urlparse

from ..config import (
    SANDBOX_IDLE_TIMEOUT_MINUTES,
    SANDBOX_MCP_HOST_IP,
    SANDBOX_MCP_URL,
    SANDBOX_WARM_POOL_SIZE,
)
from ..log_utils import sandbox_logger
from .custom_opensandbox import CustomOpenSandbox
from .docker_client import get_docker_client
from .sandbox_setup import SandboxConfig, create_secure_sandbox

# 所有沙箱容器名共用此前缀（预热池、用户容器、旧版 create_and_setup_sandbox）。
SANDBOX_CONTAINER_PREFIX = "erp-sandbox-"

# 预热容器的专属前缀。prune_orphans 靠它把「重启后必然无主的暖容器」和
# 「映射持久化在 Mongo 里、必须留着的用户容器」区分开。
WARM_CONTAINER_PREFIX = "erp-sandbox-warm-"


def build_sandbox_config(name: str, runtimes: list[str]) -> SandboxConfig:
    """构造沙箱配置，并注入沙箱内访问 MCP 所需的地址。

    沙箱容器跑在 dind 自己的 bridge 网络里：
      - 解析不了 compose 服务名（dind 的内嵌 DNS 不认识 ``mcp``）
      - 和 mcp 不在同一个二层网络，直接发 IP 也没有回程路由

    解法是把 mcp 在 ``mcp-sandbox`` 网络上的静态 IP 写进沙箱容器的
    /etc/hosts，流量经 dind 的网关转发出去 —— dind 同时挂在该网络上，
    dockerd 为 bridge 网络装的 MASQUERADE 规则会把源地址改写成 dind 的
    地址，mcp 的响应才找得回来。

    SANDBOX_MCP_URL / SANDBOX_MCP_HOST_IP 任一为空 = 不注入（本机开发，
    或刻意不开放这条通路）。
    """
    if not SANDBOX_MCP_URL or not SANDBOX_MCP_HOST_IP:
        return SandboxConfig(name=name, runtimes=runtimes)

    host = urlparse(SANDBOX_MCP_URL).hostname
    if not host:
        sandbox_logger.warning(
            f"SANDBOX_MCP_URL={SANDBOX_MCP_URL!r} has no hostname; "
            f"skipping MCP injection into sandbox"
        )
        return SandboxConfig(name=name, runtimes=runtimes)

    base = SANDBOX_MCP_URL.rstrip("/")
    return SandboxConfig(
        name=name,
        runtimes=runtimes,
        env_vars={
            "MCP_SERVER_URL": base,
            "MCP_SSE_URL": f"{base}/sse",
        },
        extra_hosts={host: SANDBOX_MCP_HOST_IP},
    )


# ============================================================
# 沙箱状态枚举
# ============================================================

class SandboxState:
    WARM = "warm"           # 预热池中的空闲容器
    CLAIMED = "claimed"     # 已分配给用户
    CACHED = "cached"       # 已持久化到 MongoDB
    CREATING = "creating"   # 正在创建中
    DESTROYED = "destroyed" # 已销毁


# ============================================================
# 沙箱元数据
# ============================================================

class SandboxEntry:
    """沙箱条目（跟踪容器的完整生命周期）"""

    def __init__(
        self,
        sandbox: CustomOpenSandbox,
        user_id: str = "",
        state: str = SandboxState.WARM,
    ):
        self.sandbox = sandbox
        self.user_id = user_id
        self.state = state
        self.created_at = datetime.now()
        self.claimed_at: Optional[datetime] = None
        self.last_active_at = datetime.now()
        self.active_runs = 0

    def touch(self):
        """更新活跃时间"""
        self.last_active_at = datetime.now()

    @property
    def container_name(self) -> str:
        return self.sandbox.container_name

    @property
    def container_id(self) -> str:
        return self.sandbox.container_id

    def is_healthy(self) -> bool:
        """检查容器是否健康"""
        return self.sandbox.ping()

    def to_dict(self) -> dict:
        """序列化为字典（用于 MongoDB 存储）"""
        return {
            "container_name": self.container_name,
            "container_id": self.container_id,
            "user_id": self.user_id,
            "state": self.state,
            "created_at": self.created_at.isoformat(),
            "claimed_at": self.claimed_at.isoformat() if self.claimed_at else None,
            "last_active_at": self.last_active_at.isoformat(),
            "active_runs": self.active_runs,
        }


# ============================================================
# 沙箱生命周期管理器
# ============================================================

class SandboxManager:
    """
    沙箱生命周期管理器（Harness 五态模型）

    核心职责：
    1. 预热池管理：保持 N 个空闲容器随时可用
    2. 认领机制：用户请求时从预热池快速分配
    3. MongoDB 缓存：持久化 user→container 映射
    4. 自动新建：预热池空时按需创建
    5. 超时回收 + 故障自动重建
    """

    _instance: Optional['SandboxManager'] = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def __init__(
        self,
        warm_pool_size: Optional[int] = None,
        idle_timeout_minutes: Optional[int] = None,
    ):
        if self._initialized:
            return
        self._initialized = True

        # --- 核心状态 ---
        self._entries: Dict[str, SandboxEntry] = {}   # container_name → entry
        self._user_map: Dict[str, str] = {}           # user_id → container_name
        self._warm_creating = 0                        # 避免并发补池超量创建

        # --- 配置 ---
        self._warm_pool_size = (
            SANDBOX_WARM_POOL_SIZE if warm_pool_size is None else warm_pool_size
        )
        effective_idle_timeout = (
            SANDBOX_IDLE_TIMEOUT_MINUTES
            if idle_timeout_minutes is None
            else idle_timeout_minutes
        )
        self._idle_timeout = timedelta(minutes=effective_idle_timeout)
        self._lock = threading.Lock()

        sandbox_logger.info(
            f"SandboxManager initialized (warm_pool={self._warm_pool_size}, "
            f"idle_timeout={effective_idle_timeout}min)"
        )

    # ============================================================
    # 预热池管理
    # ============================================================

    def ensure_warm_pool(self):
        """确保预热池中有足够的空闲容器"""
        with self._lock:
            warm_count = sum(
                1 for e in self._entries.values()
                if e.state == SandboxState.WARM
            )

            needed = self._warm_pool_size - warm_count - self._warm_creating
            if needed <= 0:
                return
            self._warm_creating += needed

            sandbox_logger.info(f"Warm pool refill: need {needed} more containers")

        # 在锁外创建容器（避免长时间持有锁）
        for i in range(needed):
            try:
                entry = self._create_warm_container()
                with self._lock:
                    self._entries[entry.container_name] = entry
                sandbox_logger.info(
                    f"Warm pool container created: {entry.container_name}"
                )
            except Exception as e:
                sandbox_logger.error(f"Failed to create warm pool container: {e}")
            finally:
                with self._lock:
                    self._warm_creating = max(0, self._warm_creating - 1)

    def _create_warm_container(self) -> SandboxEntry:
        """创建一个预热容器"""
        # 生成唯一容器名
        name = f"{WARM_CONTAINER_PREFIX}{uuid.uuid4().hex[:12]}"

        # python:3.11-slim 已带 Python；图表和 Skill 依赖按需安装到
        # /workspace/python-packages，预热阶段不做耗时网络安装。
        config = build_sandbox_config(name, runtimes=[])
        sandbox = create_secure_sandbox(config)
        sandbox.execute(
            "mkdir -p /workspace /workspace/data /workspace/analysis "
            "/workspace/output /skills"
        )

        return SandboxEntry(sandbox=sandbox, state=SandboxState.WARM)

    # ============================================================
    # 认领机制（用户请求沙箱）
    # ============================================================

    def get_sandbox(self, user_id: str) -> CustomOpenSandbox:
        """
        获取用户的沙箱实例

        优先级：
        1. 已有且健康 → 直接返回
        2. MongoDB 有缓存且健康 → 恢复
        3. 预热池有空闲 → 认领
        4. 新建容器
        """
        with self._lock:
            # 1. 检查用户是否已有沙箱
            container_name = self._user_map.get(user_id)
            if container_name and container_name in self._entries:
                entry = self._entries[container_name]
                if entry.is_healthy():
                    entry.touch()
                    sandbox_logger.debug(f"Returning existing sandbox for {user_id}")
                    return entry.sandbox
                else:
                    # 容器故障，清理并重建
                    sandbox_logger.warning(
                        f"Sandbox unhealthy for {user_id}, will rebuild"
                    )
                    self._remove_entry(entry)

        # 2. 服务重启后优先恢复已有容器，避免先认领预热容器导致旧容器孤儿化。
        restored = self._restore_from_mongodb(user_id)
        if restored:
            return restored

        # 3. 尝试从预热池认领
        claimed = self._claim_from_warm_pool(user_id)
        if claimed:
            return claimed

        # 4. 新建容器
        sandbox_logger.info(f"No warm/cached sandbox for {user_id}, creating new")
        return self._create_for_user(user_id)

    def _claim_from_warm_pool(self, user_id: str) -> Optional[CustomOpenSandbox]:
        """从预热池中认领一个空闲容器"""
        with self._lock:
            for entry in self._entries.values():
                if entry.state == SandboxState.WARM and entry.is_healthy():
                    # 认领！
                    entry.user_id = user_id
                    entry.state = SandboxState.CLAIMED
                    entry.claimed_at = datetime.now()
                    entry.touch()
                    self._user_map[user_id] = entry.container_name

                    sandbox_logger.info(
                        f"Claimed warm sandbox {entry.container_name} for {user_id}"
                    )

                    # 异步持久化到 MongoDB
                    self._persist_to_mongodb(entry)

                    # 补充预热池
                    threading.Thread(
                        target=self.ensure_warm_pool,
                        daemon=True,
                    ).start()

                    return entry.sandbox

        return None

    def _create_for_user(self, user_id: str) -> CustomOpenSandbox:
        """为用户创建新容器"""
        # 正常 Web 链路由 AgentLoader 串行创建；这里仍做二次检查，防止其他调用方
        # 并发进入 Manager 时各自创建并覆盖同一 user_id 的映射。
        with self._lock:
            current_name = self._user_map.get(user_id)
            current = self._entries.get(current_name) if current_name else None
            if current is not None and current.is_healthy():
                current.touch()
                return current.sandbox

        safe_user_id = "".join(c if c.isalnum() else "_" for c in user_id)
        name = f"erp-sandbox-{safe_user_id}-{uuid.uuid4().hex[:12]}"

        config = build_sandbox_config(name, runtimes=[])
        sandbox = create_secure_sandbox(config)
        sandbox.execute(
            "mkdir -p /workspace /workspace/data /workspace/analysis "
            "/workspace/output /skills"
        )

        entry = SandboxEntry(
            sandbox=sandbox,
            user_id=user_id,
            state=SandboxState.CLAIMED,
        )
        entry.claimed_at = datetime.now()

        raced_entry = None
        with self._lock:
            current_name = self._user_map.get(user_id)
            current = self._entries.get(current_name) if current_name else None
            if current is not None and current.is_healthy():
                current.touch()
                raced_entry = current
            else:
                self._entries[name] = entry
                self._user_map[user_id] = name

        if raced_entry is not None:
            # 有并发调用已经抢先成功，锁外清理自己刚创建的多余容器。
            try:
                sandbox.destroy_container()
            except Exception:
                pass
            return raced_entry.sandbox

        self._persist_to_mongodb(entry)
        sandbox_logger.info(f"New sandbox created for {user_id}: {name}")
        return sandbox

    # ============================================================
    # MongoDB 缓存（持久化 user→container 映射）
    # ============================================================

    def _persist_to_mongodb(self, entry: SandboxEntry):
        """将沙箱映射持久化到 MongoDB"""
        try:
            import os

            from pymongo import MongoClient
            mongo_uri = os.getenv("MONGODB_URI", "mongodb://localhost:27017")
            db_name = os.getenv("MONGODB_DB_NAME", "erp_agent")

            client = MongoClient(mongo_uri, serverSelectionTimeoutMS=3000)
            db = client[db_name]

            db.sandbox_cache.update_one(
                {"user_id": entry.user_id},
                {"$set": entry.to_dict()},
                upsert=True,
            )
            entry.state = SandboxState.CACHED
            client.close()
            sandbox_logger.debug(f"Persisted sandbox cache for {entry.user_id}")
        except Exception as e:
            sandbox_logger.warning(f"Failed to persist sandbox cache: {e}")

    def _restore_from_mongodb(self, user_id: str) -> Optional[CustomOpenSandbox]:
        """从 MongoDB 恢复沙箱映射"""
        try:
            import os

            from pymongo import MongoClient
            mongo_uri = os.getenv("MONGODB_URI", "mongodb://localhost:27017")
            db_name = os.getenv("MONGODB_DB_NAME", "erp_agent")

            client = MongoClient(mongo_uri, serverSelectionTimeoutMS=3000)
            db = client[db_name]

            doc = db.sandbox_cache.find_one({"user_id": user_id})
            client.close()

            if not doc:
                return None

            container_name = doc.get("container_name", "")
            sandbox_logger.info(
                f"Found cached sandbox mapping: {user_id} -> {container_name}"
            )

            # 直接构造，不先单独查一次容器状态：CustomOpenSandbox._connect
            # 已经覆盖"不存在"与"未运行"两种情况。之前这里多建了一个
            # Docker 客户端只为查状态，紧接着构造时又建第二个。
            try:
                sandbox = CustomOpenSandbox(container_name=container_name)
            except Exception as e:
                sandbox_logger.info(
                    f"Cached container unavailable ({e}), cleaning cache"
                )
                self._cleanup_mongodb_cache(user_id)
                return None

            entry = SandboxEntry(
                sandbox=sandbox,
                user_id=user_id,
                state=SandboxState.CACHED,
            )
            entry.claimed_at = datetime.now()

            with self._lock:
                self._entries[container_name] = entry
                self._user_map[user_id] = container_name

            sandbox_logger.info(
                f"Restored sandbox from MongoDB cache: {container_name}"
            )
            return sandbox

        except Exception as e:
            sandbox_logger.warning(f"Failed to restore from MongoDB cache: {e}")

        return None

    def _cleanup_mongodb_cache(self, user_id: str):
        """清理 MongoDB 中的无效缓存"""
        try:
            import os

            from pymongo import MongoClient
            mongo_uri = os.getenv("MONGODB_URI", "mongodb://localhost:27017")
            db_name = os.getenv("MONGODB_DB_NAME", "erp_agent")

            client = MongoClient(mongo_uri, serverSelectionTimeoutMS=3000)
            db = client[db_name]
            db.sandbox_cache.delete_one({"user_id": user_id})
            client.close()
        except Exception as e:
            sandbox_logger.warning(f"Failed to cleanup MongoDB cache: {e}")

    # ============================================================
    # 重建 / 销毁
    # ============================================================

    def rebuild(self, user_id: str = "default_user") -> CustomOpenSandbox:
        """重建用户沙箱（故障恢复）"""
        active_runs = 0
        with self._lock:
            container_name = self._user_map.get(user_id)
            if container_name and container_name in self._entries:
                entry = self._entries[container_name]
                active_runs = entry.active_runs
                self._remove_entry(entry)

        sandbox = self._create_for_user(user_id)
        if active_runs:
            with self._lock:
                replacement = self._entries.get(self._user_map.get(user_id, ""))
                if replacement is not None:
                    replacement.active_runs = active_runs
        return sandbox

    def destroy_user_sandbox(self, user_id: str):
        """销毁用户沙箱"""
        with self._lock:
            container_name = self._user_map.pop(user_id, None)
            if container_name and container_name in self._entries:
                entry = self._entries[container_name]
                self._remove_entry(entry)
                self._cleanup_mongodb_cache(user_id)
                sandbox_logger.info(f"Sandbox destroyed for user: {user_id}")

    def destroy_all(self):
        """销毁所有沙箱"""
        with self._lock:
            for entry in list(self._entries.values()):
                try:
                    entry.sandbox.destroy_container()
                except Exception:
                    pass
            self._entries.clear()
            self._user_map.clear()
        sandbox_logger.info("All sandboxes destroyed")

    # ============================================================
    # 超时回收
    # ============================================================

    def _persisted_container_names(self) -> Optional[set[str]]:
        """读 ``sandbox_cache`` 里所有映射的容器名。

        返回 ``None`` 表示**读不到**（Mongo 不可用或查询失败），调用方必须把
        它和「读到空集合」区别对待：空集合说明确实没有活跃用户容器，可以放心
        清扫；``None`` 说明信息不全，此时删任何一个用户容器都可能删掉别人的
        工作区。
        """
        try:
            import os

            from pymongo import MongoClient
            mongo_uri = os.getenv("MONGODB_URI", "mongodb://localhost:27017")
            db_name = os.getenv("MONGODB_DB_NAME", "erp_agent")

            client = MongoClient(mongo_uri, serverSelectionTimeoutMS=3000)
            try:
                names = {
                    doc.get("container_name")
                    for doc in client[db_name].sandbox_cache.find(
                        {}, {"container_name": 1}
                    )
                }
            finally:
                client.close()
        except Exception as e:
            sandbox_logger.warning(f"Failed to read sandbox_cache: {e}")
            return None
        names.discard(None)
        return names

    def prune_orphans(self) -> int:
        """清掉本进程不认识的遗留沙箱容器，返回清理数量。

        暖容器（``erp-sandbox-warm-<hex>``）在进程重启后必然无主：预热池是纯
        进程内状态，旧的那批既不在 ``self._entries`` 里、也不会被
        :meth:`cleanup_idle_sandboxes` 触及，会以 ``sleep infinity`` + 512MB
        内存限制的形态永久堆积直到 OOM。所以启动时必须先扫掉。

        **用户容器（``erp-sandbox-<user>-<hex>``）不能按前缀一并扫掉。**
        它们与暖容器共用 ``erp-sandbox-`` 前缀，而 user → container 映射是
        持久化在 Mongo 的 ``sandbox_cache`` 里的，:meth:`_restore_from_mongodb`
        正是靠它让重启后的会话接着用同一个工作区。无差别删除会把每个用户
        正在用的 ``/workspace`` 和依赖卷一起清空，重启即丢数据 —— 这与
        ``web_main.lifespan`` 里「重启后可恢复」的承诺直接矛盾。因此这里只删
        **在 sandbox_cache 里查不到**的用户容器，那才是真正的孤儿。

        只在服务启动时调用：运行期调用会误删其它并发进程刚建的容器。
        """
        try:
            client = get_docker_client()
            stale = client.containers.list(
                all=True, filters={"name": SANDBOX_CONTAINER_PREFIX}
            )
        except Exception as e:
            sandbox_logger.warning(f"Orphan prune skipped, Docker unavailable: {e}")
            return 0

        persisted = self._persisted_container_names()
        if persisted is None:
            sandbox_logger.warning(
                "Orphan prune: sandbox_cache unreadable — pruning warm containers "
                "only; user sandboxes are preserved to avoid destroying live work"
            )

        removed = 0
        for container in stale:
            # filters 是子串匹配，这里再确认一次前缀，避免误伤
            # 名字里恰好含该子串的无关容器。
            if not container.name.startswith(SANDBOX_CONTAINER_PREFIX):
                continue
            if container.name in self._entries:
                continue
            if not container.name.startswith(WARM_CONTAINER_PREFIX):
                # 用户容器：只有确认它不在持久化映射里才删。读不到映射时保留。
                if persisted is None or container.name in persisted:
                    continue
            try:
                container.stop(timeout=3)
                # v=True：孤儿容器的依赖目录 volume 跟着一起清（见 sandbox_setup）
                container.remove(force=True, v=True)
                removed += 1
            except Exception as e:
                sandbox_logger.warning(
                    f"Failed to prune orphan {container.name}: {e}"
                )

        if removed:
            sandbox_logger.info(f"Pruned {removed} orphan sandbox container(s)")
        return removed

    def cleanup_idle_sandboxes(self):
        """回收超时的空闲沙箱"""
        now = datetime.now()
        with self._lock:
            for entry in list(self._entries.values()):
                if entry.state in (SandboxState.CLAIMED, SandboxState.CACHED):
                    if entry.active_runs > 0:
                        continue
                    idle_time = now - entry.last_active_at
                    if idle_time > self._idle_timeout:
                        sandbox_logger.info(
                            f"Reclaiming idle sandbox: {entry.container_name} "
                            f"(idle {idle_time.total_seconds()/60:.0f}min)"
                        )
                        user_id = entry.user_id
                        self._remove_entry(entry)
                        if user_id:
                            self._user_map.pop(user_id, None)
                            self._cleanup_mongodb_cache(user_id)

    # ============================================================
    # 健康检查
    # ============================================================

    def get_active_container(self, user_id: str = "default_user") -> Optional[str]:
        """获取用户当前活跃的容器ID（供健康检查中间件使用）"""
        with self._lock:
            container_name = self._user_map.get(user_id)
            if container_name and container_name in self._entries:
                entry = self._entries[container_name]
                if entry.is_healthy():
                    return entry.container_id
        return None

    def touch(self, user_id: str) -> None:
        """记录某个用户沙箱仍在被使用，供健康检查链路调用。"""
        with self._lock:
            container_name = self._user_map.get(user_id)
            entry = self._entries.get(container_name) if container_name else None
            if entry is not None:
                entry.touch()

    def acquire_lease(self, user_id: str) -> bool:
        """标记正在运行的 Agent 流，防止超时回收误删工作中的容器。"""
        with self._lock:
            container_name = self._user_map.get(user_id)
            entry = self._entries.get(container_name) if container_name else None
            if entry is None:
                return False
            entry.active_runs += 1
            entry.touch()
            return True

    def release_lease(self, user_id: str) -> None:
        """释放运行租约；异常清理路径也不会让计数变为负数。"""
        with self._lock:
            container_name = self._user_map.get(user_id)
            entry = self._entries.get(container_name) if container_name else None
            if entry is not None:
                entry.active_runs = max(0, entry.active_runs - 1)
                entry.touch()

    def health_check_all(self):
        """检查所有沙箱健康状态"""
        with self._lock:
            unhealthy = []
            for name, entry in self._entries.items():
                if not entry.is_healthy():
                    unhealthy.append(entry)

        # 在锁外重建故障容器
        for entry in unhealthy:
            sandbox_logger.warning(
                f"Unhealthy sandbox detected: {entry.container_name} "
                f"(user={entry.user_id})"
            )
            if entry.user_id:
                self.rebuild(entry.user_id)

    # ============================================================
    # 内部工具
    # ============================================================

    def _remove_entry(self, entry: SandboxEntry):
        """移除并销毁一个条目（必须在锁内调用）"""
        try:
            entry.sandbox.destroy_container()
        except Exception:
            pass
        entry.state = SandboxState.DESTROYED
        self._entries.pop(entry.container_name, None)
        if entry.user_id:
            self._user_map.pop(entry.user_id, None)


# ============================================================
# 全局单例
# ============================================================

sandbox_manager = SandboxManager()
