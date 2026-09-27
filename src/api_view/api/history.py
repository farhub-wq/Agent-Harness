"""
历史会话管理
会话列表 / 消息查询 / 会话删除
"""
from fastapi import APIRouter, Depends, Query

from ..agent_loader import agent_loader
from ..auth import assert_thread_owner, current_user_id, resolve_user_id

router = APIRouter(prefix="/api/history", tags=["history"])


@router.get("")
async def list_conversations(
    user_id: str = Query(default="default_user"),
    authenticated: str | None = Depends(current_user_id),
):
    """获取会话列表"""
    conversations = await agent_loader.get_conversations(
        resolve_user_id(authenticated, user_id)
    )
    return {"conversations": conversations}


@router.get("/{thread_id}/messages")
async def get_messages(
    thread_id: str,
    authenticated: str | None = Depends(current_user_id),
):
    """获取指定会话的消息列表"""
    owner = await agent_loader.get_conversation_user_id(thread_id)
    assert_thread_owner(thread_id, owner, authenticated)
    messages = await agent_loader.get_display_messages(thread_id)
    return {"thread_id": thread_id, "messages": messages}


@router.delete("/{thread_id}")
async def delete_conversation(
    thread_id: str,
    authenticated: str | None = Depends(current_user_id),
):
    """删除会话"""
    owner = await agent_loader.get_conversation_user_id(thread_id)
    assert_thread_owner(thread_id, owner, authenticated)
    await agent_loader.delete_conversation(thread_id)
    return {"success": True, "message": f"会话 {thread_id} 已删除"}
