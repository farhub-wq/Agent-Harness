import { defineConfig } from "vitest/config";

// 只测纯逻辑（src/lib/**）：URL 拼接、错误分支、SSE 解析。
// 刻意**不上 jsdom + React Testing Library** —— 现在一个组件测试都没有，
// 装了就是 200 多个包白白进 `npm ci`（CI 每个 PR 都要付这个钱）。
// 哪天要测组件，再加 `environment: "jsdom"` 与那两个依赖，那时成本才有着落。
export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
    // 测试文件排除在构建产物之外；这里再排除一次是为了让 `vitest --watch`
    // 不去扫 .next 里 Next 自己生成的产物。
    exclude: ["node_modules/**", ".next/**"],
  },
});
