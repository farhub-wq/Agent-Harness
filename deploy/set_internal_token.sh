#!/usr/bin/env sh
# 生成 / 更新 backend 与 nginx 之间的共享密钥（INTERNAL_AUTH_TOKEN）。
#
# 为什么需要这个脚本：这个值必须同时出现在两处 ——
#   deploy/.env        （backend 读，用来校验）
#   deploy/nginx.env   （nginx 读，渲染成 X-Internal-Auth 注入头）
# 手工同步迟早写歪，写歪的表现是"所有 /api 请求 401"，很难一眼看出原因。
# 所以由本脚本一次写入两处。
#
# 用法：
#   cp deploy/nginx.env.example deploy/nginx.env   # 首次（该文件不入库）
#   sh deploy/set_internal_token.sh            # 生成新密钥并写入两处
#   sh deploy/set_internal_token.sh --show     # 只看当前值，不改
#
# 改完必须重建两个容器才生效（环境变量在容器创建时注入，restart 不重读 env_file）：
#   docker compose up -d backend nginx
set -eu

ENV_FILE="$(dirname "$0")/.env"
NGINX_ENV_FILE="$(dirname "$0")/nginx.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "找不到 $ENV_FILE —— 先按 deploy/README.md 生成配置" >&2
    exit 1
fi
if [ ! -f "$NGINX_ENV_FILE" ]; then
    echo "找不到 $NGINX_ENV_FILE —— 先 cp deploy/nginx.env.example deploy/nginx.env" >&2
    exit 1
fi

# 24 字节 = 48 位十六进制，暴力猜不现实；纯 hex 不含引号/空白，
# 免得在 env_file 和 nginx 模板里踩转义坑。
new_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
    else
        head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

current_token() {
    sed -n 's/^INTERNAL_AUTH_TOKEN=//p' "$1" | head -n 1
}

if [ "${1:-}" = "--show" ]; then
    echo "deploy/.env      : $(current_token "$ENV_FILE")"
    echo "deploy/nginx.env : $(current_token "$NGINX_ENV_FILE")"
    exit 0
fi

TOKEN="$(new_token)"

# 用 awk 就地替换：有该行就改，没有就追加。比 sed -i 可移植（GNU/BSD 语法不同）。
write_var() {
    file="$1"
    awk -v key="INTERNAL_AUTH_TOKEN" -v val="$TOKEN" '
        BEGIN { done = 0 }
        $0 ~ "^" key "=" { print key "=" val; done = 1; next }
        { print }
        END { if (!done) print key "=" val }
    ' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

write_var "$ENV_FILE"
write_var "$NGINX_ENV_FILE"

echo "已写入新密钥（前 8 位 $(printf '%s' "$TOKEN" | cut -c1-8)…）"
echo "  $ENV_FILE"
echo "  $NGINX_ENV_FILE"
echo
echo "生效需要重建容器：docker compose up -d backend nginx"
