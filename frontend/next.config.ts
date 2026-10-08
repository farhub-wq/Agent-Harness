import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // 产出 .next/standalone（自带最小 node_modules），运行镜像不必带完整依赖树。
  output: "standalone",

  // 仅本地开发模式（npm run dev）把 /api/* 代理到后端 8000 端口。
  // 生产（Docker）环境下由 nginx 统一反代，rewrite 必须关闭——否则
  // Next 会把 /api 请求转发到容器内不存在的 localhost:8000。
  async rewrites() {
    if (process.env.NODE_ENV === "development") {
      return [
        {
          source: "/api/:path*",
          destination: "http://localhost:8000/api/:path*",
        },
      ];
    }
    return [];
  },
};

export default nextConfig;
