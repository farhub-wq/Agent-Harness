"""``SandboxManager.prune_orphans()`` 的挑选逻辑。

这个函数在**每次 backend 启动**时跑一遍，决定哪些沙箱容器被删掉。删错方向的
代价极不对称：

- 该删没删 → 暖容器堆到 OOM（它们 `sleep infinity` + 512MB 内存限制）。
- **该留却删了 → 用户正在用的 ``/workspace`` 和依赖卷当场消失**，而且
  ``web_main.lifespan`` 对"重启后可恢复"的承诺同时失效。

所以这里的重点是「什么情况下必须**不**删」，其中最关键的一条是：Mongo 读不到
沙箱映射时（``_persisted_container_names()`` 返回 ``None``），**用户容器一律保留**。
写反了就是「Mongo 一抖动就删光所有用户工作区」。

判定逻辑目前**内联在 ``prune_orphans`` 里**、没有抽成可测的纯函数，所以只能
连 docker client 一起替换掉。假容器只需要 ``.name`` / ``.stop`` / ``.remove``
三个成员 —— 这反过来也说明了一件好事：这段逻辑除容器名之外不依赖 docker。
"""
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from src.agent.backends.sandbox_manager import (
    SANDBOX_CONTAINER_PREFIX,
    WARM_CONTAINER_PREFIX,
    SandboxManager,
)

WARM = f"{WARM_CONTAINER_PREFIX}abc123def456"
USER_ALICE = f"{SANDBOX_CONTAINER_PREFIX}alice_1a2b3c4d"
USER_BOB = f"{SANDBOX_CONTAINER_PREFIX}bob_2e3f4a5b"


class FakeContainer:
    def __init__(self, name: str):
        self.name = name
        self.stopped = False
        self.removed = False

    def stop(self, timeout=None):  # noqa: ARG002 - 签名对齐 docker SDK
        self.stopped = True

    def remove(self, force=False, v=False):  # noqa: ARG002
        self.removed = True


class FakeClient:
    def __init__(self, containers):
        self._containers = containers
        self.containers = SimpleNamespace(list=lambda **kw: list(containers))


class PruneOrphansTest(unittest.TestCase):
    def setUp(self):
        self.mgr = SandboxManager()
        # 单例：把被改动的私有状态存下来，tearDown 里还原，
        # 避免影响同一次 pytest 会话里的其它测试。
        self._orig_entries = dict(self.mgr._entries)
        self.mgr._entries = {}

    def tearDown(self):
        self.mgr._entries = self._orig_entries

    def _run(self, containers, persisted):
        """跑一次 prune_orphans，返回 (删除计数, 被删容器名集合, 全部容器)。"""
        with patch("src.agent.backends.sandbox_manager.get_docker_client",
                   return_value=FakeClient(containers)), \
             patch.object(SandboxManager, "_persisted_container_names",
                          return_value=persisted):
            removed = self.mgr.prune_orphans()
        return removed, {c.name for c in containers if c.removed}, containers

    # ------------------------------------------------------------ 必删
    def test_warm_container_is_pruned(self):
        """暖容器在进程重启后必然无主：预热池是纯进程内状态。"""
        removed, names, _ = self._run([FakeContainer(WARM)], persisted=set())
        self.assertEqual(removed, 1)
        self.assertEqual(names, {WARM})

    def test_user_container_not_in_persisted_is_pruned(self):
        """真正的孤儿用户容器（映射里查不到）该删。"""
        removed, names, _ = self._run([FakeContainer(USER_BOB)], persisted=set())
        self.assertEqual(removed, 1)
        self.assertEqual(names, {USER_BOB})

    # ------------------------------------------------------------ 必留
    def test_container_in_entries_is_kept(self):
        """本进程自己管的容器，即使名字像暖容器也不能删。"""
        c = FakeContainer(WARM)
        self.mgr._entries = {WARM: object()}
        removed, _, _ = self._run([c], persisted=set())
        self.assertEqual(removed, 0)
        self.assertFalse(c.removed)

    def test_persisted_user_container_is_kept(self):
        """在 sandbox_cache 里的用户容器 = 正被使用，必须留。

        删掉它等于清空那个用户的 /workspace 和依赖卷，
        而 lifespan 里对重启后恢复的承诺会同时失效。
        """
        c = FakeContainer(USER_ALICE)
        removed, _, _ = self._run([c], persisted={USER_ALICE})
        self.assertEqual(removed, 0)
        self.assertFalse(c.removed)

    def test_persisted_none_keeps_all_user_containers(self):
        """**Mongo 读不到映射时，用户容器一律保留。**

        这是本文件最要紧的一条。``_persisted_container_names()`` 返回 None
        表示"我们不知道谁在用哪个容器"，此时唯一的正确选择是不动它们 ——
        fail closed 的方向在这里是「保留」。写反了就是「Mongo 一抖动就删光
        所有用户工作区」，而 Mongo 抖动比重启罕见得多、也更容易被忽略。
        """
        containers = [FakeContainer(USER_ALICE), FakeContainer(USER_BOB)]
        removed, names, _ = self._run(containers, persisted=None)
        self.assertEqual(removed, 0, "persisted=None 时不应删任何用户容器")
        self.assertEqual(names, set())

    def test_persisted_none_still_prunes_warm_containers(self):
        """但暖容器照删 —— 它们与 Mongo 无关，重启后必然无主。"""
        warm = FakeContainer(WARM)
        alice = FakeContainer(USER_ALICE)
        removed, names, _ = self._run([warm, alice], persisted=None)
        self.assertEqual(removed, 1)
        self.assertEqual(names, {WARM})

    # ------------------------------------------------------------ 边界
    def test_unrelated_container_is_ignored(self):
        """filters 是**子串**匹配，别误伤名字里恰好含该子串的无关容器。"""
        c = FakeContainer("my-app-erp-sandbox-backup")
        removed, _, _ = self._run([c], persisted=set())
        self.assertEqual(removed, 0)
        self.assertFalse(c.removed)

    def test_docker_unavailable_returns_zero_without_raising(self):
        """dind 连不上时必须优雅降级，而不是让 backend 启动失败。

        这条是 PR 门禁能跑「无 dind 集成栈」的前提（见方案阶段 3-B）：
        depends_on 只是编排顺序约束，代码这边对 dind 缺失是容错的。
        """
        with patch("src.agent.backends.sandbox_manager.get_docker_client",
                   side_effect=RuntimeError("dind down")):
            self.assertEqual(self.mgr.prune_orphans(), 0)

    def test_stop_failure_does_not_abort_the_sweep(self):
        """单个容器删不掉不该中断整轮清扫。"""
        class Exploding(FakeContainer):
            def stop(self, timeout=None):  # noqa: ARG002
                raise RuntimeError("boom")

        bad = Exploding(f"{WARM_CONTAINER_PREFIX}dead")
        good = FakeContainer(WARM)
        removed, names, _ = self._run([bad, good], persisted=set())
        self.assertEqual(removed, 1)
        self.assertEqual(names, {WARM})


if __name__ == "__main__":
    unittest.main()
