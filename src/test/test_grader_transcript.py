"""评审转录压缩的回归测试。

核心断言是「证据真的走到了 grader 手里」——所以不给 SDK 打桩，直接调它真实的
`_build_grader_transcript`，看最终那段发给 grader 的文本里有没有早期工具调用。
"""

import unittest

from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

from src.agent.middlewares.grader_transcript import (
    DIGEST_MARKER,
    GRADER_MESSAGE_WINDOW,
    build_grader_messages,
)


def _turn(tool_calls: int) -> list:
    """造一轮对话：用户提问 + tool_calls 次「工具调用 / 工具结果」往返。"""
    messages: list = [HumanMessage(content="统计一下供应商总数并出图")]
    for i in range(tool_calls):
        messages.append(
            AIMessage(
                content="",
                tool_calls=[{"name": f"tool_{i:02d}", "args": {"q": f"arg-{i:02d}"}, "id": f"call-{i}"}],
            )
        )
        messages.append(ToolMessage(content=f'{{"code":0,"data":"result-{i:02d}"}}', tool_call_id=f"call-{i}", name=f"tool_{i:02d}"))
    messages.append(AIMessage(content="共 42 家供应商。"))
    return messages


class GraderTranscriptTests(unittest.TestCase):
    def test_window_matches_installed_sdk(self):
        """框架改了窗口就必须回来改这里的常量，而不是静默失效。"""
        from deepagents.middleware import rubric

        self.assertEqual(
            rubric._MAX_TRANSCRIPT_MESSAGES,
            GRADER_MESSAGE_WINDOW,
            "deepagents 的转录窗口变了，grader_transcript.GRADER_MESSAGE_WINDOW 需要同步",
        )

    def test_short_transcript_passes_through_untouched(self):
        messages = _turn(3)
        self.assertLessEqual(len(messages), GRADER_MESSAGE_WINDOW)
        self.assertEqual(build_grader_messages(messages), messages)

    def test_long_transcript_fits_window(self):
        prepared = build_grader_messages(_turn(32))
        self.assertLessEqual(len(prepared), GRADER_MESSAGE_WINDOW)
        # 窗口是作用在返回值上的，返回值的长度就是 grader 实际能看到的条数
        self.assertEqual(len(prepared), 1 + 1 + 20)  # 提问 + digest + 尾部

    def test_early_tool_evidence_reaches_the_grader(self):
        """这是这个 bug 的核心：32 次工具调用时，第 0 次调用的证据不能被丢掉。"""
        from deepagents.middleware.rubric import _build_grader_transcript

        transcript = _build_grader_transcript(build_grader_messages(_turn(32)))

        # 早期调用的名字与结果都还在
        self.assertIn("tool_00", transcript)
        self.assertIn("result-00", transcript)
        # 全部 32 次调用的名字都在（ledger 的清单行保证一条不丢）
        for i in range(32):
            self.assertIn(f"tool_{i:02d}", transcript)
        # 最终回答保持原样
        self.assertIn("共 42 家供应商。", transcript)
        self.assertIn(DIGEST_MARKER, transcript)

    def test_without_the_fix_the_evidence_is_lost(self):
        """反向断言：不压缩时（= 修复前）早期证据确实会丢。

        这条测试是修复有效性的对照 —— 如果哪天框架把窗口改大了，它会失败，
        提醒我们这条修复可以退休了。
        """
        from deepagents.middleware.rubric import _build_grader_transcript

        transcript = _build_grader_transcript(_turn(32))
        self.assertNotIn("result-00", transcript)

    def test_original_prompt_is_not_duplicated(self):
        messages = _turn(32)
        prepared = build_grader_messages(messages)
        prompts = [m for m in prepared if isinstance(m, HumanMessage)]
        self.assertEqual(len(prompts), 1)

    def test_identical_prompt_messages_do_not_confuse_head_lookup(self):
        """内容相同的两条 human 消息不能让我们定位错下标。"""
        filler = HumanMessage(content="同样的一句话")
        messages = [filler, HumanMessage("同样的一句话")] + _turn(32)[1:]
        prepared = build_grader_messages(messages)
        self.assertLessEqual(len(prepared), GRADER_MESSAGE_WINDOW)
        self.assertIs(prepared[0], messages[0])

    def test_transcript_without_human_message_still_compresses(self):
        messages = _turn(32)[1:]
        prepared = build_grader_messages(messages)
        self.assertLessEqual(len(prepared), GRADER_MESSAGE_WINDOW)


if __name__ == "__main__":
    unittest.main()
