"""把交给评审 grader 的转录压缩到框架窗口之内。

`RubricMiddleware` 只把转录的尾部送进 grader（deepagents 0.7.x 里是
`_MAX_TRANSCRIPT_MESSAGES = 30`）。本项目一轮任务轻松 30+ 次工具调用，
每次调用产生「AI 消息 + 工具结果」两条，于是带着证据的那批 ERP 查询会被挤出
窗口，grader 只能看到结尾一段，得出「没有工具证据、疑似编造」的结论 ——
用户看得到正确回答，评审却永远不通过。

SDK 为此留了 `prepare_messages_for_grader` 钩子：**先跑这个变换，再对它的
返回值套窗口**。所以只要变换后的条数 ≤ 30，窗口就不会再截掉任何东西。

策略是保留头尾、压缩中间：

- 头：用户原始提问（verbatim）
- 中：本轮之前的工具活动压成一份 ledger —— 先列**全部**工具名（保证
  "调用过什么"这类证据一条不丢），再按预算附上每次调用的参数与结果摘要
- 尾：最近若干条 verbatim，让 grader 看到最终回答的原貌

不依赖任何私有常量或 monkeypatch，所以容器里重新 pip install 也不会失效。
"""

from __future__ import annotations

import json
from typing import Any

from langchain_core.messages import AIMessage, AnyMessage, ToolMessage

# 必须与 deepagents 的 `_MAX_TRANSCRIPT_MESSAGES` 对齐。写成常量并在下面
# 加断言式注释，是为了将来框架改了窗口时能一眼找到这里。
GRADER_MESSAGE_WINDOW = 30

# 尾部保留的条数。取 20 < GRADER_MESSAGE_WINDOW，保证「头 + ledger + 尾」
# 三部分合起来一定塞得进窗口。
_TAIL_MESSAGES = 20

# 中间那段的字符预算。超了就只保留工具名清单 + 靠前的调用明细。
_LEDGER_CHAR_BUDGET = 6000
_TOOL_ARGS_CHARS = 160
_TOOL_RESULT_CHARS = 300
_TEXT_CHARS = 160

# 标在摘要消息开头，方便排查时一眼认出这不是模型真的说过的话。
DIGEST_MARKER = "[transcript digest]"


def _text_of(msg: AnyMessage) -> str:
    """把消息内容压成纯文本。只取文本块，不展开图片等二进制块。"""
    content = getattr(msg, "content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
        return "\n".join(p for p in parts if p)
    return ""


def _brief(value: Any, limit: int) -> str:
    """单行化 + 截断，避免 ledger 里出现多行把一条证据撑成一片。"""
    if not isinstance(value, str):
        try:
            value = json.dumps(value, ensure_ascii=False)
        except (TypeError, ValueError):
            value = str(value)
    value = " ".join(value.split())
    if len(value) > limit:
        value = value[:limit] + "…"
    return value


def _role_label(msg: AnyMessage) -> str:
    if isinstance(msg, ToolMessage):
        return f"tool:{msg.name or 'tool'}"
    if isinstance(msg, AIMessage):
        return "assistant"
    return getattr(msg, "type", "message")


def _call_names(messages: list[AnyMessage]) -> list[str]:
    names: list[str] = []
    for msg in messages:
        for call in getattr(msg, "tool_calls", None) or []:
            names.append(call.get("name") or "tool")
    return names


def _ledger_lines(middle: list[AnyMessage]) -> list[str]:
    lines: list[str] = []
    for msg in middle:
        calls = getattr(msg, "tool_calls", None) or []
        for call in calls:
            lines.append(f"{call.get('name') or 'tool'}({_brief(call.get('args'), _TOOL_ARGS_CHARS)})")
        if isinstance(msg, ToolMessage):
            lines.append(f"  -> {_brief(_text_of(msg), _TOOL_RESULT_CHARS)}")
        elif not calls:
            text = _text_of(msg)
            if text:
                lines.append(f"[{_role_label(msg)}] {_brief(text, _TEXT_CHARS)}")
    return lines


def build_ledger(middle: list[AnyMessage]) -> str:
    """把一段消息压成「工具名清单 + 明细」的文本。"""
    if not middle:
        return ""
    names = _call_names(middle)
    chunks: list[str] = []
    if names:
        chunks.append(f"本轮早期工具调用（共 {len(names)} 次，按顺序）：" + ", ".join(names))

    lines = _ledger_lines(middle)
    used = 0
    kept: list[str] = []
    for index, line in enumerate(lines):
        if used + len(line) > _LEDGER_CHAR_BUDGET:
            kept.append(f"…另有 {len(lines) - index} 行早期明细因长度省略")
            break
        kept.append(line)
        used += len(line)
    if kept:
        chunks.append("\n".join(kept))
    return "\n\n".join(chunks)


def _find_original_prompt(messages: list[AnyMessage]) -> int:
    """定位用户原始提问的下标；找不到返回 -1。

    用 `is` 而不是 `==` —— LangChain 消息的相等比较是按内容来的，内容相同的
    两条消息会被判等，取到的下标可能不是真正那一条。
    """
    for index, msg in enumerate(messages):
        if getattr(msg, "type", "") != "human":
            continue
        if getattr(msg, "additional_kwargs", {}).get("lc_source") == "rubric_grader":
            continue
        return index
    return -1


def build_grader_messages(messages: list[AnyMessage]) -> list[AnyMessage]:
    """`prepare_messages_for_grader` 的实现。见模块 docstring。"""
    if len(messages) <= GRADER_MESSAGE_WINDOW:
        return list(messages)

    assert _TAIL_MESSAGES + 2 <= GRADER_MESSAGE_WINDOW, "头 + ledger + 尾必须塞得进窗口"

    tail_start = len(messages) - _TAIL_MESSAGES
    tail = messages[tail_start:]
    head_index = _find_original_prompt(messages)

    middle_start = 0 if head_index < 0 else head_index + 1
    middle = messages[middle_start:tail_start]

    prepared: list[AnyMessage] = []
    # 原始提问若已经落在尾部区间里就不重复添加，否则 grader 会看到两遍。
    if 0 <= head_index < tail_start:
        prepared.append(messages[head_index])

    ledger = build_ledger(middle)
    if ledger:
        prepared.append(AIMessage(content=f"{DIGEST_MARKER}\n{ledger}"))

    prepared.extend(tail)
    return prepared
