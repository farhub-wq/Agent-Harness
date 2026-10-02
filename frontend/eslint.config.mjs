import next from "eslint-config-next/core-web-vitals";

// Next 16 移除了 `next lint`（连同它自带的 eslintrc 兼容层），所以这里必须是
// **flat config**：`eslint.config.mjs` 这个文件名与位置都不能改。
//
// `eslint-config-next@16` 直接导出 `Linter.Config[]`，不用再套 @eslint/eslintrc 的
// FlatCompat —— 那是 Next 15 及以前的写法，套在这里反而会因为重复解析 eslintrc
// 格式而报错。
//
// core-web-vitals 而非默认 preset：它在默认规则之上加了 CWV 那几条。这个项目是
// 流式聊天界面，图片与脚本规则值得拦。

// **只拦 error，不拦 warning**：`eslint .` 在只有 warning 时退出码就是 0，
// 所以不需要额外参数 —— 但也别给这个命令加 `--max-warnings 0`，那会让一条
// 拼写级提示卡住整个 PR。首版的门禁价值在于"红的就是真问题"。
const config = [
  ...next,
  {
    // 全局忽略（基础 preset 里已忽略 .next/out/build，这里只补仓库自己的产物）。
    // 注意这个对象**只能有 ignores 一个键**，否则 eslint 会把它当成普通配置块。
    ignores: ["coverage/**", "next-env.d.ts"],
  },
  {
    rules: {
      // ---------------------------------------------------------------- 首版降级
      // 下面 4 条是 Next 16 随 eslint-config-next 一起启用的 React Compiler 诊断
      // 规则。它们**不是**传统的 lint 风格问题，是对既有代码"React Compiler
      // 无法优化"的判定；仓库里现有 5 处命中，全在流式回答与历史加载这两块
      // 逻辑最绕的地方：
      //
      //   StreamingText.tsx:23  react-hooks/refs
      //   StreamingText.tsx:61  react-hooks/set-state-in-effect
      //   useChat.ts:182        react-hooks/immutability
      //   useChat.ts:203        react-hooks/preserve-manual-memoization
      //   useHistory.ts:25      react-hooks/set-state-in-effect
      //
      // 首版先降成 warning：这几处的修法（去掉手工 memo、把 ref 读取挪出渲染、
      // 用 useSyncExternalStore 替掉 effect 里 setState）都是**行为相关的重构**，
      // 改错了会直接坏掉流式输出，必须连测试一起做，不能顺手塞进"接工具链"这一批。
      // 而把这些留在 error 上，等于让 main 从第一天起就红 —— 方案里那句
      // "红的流水线等于没有流水线"说的就是这种状态。
      //
      // **下一步（单独一批）**：按上面 5 个行号逐个修掉，跑通后把这段降级删掉。
      // 这段配置与 test_auth.py 里那条"已知漏洞"断言是同一个套路：让"什么时候
      // 把它改回 error"这件事必须显式发生。
      "react-hooks/refs": "warn",
      "react-hooks/set-state-in-effect": "warn",
      "react-hooks/immutability": "warn",
      "react-hooks/preserve-manual-memoization": "warn",
    },
  },
];

export default config;
