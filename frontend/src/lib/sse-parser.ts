import { SSEEvent } from "./types";

/**
 * SSE 流解析器
 * 将原始文本块解析为结构化的 SSE 事件
 */
export class SSEParser {
  private buffer: string = "";

  // **这两个必须是实例字段，不能是 parse() 的局部变量。**
  // 读取 chunk 的边界由 TCP/HTTP 分帧决定，可能正好切在 `event:` 行和
  // `data:` 行之间：那种情况下 `event: token` 这一行会在本次 parse() 里被读到、
  // 存进局部变量，函数返回时随局部变量一起消失；下一次 parse() 只看见
  // `data: ...`，于是空行处的 `currentEvent &&` 判定为假，**这个 token 静默
  // 丢掉**（不报错、不重试，界面上就是少了一截字）。解析器跨块的状态只有
  // buffer 一份是不够的，事件名与数据也必须一起跨块。
  private currentEvent = "";
  private currentData = "";

  /**
   * 输入原始文本块，返回解析出的事件数组
   */
  parse(chunk: string): SSEEvent[] {
    this.buffer += chunk;
    const events: SSEEvent[] = [];
    const lines = this.buffer.split("\n");

    // 保留最后一个可能不完整的行
    this.buffer = lines.pop() || "";

    for (const line of lines) {
      if (line.startsWith("event:")) {
        this.currentEvent = line.slice(6).trim();
      } else if (line.startsWith("data:")) {
        this.currentData = line.slice(5).trim();
      } else if (line.trim() === "" && this.currentEvent && this.currentData) {
        // 空行表示事件结束。判定用 trim() === "" 而不是 === "" 以容忍 CRLF：
        // 按 "\n" 切分后 CRLF 的空行是 "\r"，`=== ""` 会漏掉它，整条流一个
        // 事件都解析不出来（值那边已经有 .trim()，只有这里漏了）。
        const { currentEvent, currentData } = this;
        try {
          const parsed = JSON.parse(currentData);
          const event: SSEEvent = { type: currentEvent, ...parsed };
          events.push(event);
        } catch {
          // 非 JSON data，构造简单事件
          if (currentEvent === "token") {
            events.push({
              type: "token",
              content: currentData,
              source: "main",
            });
          }
        }
        this.currentEvent = "";
        this.currentData = "";
      }
    }

    return events;
  }

  reset(): void {
    // 三份状态一起清：只清 buffer 会留下半个事件，下一个流的第一块会拿它
    // 拼出一个内容错乱的事件（换成新会话时会发生）。
    this.buffer = "";
    this.currentEvent = "";
    this.currentData = "";
  }
}
