# Next.js 16 standalone 多阶段构建
FROM node:22-alpine AS deps
WORKDIR /app
# 国内直连 registry.npmjs.org 基本拉不动。npm 10 默认 replace-registry-host=npmjs，
# 会把 package-lock.json 里写死的 registry.npmjs.org 换成这里指定的源。
ARG NPM_REGISTRY=https://registry.npmmirror.com
COPY package.json package-lock.json ./
RUN npm ci --registry="$NPM_REGISTRY"

FROM node:22-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3000

# HOSTNAME 必须在运行时显式设为 0.0.0.0：standalone 的 server.js 读的是
# process.env.HOSTNAME，而容器里这个变量默认是容器 ID，会导致 bind 失败。
# 这里给个默认值，compose 里再覆盖一次以防被继承的镜像 ENV 影响。
ENV HOSTNAME=0.0.0.0

COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public

EXPOSE 3000
CMD ["node", "server.js"]
