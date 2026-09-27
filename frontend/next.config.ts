import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // 产出 .next/standalone（自带最小 node_modules），运行镜像不必带完整依赖树。
  output: "standalone",

  // 这里原先有一条 /api/:path* → http://localhost:8000/api/:path* 的 rewrite。
  // 它从未生效过：src/lib/api.ts 一直用绝对 URL，浏览器直接打到 8000 端口，
  // 绕过了 Next 服务。改成相对路径 /api 之后如果不删掉它，请求会被 Next
  // 接住并转发到容器内并不存在的 localhost:8000。反代统一由 nginx 负责。
};

export default nextConfig;
