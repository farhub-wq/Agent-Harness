"""``/api/history`` 三个端点的会话归属校验。

改造前这三个端点（列表 / 消息 / 删除）**都没有归属校验**，知道 thread_id 就能
读写删别人的会话；``user_id`` 还完全由客户端提供，前端硬编码成 ``user-001``，
所有浏览器共享同一份历史。

这里覆盖三件事，其中第 3 条最容易被漏掉：

1. 跨用户访问 → 403
2. 归属记录为空（孤儿会话）→ 403，**不是放行**
3. 403 时**不能有任何副作用** —— 尤其是 ``delete_conversation``：
   校验失败却已经删了，是最坏的组合。

端点里的 ``authenticated`` 形参默认值是 ``Depends(current_user_id)``，
只有走 FastAPI 依赖注入时才是 ``None``；直接调用必须显式传。
"""
import asyncio
import unittest
from unittest.mock import AsyncMock, patch

from fastapi import HTTPException

from src.api_view.api import history
from src.api_view.auth import derive_user_id

ALICE = derive_user_id("alice")
BOB = derive_user_id("bob")


class _FakeAgentLoader:
    """只实现 history.py 用到的四个方法。"""

    def __init__(self, owner=None, messages=None):
        self._owner = owner
        self._messages = messages if messages is not None else [{"role": "user"}]
        self.get_conversations = AsyncMock(return_value=[{"thread_id": "t1"}])
        # **必须用 side_effect，不能用 return_value=self._owner。**
        # return_value 在**构造这一刻**就把当前值固化下来了，之后再改
        # self._owner 不会生效 —— 于是下面所有"先设 _owner 再断言"的用例
        # 全部退化成 owner 恒为 None：期望 403 的那几个照样通过（因为 None 也
        # 403），看着在测归属不匹配，实际一次都没走到那个分支。
        self.get_conversation_user_id = AsyncMock(side_effect=lambda *a, **k: self._owner)
        self.get_display_messages = AsyncMock(return_value=self._messages)
        self.delete_conversation = AsyncMock(return_value=None)


class _HistoryTestBase(unittest.TestCase):
    def setUp(self):
        self.loader = _FakeAgentLoader()
        self._patcher = patch.object(history, "agent_loader", self.loader)
        self._patcher.start()
        self.addCleanup(self._patcher.stop)


class TestGetMessagesOwnership(_HistoryTestBase):
    def _call(self, thread_id, authenticated):
        return asyncio.run(history.get_messages(thread_id=thread_id,
                                                authenticated=authenticated))

    def test_owner_mismatch_is_403(self):
        self.loader._owner = BOB
        with self.assertRaises(HTTPException) as ctx:
            self._call("t1", ALICE)
        self.assertEqual(ctx.exception.status_code, 403)
        # 拒绝了就不该再去读消息内容
        self.loader.get_display_messages.assert_not_awaited()

    def test_orphaned_thread_is_403(self):
        """有展示消息但没有归属记录 —— 这种 thread 只有 chat.py 能认领。

        history 这三个端点一律拒绝：放行就等于"随便报一个 thread_id 就能读"。
        """
        for owner in (None, ""):
            with self.subTest(owner=owner):
                self.loader._owner = owner
                with self.assertRaises(HTTPException) as ctx:
                    self._call("t1", ALICE)
                self.assertEqual(ctx.exception.status_code, 403)

    def test_owner_match_returns_messages(self):
        self.loader._owner = ALICE
        result = self._call("t1", ALICE)
        self.assertEqual(result["thread_id"], "t1")
        self.assertEqual(result["messages"], self.loader._messages)

    def test_unauthenticated_skips_check(self):
        """AUTH_MODE=none（authenticated 为 None）不校验，保持本机开发行为。"""
        self.loader._owner = BOB
        result = self._call("t1", None)
        self.assertEqual(result["thread_id"], "t1")


class TestDeleteConversationOwnership(_HistoryTestBase):
    def _call(self, thread_id, authenticated):
        return asyncio.run(history.delete_conversation(thread_id=thread_id,
                                                       authenticated=authenticated))

    def test_owner_mismatch_is_403_and_does_not_delete(self):
        """**403 时绝不能已经删了。** 校验失败 + 副作用是最坏的组合。"""
        self.loader._owner = BOB
        with self.assertRaises(HTTPException) as ctx:
            self._call("t1", ALICE)
        self.assertEqual(ctx.exception.status_code, 403)
        self.loader.delete_conversation.assert_not_awaited()

    def test_orphaned_thread_is_403_and_does_not_delete(self):
        self.loader._owner = None
        with self.assertRaises(HTTPException) as ctx:
            self._call("t1", ALICE)
        self.assertEqual(ctx.exception.status_code, 403)
        self.loader.delete_conversation.assert_not_awaited()

    def test_owner_match_deletes(self):
        self.loader._owner = ALICE
        result = self._call("t1", ALICE)
        self.assertTrue(result["success"])
        self.loader.delete_conversation.assert_awaited_once_with("t1")

    def test_unauthenticated_skips_check(self):
        self.loader._owner = BOB
        result = self._call("t1", None)
        self.assertTrue(result["success"])


class TestListConversationsIdentity(_HistoryTestBase):
    """列表端点不做归属校验（它按 user_id 查），但**身份不能来自请求**。"""

    def _call(self, user_id, authenticated):
        return asyncio.run(history.list_conversations(user_id=user_id,
                                                      authenticated=authenticated))

    def test_authenticated_identity_overrides_requested_user_id(self):
        """请求里报别人的 user_id 也没用 —— 查询用的是认证身份。"""
        self._call(user_id=BOB, authenticated=ALICE)
        self.loader.get_conversations.assert_awaited_once_with(ALICE)

    def test_falls_back_to_requested_when_unauthenticated(self):
        self._call(user_id=BOB, authenticated=None)
        self.loader.get_conversations.assert_awaited_once_with(BOB)


if __name__ == "__main__":
    unittest.main()
