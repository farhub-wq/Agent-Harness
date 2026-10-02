import { describe, expect, it } from "vitest";

import { SSEParser } from "../sse-parser";

/**
 * `SSEParser` 的跨块行为。
 *
 * 这个解析器是流式回答的唯一入口，它的失败方式全是**静默**的：丢一个 token
 * 不报错、不重试，界面上只是少几个字。所以这里测的重点不是"正常路径能解析"，
 * 而是"在任意位置被切开时一个字都不能丢" —— 而 chunk 边界由 TCP/HTTP 分帧
 * 决定，不受我们控制。
 *
 * 后端固定发 `event: X\ndata: {单行 JSON}\n\n`（见 src/api_view/api/chat.py
 * 的 sse_event()），测试数据按这个形状来。
 */

/** 一次喂一块，把各块返回的事件摊平。 */
const feed = (parser: SSEParser, chunks: string[]) =>
  chunks.flatMap((c) => parser.parse(c));

const TOKEN_CHUNK = 'event: token\ndata: {"content":"你好","source":"main"}\n\n';

describe("单块解析", () => {
  it("解析一个完整事件", () => {
    const events = new SSEParser().parse(TOKEN_CHUNK);
    expect(events).toEqual([{ type: "token", content: "你好", source: "main" }]);
  });

  it("一个块里的多个事件全部解析", () => {
    const events = new SSEParser().parse(`event: token\ndata: {"content":"a"}\n\nevent: done\ndata: {"thread_id":"t-1","interrupted":false}\n\n`);
    expect(events).toEqual([
      { type: "token", content: "a" },
      { type: "done", thread_id: "t-1", interrupted: false },
    ]);
  });

  it("没有结尾空行时不提前发出事件", () => {
    // 少一个 \n 就还没结束 —— 提前发出去会把后续 data 切成两个事件。
    const parser = new SSEParser();
    expect(parser.parse('event: token\ndata: {"content":"a"}')).toEqual([]);
    expect(parser.parse("\n\n")).toEqual([{ type: "token", content: "a" }]);
  });
});

describe("跨块边界（chunk 由 TCP 分帧决定，切在哪都合法）", () => {
  it("在 event: 行与 data: 行之间被切开", () => {
    // 这是本文件存在的主要原因：事件名必须和 buffer 一起跨块保存。
    // 之前 currentEvent/currentData 是 parse() 的局部变量，这种切法会把这个
    // token 静默丢掉 —— 不报错、不重试，只是回答少一截。
    const parser = new SSEParser();
    expect(feed(parser, ["event: token\n", 'data: {"content":"你', '好"}\n\n'])).toEqual([
      { type: "token", content: "你好" },
    ]);
  });

  it("逐字节喂也能还原（最坏的切分）", () => {
    const parser = new SSEParser();
    const events = feed(parser, TOKEN_CHUNK.split(""));
    expect(events).toEqual([{ type: "token", content: "你好", source: "main" }]);
  });

  it("在 JSON 中间被切开不会解析出半个对象", () => {
    const parser = new SSEParser();
    // 切在 UTF-8 多字节字符中间也不会出乱码：decode 侧用 {stream:true}，
    // 这里模拟的是解码后的字符串被切开。
    const events = feed(parser, [
      'event: tool_result\ndata: {"name":"erp_c',
      'all","content":"ok"}\n\n',
    ]);
    expect(events).toEqual([{ type: "tool_result", name: "erp_call", content: "ok" }]);
  });

  it("连续多个事件跨块不会串味", () => {
    const parser = new SSEParser();
    const events = feed(parser, [
      "event: token\ndata:",
      ' {"content":"a"}\n\nevent: token\ndata: {"content":"b"}',
      "\n\n",
    ]);
    expect(events).toEqual([
      { type: "token", content: "a" },
      { type: "token", content: "b" },
    ]);
  });
});

describe("容错", () => {
  it("data 不是 JSON 时，token 降级成纯文本事件", () => {
    // 老版本后端发过不带 JSON 的裸 token；保留这条兼容路径。
    expect(new SSEParser().parse("event: token\ndata: 裸文本\n\n")).toEqual([
      { type: "token", content: "裸文本", source: "main" },
    ]);
  });

  it("data 不是 JSON 且事件名不是 token 时丢弃，且不污染下一个事件", () => {
    const parser = new SSEParser();
    expect(parser.parse("event: tool_start\ndata: 不是 JSON\n\n")).toEqual([]);
    // 上一个事件的残留数据不该被下一个事件复用。
    expect(parser.parse(TOKEN_CHUNK)).toEqual([
      { type: "token", content: "你好", source: "main" },
    ]);
  });

  it("只有空行 / 只有 event 没有 data 时不发事件", () => {
    expect(new SSEParser().parse("\n\n")).toEqual([]);
    // 心跳（某些代理会插空行）不能变成垃圾事件。
    expect(new SSEParser().parse("event: ping\n\n")).toEqual([]);
  });

  it("容忍 CRLF：按 \\n 切分后空行是 \\r，不能因此整条流解析不出东西", () => {
    const events = new SSEParser().parse(TOKEN_CHUNK.replace(/\n/g, "\r\n"));
    expect(events).toEqual([{ type: "token", content: "你好", source: "main" }]);
  });

  it("reset 清空三份状态（buffer 与半个事件）", () => {
    const parser = new SSEParser();
    parser.parse('event: token\ndata: {"content":"半个');
    parser.reset();

    // 换会话后如果只清 buffer，这半截会被拼到新会话的第一块上，
    // 生成一个内容错乱的事件。
    expect(parser.parse(TOKEN_CHUNK)).toEqual([
      { type: "token", content: "你好", source: "main" },
    ]);
  });
});

describe("载荷形状", () => {
  it("JSON 里的 type 会覆盖 event: 行（展开顺序所致）", () => {
    // `{ type: currentEvent, ...parsed }` —— 后端现在不发 type 字段，所以
    // 这是潜伏的：哪天有人给 data 里加个 type，事件类型会静默变成 data 里的
    // 那个值，路由到错误的处理分支。钉住它，改顺序时这里会红。
    const events = new SSEParser().parse('event: token\ndata: {"type":"done"}\n\n');
    expect(events).toEqual([{ type: "done" }]);
  });
});
