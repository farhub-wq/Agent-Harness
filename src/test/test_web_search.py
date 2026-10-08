"""web_search 工具的离线回归测试（不触发真实 ChatAnywhere 请求）。"""
from __future__ import annotations

import unittest
from unittest.mock import patch

from src.agent.tools.web_search import web_search


class WebSearchTests(unittest.TestCase):
    def test_uses_chatanywhere_key_and_chat_completions(self):
        class Response:
            status_code = 200
            text = ""

            @staticmethod
            def json():
                return {
                    "choices": [
                        {"message": {"content": "搜索摘要结果"}}
                    ]
                }

        with patch(
            "src.agent.tools.web_search.get_env",
            side_effect=lambda key, default="": {
                "CHATANYWHERE_API_KEY": "test-key",
                "LLM_BASE_URL": "https://api.chatanywhere.tech/v1",
                "LLM_MODEL": "gpt-4o-mini",
                "WEB_SEARCH_MODEL": "gpt-4o-mini",
            }.get(key, default),
        ), patch(
            "src.agent.tools.web_search.httpx.post", return_value=Response()
        ) as post:
            result = web_search.invoke({"query": "测试查询"})

        self.assertEqual(result, "搜索摘要结果")
        self.assertEqual(
            post.call_args.args[0],
            "https://api.chatanywhere.tech/v1/chat/completions",
        )
        payload = post.call_args.kwargs["json"]
        self.assertEqual(payload["model"], "gpt-4o-mini")
        self.assertEqual(payload["messages"][1]["content"], "测试查询")

    def test_missing_api_key_returns_error(self):
        with patch(
            "src.agent.tools.web_search.get_env",
            return_value="",
        ):
            result = web_search.invoke({"query": "测试查询"})
        self.assertIn("CHATANYWHERE_API_KEY", result)

    def test_non_200_returns_error_message(self):
        class Response:
            status_code = 401
            text = "Unauthorized"

            @staticmethod
            def json():
                return {"error": {"message": "invalid api key"}}

        with patch(
            "src.agent.tools.web_search.get_env",
            side_effect=lambda key, default="": {
                "CHATANYWHERE_API_KEY": "bad-key",
                "LLM_BASE_URL": "https://api.chatanywhere.tech/v1",
                "WEB_SEARCH_MODEL": "gpt-4o-mini",
            }.get(key, default),
        ), patch(
            "src.agent.tools.web_search.httpx.post", return_value=Response()
        ):
            result = web_search.invoke({"query": "测试查询"})
        self.assertIn("搜索失败", result)
        self.assertIn("invalid api key", result)


if __name__ == "__main__":
    unittest.main()
