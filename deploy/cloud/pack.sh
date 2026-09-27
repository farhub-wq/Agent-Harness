#!/usr/bin/env bash
# 在没有 git 的机器上把当前工作树打成部署包（本仓库的工作树是未提交状态，
# 直接 git clone 拿到的会是上游代码，不含任何本地改动）。
#
# 用法（仓库根目录）：
#   bash deploy/cloud/pack.sh [输出路径]      # 默认 /tmp/erp-agent-deploy.tar.gz
#
# 刻意排除的东西及原因：
#   .git/                   服务器上不需要，且体积大
#   .venv/                  Windows 二进制，461MB，服务器上用不到
#   frontend/node_modules/  418MB，服务器上 docker build 会重新装
#   frontend/.next/         同上
#   .env  deploy/.env       含本机的 DeepSeek key 与 Mongo 密码。根 .env 是宿主
#                           进程开发用的（容器不读它，Dockerfile 里也没 COPY），
#                           deploy/.env 服务器上由 bootstrap.sh 从 .env.example 重新生成
#   deploy/nginx/htpasswd   认证凭据，服务器上重新生成
#   tmp/  src/download/     运行期产物
#   mongo-data/ .history/   本机残留
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-/tmp/erp-agent-deploy.tar.gz}"

# Git Bash 下把 "C:/x/y.tar.gz" 直接交给 GNU tar，tar 会把 C: 当成 rsh 远程主机，
# 报 "Cannot connect to C: resolve failed"。转成 MSYS 形式绕开。
case "$OUT" in
    [A-Za-z]:[\\/]*)
        if command -v cygpath >/dev/null 2>&1; then
            OUT="$(cygpath -u "$OUT")"
        else
            echo "输出路径别写成 Windows 盘符形式，改成 /c/... 或 /tmp/..." >&2
            exit 1
        fi
        ;;
esac

cd "$REPO"

if [ ! -f docker-compose.yml ] || [ ! -d src/agent ]; then
    echo "看起来不在仓库根目录（$REPO），中止" >&2
    exit 1
fi

tar \
    --exclude=./.env \
    --exclude=./.git \
    --exclude=./.venv \
    --exclude=./frontend/node_modules \
    --exclude=./frontend/.next \
    --exclude=./deploy/.env \
    --exclude=./deploy/nginx.env \
    --exclude=./deploy/nginx/htpasswd \
    --exclude=./tmp \
    --exclude=./src/download \
    --exclude=./mongo-data \
    --exclude=./.history \
    --exclude='*/__pycache__' \
    --exclude='*.pyc' \
    --exclude='*.log' \
    -czf "$OUT" .

SIZE=$(du -h "$OUT" | cut -f1)
echo "打包完成：$OUT（$SIZE）"
echo
echo "内容抽查（下面这段应当只有 ok）："
LIST="$(tar -tzf "$OUT")"
LEAK="$(printf '%s\n' "$LIST" | grep -E '^\./(\.env$|deploy/\.env$|deploy/nginx\.env$|\.git/|\.venv/|frontend/node_modules/|frontend/\.next/|deploy/nginx/htpasswd$|tmp/|src/download/)' || true)"
if [ -n "$LEAK" ]; then
    echo "!! 这些不该出现在包里：" >&2
    printf '%s\n' "$LEAK" | head -5 >&2
    exit 1
fi
echo "  ok（共 $(printf '%s\n' "$LIST" | wc -l | tr -d ' ') 个条目）"
echo "  抽查关键文件在不在："
for f in docker-compose.yml Dockerfile deploy/.env.example deploy/cloud/bootstrap.sh \
         deploy/nginx/nginx.conf deploy/nginx.env.example deploy/dind-daemon.json \
         frontend/package-lock.json; do
    printf '%s\n' "$LIST" | grep -qx "./$f" && echo "    ok  $f" || { echo "    !! 缺 $f" >&2; exit 1; }
done
echo
echo "下一步："
echo "  scp $OUT root@<服务器IP>:/root/"
echo "  ssh root@<服务器IP>"
echo "  tar -xzf /root/$(basename "$OUT") -C /root/erp-agent && cd /root/erp-agent"
echo "  bash deploy/cloud/bootstrap.sh <服务器IP或域名>"
