import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { ChatRequest } from "../types";

/**
 * `src/lib/api.ts` 的两类断言：
 *
 * 1. **基址必须是相对路径 `/api`** —— 这是「同一个前端镜像在任何环境都能用」
 *    的根据（方案约束 D）。`NEXT_PUBLIC_*` 是**构建期内联**的，一旦有人把后端
 *    绝对地址烧进去，镜像就绑死在某个环境上。这条在 CI 里还有第二道（对
 *    **构建产物** grep），两条都要：这条在 PR 里就给出人话失败原因，那条才能
 *    抓住"只在构建期发生"的泄漏。
 * 2. 错误分支：`!res.ok` 必须抛，不能把 401/500 的响应体当数据往下传。
 *    nginx 认不出身份时首页返回 401 的 HTML —— 静默吞掉会让聊天窗显示
 *    "{}" 而不是"没登录"。
 */

/** 每个用例都要重新 import：`BASE_URL` 是模块级常量，读的是 import 那一刻的 env。 */
async function loadApi(apiBaseUrl?: string) {
  vi.resetModules();
  if (apiBaseUrl === undefined) {
    delete process.env.NEXT_PUBLIC_API_BASE_URL;
  } else {
    process.env.NEXT_PUBLIC_API_BASE_URL = apiBaseUrl;
  }
  return import("../api");
}

const jsonResponse = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });

/** 造一个完整的 ChatRequest —— 只写个别字段会让 tsc 报缺字段。 */
const chatRequest = (overrides: Partial<ChatRequest> = {}): ChatRequest => ({
  message: "hi",
  thread_id: "t-1",
  user_id: "user-001",
  username: "tester",
  ...overrides,
});

/** 分块吐字节的响应，用来验证 `decode(value, {stream:true})` 的边界处理。 */
const streamResponse = (chunks: string[]) => {
  const encoder = new TextEncoder();
  return new Response(
    new ReadableStream({
      start(controller) {
        for (const c of chunks) controller.enqueue(encoder.encode(c));
        controller.close();
      },
    }),
  );
};

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
  delete process.env.NEXT_PUBLIC_API_BASE_URL;
});

describe("BASE_URL", () => {
  it("默认是相对路径 /api（镜像与环境无关）", async () => {
    const { BASE_URL } = await loadApi();
    expect(BASE_URL).toBe("/api");
  });

  it("允许用 NEXT_PUBLIC_API_BASE_URL 覆盖", async () => {
    const { BASE_URL } = await loadApi("https://example.test/api");
    expect(BASE_URL).toBe("https://example.test/api");
  });

  it("环境变量是空串时会退化成根路径（已知坑，不是设计）", async () => {
    // `?? ` 只挡 null/undefined，挡不住空串。若构建时把
    // NEXT_PUBLIC_API_BASE_URL 设成 ""，BASE_URL 会变成 ""，所有请求打到
    // /chat/stream 而不是 /api/chat/stream → 全 404，且现象看着像 nginx 坏了。
    //
    // 写这条不是认可这个行为，是让它变得可见：谁哪天把 `??` 改成 `||`，
    // 这里会红，改动者必须显式更新这条断言。
    const { BASE_URL } = await loadApi("");
    expect(BASE_URL).toBe("");
  });
});

describe("streamChat", () => {
  it("POST 到 /chat/stream 并把分块内容交给 onChunk", async () => {
    const { streamChat, BASE_URL } = await loadApi();
    fetchMock.mockResolvedValue(streamResponse(["event: token\n", 'data: {"content":"你', '好"}\n\n']));

    const chunks: string[] = [];
    const request = chatRequest({ message: "你好", thread_id: "t-42" });
    await streamChat(request, (c) => chunks.push(c));

    expect(BASE_URL).toBe("/api");
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("/api/chat/stream");
    expect(init.method).toBe("POST");
    // 请求体必须原样发出去：`username` 是后端唯一认得的展示名来源，掉了就变成
    // 匿名会话（而 AUTH_MODE=proxy 下 user_id 由 nginx 决定，掉了不影响归属 ——
    // 所以这个字段丢了不会报错，只会静默显示错名字，更需要钉住）。
    expect(JSON.parse(init.body)).toEqual(request);
    // 分块边界不能丢字符：拼起来必须与原始流逐字相同。
    expect(chunks.join("")).toBe('event: token\ndata: {"content":"你好"}\n\n');
  });

  it("非 2xx 抛错并带上状态码", async () => {
    const { streamChat } = await loadApi();
    fetchMock.mockResolvedValue(new Response("unauthorized", { status: 401 }));

    await expect(streamChat(chatRequest(), () => {})).rejects.toThrow(
      "Stream failed: 401",
    );
  });

  it("响应没有 body 时抛错，而不是静默成功", async () => {
    // 静默成功会让上层的流式 UI 永远停在"思考中"。
    const { streamChat } = await loadApi();
    fetchMock.mockResolvedValue({ ok: true, body: null });

    await expect(streamChat(chatRequest(),() => {})).rejects.toThrow(
      "No response body",
    );
  });

  it("把 signal 透传给 fetch（用于「停止生成」）", async () => {
    const { streamChat } = await loadApi();
    fetchMock.mockResolvedValue(streamResponse([]));

    const controller = new AbortController();
    await streamChat(chatRequest(),() => {}, controller.signal);

    expect(fetchMock.mock.calls[0][1].signal).toBe(controller.signal);
  });
});

describe("resumeChat", () => {
  it("POST 到 /chat/{id}/resume", async () => {
    const { resumeChat } = await loadApi();
    fetchMock.mockResolvedValue(streamResponse([]));

    await resumeChat(
      { thread_id: "t-1", resume_data: { action: "approve" } },
      () => {},
    );

    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("/api/chat/t-1/resume");
    expect(init.method).toBe("POST");
  });
});

describe("历史 API", () => {
  it("getConversations 取 data.conversations，缺字段时给空数组", async () => {
    const { getConversations } = await loadApi();

    fetchMock.mockResolvedValue(jsonResponse({ conversations: [{ thread_id: "t-1" }] }));
    await expect(getConversations()).resolves.toEqual([{ thread_id: "t-1" }]);

    // 后端换字段名或返回了别的东西时应当是"空列表"，不是 undefined ——
    // undefined 会让调用方的 .map 炸在组件里，报错位置离原因很远。
    fetchMock.mockResolvedValue(jsonResponse({}));
    await expect(getConversations()).resolves.toEqual([]);
  });

  it("getMessages 取 data.messages，缺字段时给空数组", async () => {
    const { getMessages } = await loadApi();

    fetchMock.mockResolvedValue(jsonResponse({ messages: [{ role: "user" }] }));
    await expect(getMessages("t-1")).resolves.toEqual([{ role: "user" }]);

    fetchMock.mockResolvedValue(jsonResponse({}));
    await expect(getMessages("t-1")).resolves.toEqual([]);
  });

  it("deleteConversation 用 DELETE，非 2xx 抛错", async () => {
    const { deleteConversation } = await loadApi();

    fetchMock.mockResolvedValue(new Response(null, { status: 200 }));
    await deleteConversation("t-1");
    expect(fetchMock.mock.calls[0][0]).toBe("/api/history/t-1");
    expect(fetchMock.mock.calls[0][1].method).toBe("DELETE");

    // 403（删别人的会话）必须冒出来，否则 UI 会以为删成功了。
    fetchMock.mockResolvedValue(new Response(null, { status: 403 }));
    await expect(deleteConversation("t-1")).rejects.toThrow("Delete failed: 403");
  });

  it("getChatState 非 2xx 抛错", async () => {
    const { getChatState } = await loadApi();
    fetchMock.mockResolvedValue(new Response(null, { status: 500 }));
    await expect(getChatState("t-1")).rejects.toThrow("State failed: 500");
  });
});
