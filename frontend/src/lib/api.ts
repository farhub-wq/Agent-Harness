import { Conversation, ChatRequest, ResumeRequest } from "./types";

// 默认相对路径：由 nginx 把 /api/ 反代到 backend，浏览器与 API 同源，
// 既不用管 CORS，也不用为每个部署域名重新构建镜像。
// NEXT_PUBLIC_ 前缀是必需的——这个模块在浏览器里执行，非 NEXT_PUBLIC_ 的
// 变量会在客户端 bundle 里变成 undefined。
export const BASE_URL =
  process.env.NEXT_PUBLIC_API_BASE_URL ?? "/api";

// ===== 对话 API =====
export async function streamChat(
  request: ChatRequest,
  onChunk: (chunk: string) => void,
  signal?: AbortSignal
): Promise<void> {
  const response = await fetch(`${BASE_URL}/chat/stream`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
    signal,
  });

  if (!response.ok) {
    throw new Error(`Stream failed: ${response.status}`);
  }

  const reader = response.body?.getReader();
  if (!reader) throw new Error("No response body");

  const decoder = new TextDecoder();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    onChunk(decoder.decode(value, { stream: true }));
  }
}

export async function resumeChat(
  request: ResumeRequest,
  onChunk: (chunk: string) => void,
  signal?: AbortSignal
): Promise<void> {
  const response = await fetch(
    `${BASE_URL}/chat/${request.thread_id}/resume`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(request),
      signal,
    }
  );

  if (!response.ok) {
    throw new Error(`Resume failed: ${response.status}`);
  }

  const reader = response.body?.getReader();
  if (!reader) throw new Error("No response body");

  const decoder = new TextDecoder();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    onChunk(decoder.decode(value, { stream: true }));
  }
}

export async function getChatState(threadId: string) {
  const res = await fetch(`${BASE_URL}/chat/${threadId}/state`);
  if (!res.ok) throw new Error(`State failed: ${res.status}`);
  return res.json();
}

// ===== 历史 API =====
// 仅本机开发（AUTH_MODE=none）下生效。容器部署走 nginx Basic Auth，backend
// 会用认证身份覆盖这个值并把它丢弃 —— 前端改它不会、也不能切到别人的会话。
const USER_ID = "user-001";

export async function getConversations(): Promise<Conversation[]> {
  const res = await fetch(`${BASE_URL}/history?user_id=${USER_ID}`);
  if (!res.ok) throw new Error(`History failed: ${res.status}`);
  const data = await res.json();
  return data.conversations ?? [];
}

export async function getMessages(threadId: string) {
  const res = await fetch(`${BASE_URL}/history/${threadId}/messages`);
  if (!res.ok) throw new Error(`Messages failed: ${res.status}`);
  const data = await res.json();
  return data.messages ?? [];
}

export async function deleteConversation(threadId: string): Promise<void> {
  const res = await fetch(`${BASE_URL}/history/${threadId}`, {
    method: "DELETE",
  });
  if (!res.ok) throw new Error(`Delete failed: ${res.status}`);
}
