"""基于 LLM 知识的信息检索工具（通过 ChatAnywhere 网关调用）。

注意：本工具并非真正的联网搜索，而是调用标准 OpenAI 兼容的
chat/completions 接口，由 LLM 基于自身训练数据生成回答。
如需真实的实时联网搜索能力，需要接入专门的搜索 API（如 Tavily、Serper）
或支持 web_search 工具的模型。
"""

import httpx
from langchain_core.tools import tool

from ..env_utils import get_env
from ..log_utils import agent_logger


@tool
def web_search(query: str) -> str:
    """基于 LLM 知识库回答用户查询（非实时联网搜索）。

    Args:
        query: 查询内容，例如"摩托车火花塞市场价格趋势 2026"

    Returns:
        LLM 生成的信息摘要文本。
    """
    # 主 Agent、grader 和本工具统一使用 ChatAnywhere key。
    api_key = get_env("CHATANYWHERE_API_KEY", "")
    if not api_key:
        return "错误: 未配置 CHATANYWHERE_API_KEY，无法执行搜索"

    base_url = get_env(
        "LLM_BASE_URL", "https://api.chatanywhere.tech/v1"
    ).rstrip("/")
    # 本工具走标准 chat/completions 接口（非搜索专用接口），
    # 但允许单独指定模型，避免复用主对话的 LLM_MODEL 配置。
    model = get_env("WEB_SEARCH_MODEL", get_env("LLM_MODEL", "gpt-4o-mini"))

    try:
        response = httpx.post(
            f"{base_url}/chat/completions",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": model,
                "messages": [
                    {
                        "role": "system",
                        "content": (
                            "你是一个信息检索助手。请基于你的知识，"
                            "针对用户的查询提供简洁、准确的信息摘要。"
                            "如果某些信息可能已过时、无法确认或不在你的知识范围内，"
                            "请明确说明，切勿编造。"
                        ),
                    },
                    {"role": "user", "content": query},
                ],
                "temperature": 0.3,
                "max_tokens": 2000,
            },
            timeout=30,
        )

        if response.status_code == 200:
            result = response.json()
            content = (
                result.get("choices", [{}])[0]
                .get("message", {})
                .get("content", "")
            )
            if not content:
                return "搜索成功，但模型没有返回可读内容"
            agent_logger.info(f"Web search completed for: {query[:50]}")
            return content
        else:
            try:
                error = response.json().get("error", {}).get(
                    "message", str(response.status_code)
                )
            except Exception:
                error = response.text or str(response.status_code)
            return f"搜索失败: {error}"

    except httpx.TimeoutException:
        return "搜索超时，请稍后重试"
    except Exception as e:
        agent_logger.error(f"Web search error: {e}")
        return f"搜索异常: {str(e)}"
