"""``src/api_view/auth.py``：身份派生、共享密钥校验、会话归属。

这些逻辑以前完全没有测试，而它是**唯一**决定"谁能看谁的会话"的地方 ——
改造前 ``user_id`` 由客户端提供、前端硬编码成 ``user-001``，所有浏览器共享
同一份历史；而 ``/api/chat/{id}/history`` 和 ``DELETE /api/history/{id}``
连归属校验都没有，知道 thread_id 就能读写别人的会话。

**patch 必须打在 ``src.api_view.auth`` 上，不是 ``src.agent.config``。**
``auth.py`` 用的是 ``from ..agent.config import AUTH_MODE``，把常量**绑定进了
自己的命名空间**，所以改源模块的属性和改一个副本没区别。这个坑不写下来，
下一个人一定会踩。
"""
import asyncio
import unittest
from unittest.mock import patch

from fastapi import HTTPException

from src.api_view import auth


def _call_current_user_id(authenticated_user=None, internal_auth=None):
    """``current_user_id`` 是 async 依赖，直接 await 底层函数。

    **两个参数都必须显式传，不能靠省略。** ``current_user_id`` 的形参默认值是
    ``Header(default=None, alias=...)``，而那不是 ``None`` —— 它是 FastAPI 的
    ``FieldInfo`` 对象。只有走 FastAPI 的依赖注入时才会被换成真实值；直接调用
    底层函数时省略参数，拿到的是一个 FieldInfo，``.encode()`` 会 AttributeError。
    这个坑在"直接 await 端点函数"的测试里普遍存在。
    """
    return asyncio.run(auth.current_user_id(authenticated_user=authenticated_user,
                                            internal_auth=internal_auth))


class TestDeriveUserId(unittest.TestCase):
    """用户名 → user_id 的映射。"""

    def test_is_stable(self):
        self.assertEqual(auth.derive_user_id("alice"), auth.derive_user_id("alice"))

    def test_keeps_readable_prefix(self):
        self.assertTrue(auth.derive_user_id("alice").startswith("alice_"))

    def test_punctuation_variants_do_not_collide(self):
        """只做字符替换的话 ``a.b`` 和 ``a-b`` 会合并成同一个人。"""
        self.assertNotEqual(auth.derive_user_id("a.b"), auth.derive_user_id("a-b"))

    def test_non_ascii_username_yields_safe_id(self):
        """user_id 会进容器名，容器名有字符集限制，不能出现非 ASCII。"""
        uid = auth.derive_user_id("张三")
        self.assertRegex(uid, r"^[A-Za-z0-9_-]+$")
        self.assertTrue(uid.startswith("user_"))

    def test_empty_username(self):
        self.assertTrue(auth.derive_user_id("").startswith("user_"))


class TestCurrentUserId(unittest.TestCase):
    """认证依赖的三个分支。"""

    def test_auth_mode_none_returns_none(self):
        with patch.object(auth, "AUTH_MODE", "none"):
            self.assertIsNone(_call_current_user_id(authenticated_user="alice"))

    def test_proxy_mode_without_header_returns_401(self):
        """头缺失 = 请求没经过 nginx，必须拒绝而不是"当匿名用户放行"。"""
        with patch.object(auth, "AUTH_MODE", "proxy"), \
             patch.object(auth, "INTERNAL_AUTH_TOKEN", ""):
            for value in (None, "", "   "):
                with self.subTest(header=value):
                    with self.assertRaises(HTTPException) as ctx:
                        _call_current_user_id(authenticated_user=value)
                    self.assertEqual(ctx.exception.status_code, 401)

    def test_proxy_mode_without_shared_token_skips_token_check(self):
        """**未配共享密钥时不校验 X-Internal-Auth —— 这条行为必须被钉住。**

        它是已知的降级形态：只配了 AUTH_MODE=proxy 而没配 INTERNAL_AUTH_TOKEN
        时，任何能连到 backend 的东西都能伪造 X-Authenticated-User。web_main.py
        的 lifespan 会为此打 WARNING，但**不会拒绝启动**（拒绝会让没配密钥的
        本机开发环境起不来）。

        写这条测试不是认可这个行为，而是让"它什么时候变"变得可见：如果哪天
        有人把它改成 fail-closed，这里会红，改动者必须显式更新这条断言。
        """
        with patch.object(auth, "AUTH_MODE", "proxy"), \
             patch.object(auth, "INTERNAL_AUTH_TOKEN", ""):
            self.assertEqual(
                _call_current_user_id(authenticated_user="alice"),
                auth.derive_user_id("alice"),
            )

    def test_proxy_mode_with_token_rejects_missing_or_wrong(self):
        """配了共享密钥后，缺失/错误/空串一律 401。"""
        with patch.object(auth, "AUTH_MODE", "proxy"), \
             patch.object(auth, "INTERNAL_AUTH_TOKEN", "s3cret"):
            for value in (None, "", "wrong", "s3cret "):
                with self.subTest(header=value):
                    with self.assertRaises(HTTPException) as ctx:
                        _call_current_user_id(authenticated_user="alice",
                                              internal_auth=value)
                    self.assertEqual(ctx.exception.status_code, 401)

    def test_proxy_mode_with_correct_token_passes(self):
        with patch.object(auth, "AUTH_MODE", "proxy"), \
             patch.object(auth, "INTERNAL_AUTH_TOKEN", "s3cret"):
            self.assertEqual(
                _call_current_user_id(authenticated_user=" alice ",
                                      internal_auth="s3cret"),
                auth.derive_user_id("alice"),
            )

    def test_header_missing_is_rejected_before_token_check(self):
        """两个条件同时不满足时，报的是"绕过了 nginx"而不是"密钥不对"。"""
        with patch.object(auth, "AUTH_MODE", "proxy"), \
             patch.object(auth, "INTERNAL_AUTH_TOKEN", "s3cret"):
            with self.assertRaises(HTTPException) as ctx:
                _call_current_user_id(authenticated_user=None, internal_auth="wrong")
            self.assertEqual(ctx.exception.status_code, 401)


class TestResolveUserId(unittest.TestCase):
    """认证身份优先于请求体里的 user_id。"""

    def test_authenticated_identity_wins(self):
        self.assertEqual(auth.resolve_user_id("alice_1", "bob_2"), "alice_1")

    def test_falls_back_to_requested_when_unauthenticated(self):
        """AUTH_MODE=none 时行为与改造前一致。"""
        self.assertEqual(auth.resolve_user_id(None, "bob_2"), "bob_2")

    def test_falls_back_to_default_when_both_missing(self):
        self.assertEqual(auth.resolve_user_id(None, None), auth.DEFAULT_USER_ID)


class TestAssertThreadOwner(unittest.TestCase):
    """会话归属校验。"""

    def test_none_authenticated_skips_check(self):
        """AUTH_MODE=none（user_id 为 None）不校验，保持本机开发行为不变。"""
        auth.assert_thread_owner("t1", owner="someone_else", user_id=None)

    def test_owner_match_passes(self):
        auth.assert_thread_owner("t1", owner="alice_1", user_id="alice_1")

    def test_owner_mismatch_is_403(self):
        with self.assertRaises(HTTPException) as ctx:
            auth.assert_thread_owner("t1", owner="bob_2", user_id="alice_1")
        self.assertEqual(ctx.exception.status_code, 403)

    def test_missing_owner_is_403_not_allow(self):
        """**归属记录为空也必须拒绝。**

        放行就变成"随便报一个 thread_id 就能读"—— 因为归属记录与展示消息是
        两张表，删除会话或某一侧写入失败都会留下孤儿 thread。
        """
        for owner in (None, ""):
            with self.subTest(owner=owner):
                with self.assertRaises(HTTPException) as ctx:
                    auth.assert_thread_owner("t1", owner=owner, user_id="alice_1")
                self.assertEqual(ctx.exception.status_code, 403)


if __name__ == "__main__":
    unittest.main()
