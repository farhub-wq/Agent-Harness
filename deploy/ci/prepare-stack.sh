#!/usr/bin/env bash
# 为 CI 集成 job 生成一套可运行的本地配置。幂等：重复跑会重新生成一份新口令。
#
#   bash deploy/ci/prepare-stack.sh
#
# 生成四类配置 + 一份占位证书（**全部在 .gitignore 里，永不入库**）：
#   deploy/.env                    从 deploy/.env.example 派生，填随机 Mongo 口令、
#                                  CI 专用的假 LLM Key、以及本次生成的共享密钥
#   deploy/nginx.env               从 deploy/nginx.env.example 派生，写**同一个**
#                                  共享密钥 —— 这本身就是对「两处必须一致」的验证
#   deploy/nginx/htpasswd          Basic Auth 口令（明文不存在别处，只留在
#                                  .ci-credentials.sh 里供冒烟脚本使用）
#   deploy/ci/.ci-credentials.sh   上面三个值，供 smoke-edge.sh / stack-smoke.sh 读
#   deploy/nginx/tls/{cert,key}.pem  自签 TLS 占位证书。CI 走纯 HTTP（nginx.env 里
#                                  TLS_ENABLED= 空），但 nginx.conf 的 :443 server
#                                  **无条件**加载该路径，缺了它 nginx master 加载配置
#                                  就 emerg、容器永远 restarting —— 两个集成 job 都会
#                                  卡在等 healthy 超时。与 deploy/cd 的占位证书同契约。
#
# 为什么用随机值而不是写死：写死的话"两处不一致时应该 401"这类断言就退化成
# "常量等于常量"，永远绿。随机值让每次运行都是一次真实的一致性验证。
#
# 本机误用的防呆见下面 CI_MARKER 那段 —— 这个名字的脚本会覆盖真实的 deploy/.env。
set -euo pipefail

# 从第一行就收紧权限：下面每个文件里都有口令或密钥，不要出现"先 644 再 chmod"
# 的窗口（生产机上就踩过 644 世界可读这个坑）。
umask 077

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/ci/lib-ci.sh
. "$CI_DIR/lib-ci.sh"
REPO="$CI_REPO_ROOT"
cd "$REPO"

ENV_FILE="deploy/.env"
ENV_EXAMPLE="deploy/.env.example"
NGINX_ENV_FILE="deploy/nginx.env"
NGINX_ENV_EXAMPLE="deploy/nginx.env.example"
HTPASSWD="deploy/nginx/htpasswd"
CRED_FILE="deploy/ci/.ci-credentials.sh"

# 写在生成文件第一行的标记。它的唯一作用是让下面的防呆能区分「这是脚本生成的」
# 和「这是人配的真实配置」—— deploy/.env 里有真实的 DEEPSEEK_API_KEY，
# 误覆盖一次的代价是有人要去找回自己的 Key。
CI_MARKER="# GENERATED-BY: deploy/ci/prepare-stack.sh（CI 专用，可随时重建）"

info() { ci_info "$*"; }
die()  { ci_die "$1"; }

# ---------------------------------------------------------------- 防呆
# 目标文件已存在、且不是本脚本生成的 → 拒绝。本机要跑必须显式 CI_FORCE=1，
# 且会先备份成 *.bak.<时间戳>。
guard_existing() {
    local f="$1"
    [ -f "$f" ] || return 0
    grep -qF "$CI_MARKER" "$f" && return 0
    if [ "${CI_FORCE:-}" != "1" ]; then
        die "$f 已存在且不是 CI 生成的 —— 里面可能是你的真实配置。
    真要覆盖：先自己备份，然后 CI_FORCE=1 bash deploy/ci/prepare-stack.sh
    （脚本会再存一份 $f.bak.<时间戳>）"
    fi
    local bak="$f.bak.$(date +%Y%m%dT%H%M%S)"
    cp -p "$f" "$bak"
    printf '\033[33m !! 已备份原文件到 %s\033[0m\n' "$bak" >&2
}

set_var() { ci_set_var "$@"; }

# 从模板派生：先写标记头，再照抄模板正文（模板第一行可能是注释，无妨）。
derive_from() {
    local src="$1" dst="$2"
    [ -f "$src" ] || die "找不到模板 $src"
    { printf '%s\n' "$CI_MARKER"; cat "$src"; } > "$dst"
}

# ---------------------------------------------------------------- 生成
for f in "$ENV_FILE" "$NGINX_ENV_FILE"; do guard_existing "$f"; done
# htpasswd 与凭据文件没有"人的真实配置"这回事，直接覆盖。但要挡一下
# docker-compose 那个已知的坑：挂载源路径不存在时 Docker 会自动建一个**同名目录**，
# 于是 nginx 报的是 "is a directory" 而不是"文件不存在"（见 docker-compose.yml
# 里 htpasswd 那条挂载的注释）。这里直接说出来，别让人对着 `>` 的重定向错误发懵。
if [ -d "$HTPASSWD" ]; then
    die "$HTPASSWD 是个目录（Docker 自动建出来的那个坑）—— 删掉它再重跑：rm -rf $HTPASSWD"
fi

MONGO_PASS="$(openssl rand -hex 16)"
TOKEN="$(openssl rand -hex 24)"
BASIC_USER="ci"
BASIC_PASSWORD="$(openssl rand -hex 12)"

derive_from "$ENV_EXAMPLE" "$ENV_FILE"
set_var "$ENV_FILE" MONGO_INITDB_ROOT_USERNAME erpadmin
set_var "$ENV_FILE" MONGO_INITDB_ROOT_PASSWORD "$MONGO_PASS"
set_var "$ENV_FILE" MONGODB_URI \
    "mongodb://erpadmin:${MONGO_PASS}@mongo:27017/erp_agent?authSource=admin"
# 假 Key，但形态要像真的：backend 的 lifespan 不构造模型，所以这里不会被用到。
# 用 sk-dummy 前缀是为了命中 .gitleaks.toml 的 allowlist（虽然 .env 被 gitignore、
# 不会进历史，但本地 detect --no-git 扫目录时不该报一条假阳性）。
set_var "$ENV_FILE" DEEPSEEK_API_KEY "sk-dummy-ci-not-a-real-key"
set_var "$ENV_FILE" PUBLIC_BASE_URL "http://127.0.0.1"
set_var "$ENV_FILE" CORS_ALLOW_ORIGINS "http://127.0.0.1"
set_var "$ENV_FILE" INTERNAL_AUTH_TOKEN "$TOKEN"

derive_from "$NGINX_ENV_EXAMPLE" "$NGINX_ENV_FILE"
set_var "$NGINX_ENV_FILE" INTERNAL_AUTH_TOKEN "$TOKEN"

# htpasswd 用 openssl 生成 apr1 哈希，而不是 htpasswd(1)：apache2-utils 在
# runner 上是否预装不是我们能保证的，openssl 则是（deploy/cd/lib.sh 的前置
# 检查里也要求它存在）。nginx 的 auth_basic_user_file 认 $apr1$ 格式。
# -stdin 是为了让口令里的 '-' 之类字符不会被 openssl 当成选项。
umask 077
printf '%s\n' "$BASIC_PASSWORD" | openssl passwd -apr1 -stdin \
    | { read -r hash; printf '%s:%s\n' "$BASIC_USER" "$hash"; } > "$HTPASSWD"

cat > "$CRED_FILE" <<EOF
# GENERATED-BY: deploy/ci/prepare-stack.sh —— 一次性 CI 口令，不要提交。
# 本文件已在 .gitignore 与 deploy/cd/leak-check.sh 的 SECRET_PATHS 里。
export HTTP_PORT=80
CI_BASE_URL='http://127.0.0.1'
CI_BASIC_USER='$BASIC_USER'
CI_BASIC_PASSWORD='$BASIC_PASSWORD'
CI_INTERNAL_TOKEN='$TOKEN'
EOF

# 生产机那次教训：密钥文件曾是 644 世界可读。runner 是一次性的，但保持同样的
# 习惯不花任何代价。
chmod 600 "$ENV_FILE" "$NGINX_ENV_FILE" "$CRED_FILE"

# htpasswd **必须**是 644，不能跟着上面一起收紧。2026-10-02 在 CI 上实测踩到：
# nginx 的 master 是 root，但**真正打开这个文件的 worker 进程是 nginx 用户**，
# 600 的 root:root 文件它读不了，于是每个**带凭据**的请求都返回 500，access log
# 里只有一行 "open() /etc/nginx/htpasswd failed (13: Permission denied)"，
# 而 /healthz（auth_basic off）照常 200 —— 表现成"服务活着，只是所有页面都 500"，
# 很容易往应用层查。
#
# 另外这文件里存的是 apr1 哈希不是明文口令（明文只在本 job 的 .ci-credentials.sh
# 里，那个是 600），对它的可读性要求本来就低。生产机上按 deploy/README.md 生成
# 的也是 644 —— 这里跟着它，不要"顺手加固"。
chmod 644 "$HTPASSWD"

# ---------------------------------------------------------------- nginx TLS 占位证书
# nginx.conf 的 :443 server **无条件**写了 ssl_certificate /etc/nginx/tls/cert.pem：
# 该指令在 master 加载配置期就解析路径，跟 TLS_ENABLED 开关是不是空无关。CI 这里是
# 纯 HTTP（上面 nginx.env 里 TLS_ENABLED= 空），又不跑 bootstrap.sh / deploy.sh，
# 没人生成证书 —— 不补这一份，nginx 一启动就 emerg（cannot load certificate
# ".../tls/cert.pem": No such file or directory），容器一直 restarting，smoke-edge
# 等 420s、stack-smoke 等 600s 双双超时，而且认证 / 沙箱断言一条都跑不到。
#
# 用**同一条** openssl（RSA2048 / 3650 天 / CN=localhost），与
# deploy/cd/lib.sh 的 cd_ensure_nginx_tls_cert 保持一个契约，别在这里发散。
# compose 以**目录**挂 ./deploy/nginx/tls:/etc/nginx/tls:ro，无单文件挂载的 inode 坑。
TLS_DIR="$REPO/deploy/nginx/tls"
mkdir -p "$TLS_DIR"
if [ ! -s "$TLS_DIR/cert.pem" ] || [ ! -s "$TLS_DIR/key.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TLS_DIR/key.pem" -out "$TLS_DIR/cert.pem" \
        -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1 \
        || ci_die "自签 nginx TLS 占位证书失败（openssl req -x509）"
fi
# 证书由 master(root) 加载期读取（worker 不自行 open），600 即可，与 cd 那份占位一致。
chmod 600 "$TLS_DIR/cert.pem" "$TLS_DIR/key.pem"

info "$ENV_FILE / $NGINX_ENV_FILE / $HTPASSWD 已生成（另有 $TLS_DIR 占位证书）"
info "Basic Auth 用户：$BASIC_USER"
info "共享密钥前 8 位：$(printf '%s' "$TOKEN" | cut -c1-8)…（两处已写成同一个值）"
info "口令留在 $CRED_FILE，冒烟脚本从那里读"
