#!/usr/bin/env bash
# 在一台全新的 Ubuntu 22.04 / 24.04 云主机上把这个栈跑起来。
#
# 用法（在解压后的仓库根目录，root 身份）：
#   sudo -E bash deploy/cloud/bootstrap.sh <公网IP或域名>
#
# 可选环境变量：
#   DEEPSEEK_API_KEY=sk-xxx    不传则 .env 留空，脚本最后提示你手动补
#   LOGIN_USER=admin            nginx Basic Auth 用户名
#   LOGIN_PASSWORD=xxx         不传则随机生成并打印（只打印这一次）
#   HTTP_PORT=80               对外 HTTP 端口
#   HTTPS_PORT=443             对外 HTTPS 端口（TLS_ENABLED=1 时）
#   TLS_ENABLED=1              启用 HTTPS（生成证书 + nginx 80→443 跳转）
#   REGISTRY_URL=              配置后构建的镜像会推到 registry（见 deploy/cd/build.sh）
#
# 脚本会改的东西：apt 源里加一个 docker-ce 仓库、装 docker、写
# /etc/docker/daemon.json、必要时建 4G swap、在仓库内生成 deploy/.env 与
# deploy/nginx/htpasswd。不碰任何已有业务。
set -euo pipefail

PUBLIC_HOST="${1:-}"
if [ -z "$PUBLIC_HOST" ]; then
    echo "用法：sudo -E bash deploy/cloud/bootstrap.sh <公网IP或域名>" >&2
    exit 1
fi
if [ "$(id -u)" != "0" ]; then
    echo "请用 root 跑（sudo -E bash ...）：装 docker 和写 daemon.json 都要 root" >&2
    exit 1
fi

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
[ -f docker-compose.yml ] || { echo "不在仓库根目录（$REPO）" >&2; exit 1; }

HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
TLS_ENABLED="${TLS_ENABLED:-}"
REGISTRY_URL="${REGISTRY_URL:-}"
LOGIN_USER="${LOGIN_USER:-admin}"
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 前置检查
log "前置检查"
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
CORES=$(nproc)
echo "  内存 ${MEM_MB}MB / 磁盘可用 ${DISK_GB}GB / ${CORES} 核"
echo "  系统 $(. /etc/os-release && echo "$PRETTY_NAME")"

if [ "$MEM_MB" -lt 1800 ]; then
    echo "  !! 内存不足 2GB。frontend 的 next build 峰值在 1.5GB 以上，" >&2
    echo "     配合 swap 也许能过，但很容易 OOM。建议换 2核4G 的机型。" >&2
fi
if [ "$DISK_GB" -lt 25 ]; then
    echo "  !! 磁盘可用不足 25GB。镜像 + 构建缓存 + dind 内的沙箱镜像合计约 8-10GB，" >&2
    echo "     还要留翻倍空间给构建。建议 40GB 以上。" >&2
fi

# ---------------------------------------------------------------- swap
log "swap（next build 和 dind 都会吃内存）"
if [ "$MEM_MB" -lt 3800 ] && ! swapon --show | grep -q .; then
    echo "  内存 ${MEM_MB}MB 且当前无 swap，建 4G"
    if ! fallocate -l 4G /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-erp-agent.conf
    sysctl -q vm.swappiness=10
    echo "  已启用"
else
    echo "  跳过（内存足够或已有 swap）"
fi

# ---------------------------------------------------------------- Docker
log "安装 Docker"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg openssl >/dev/null   # openssl 后面生成密码要用

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "  已装：$(docker --version)，$(docker compose version --short)"
else

    # 走阿里云的 docker-ce 镜像源：国内直连 download.docker.com 基本装不动。
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    ARCH="$(dpkg --print-architecture)"
    CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $CODENAME stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null
    echo "  装好了：$(docker --version)"
fi

# daemon.json：镜像加速 + 日志轮转 + 固定地址池。
# 地址池那条不是洁癖：compose 里 edge/data/sandbox 三张网没写死 subnet，
# Docker 会从默认池里挑，默认池含 172.17-172.31 —— 撞上云厂商 VPC 的网段
# 就会出现"容器起得来但互相连不通"这种极难查的问题。挪到 10.201 段避开。
log "写 /etc/docker/daemon.json"
mkdir -p /etc/docker
# 这个文件里不能写注释键：Docker 29 起 dockerd 对未知键是硬失败
# （"directives don't match any configuration option: _comment_xxx"），
# 而不是像以前那样忽略。所以判断"这份是不是我们写的"只能靠内容特征。
if [ -f /etc/docker/daemon.json ] && ! grep -q 'daocloud' /etc/docker/daemon.json 2>/dev/null; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
    echo "  已有 daemon.json，备份成 .bak.<时间戳>"
fi
cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": ["https://docker.m.daocloud.io"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" },
  "default-address-pools": [
    { "base": "10.201.0.0/16", "size": 24 }
  ]
}
JSON

systemctl enable --now docker >/dev/null 2>&1 || true
systemctl restart docker
sleep 2

# dind 要开 ip_forward + iptables 转发；部分内核还得手动加载 br_netfilter。
modprobe br_netfilter 2>/dev/null || true
sysctl -qw net.ipv4.ip_forward=1
echo "  docker $(docker --version | awk '{print $3}' | tr -d ,)，加速：$(docker info 2>/dev/null | grep -A1 'Registry Mirrors' | tail -1 | xargs)"

# dind seccomp profile 已通过 dind-daemon.json 的 seccomp-profile 配置，
# 作用于 dind 内部创建的沙箱容器，不需要宿主机额外配置。
#
# userns-remap 暂未启用：在 dind-in-Docker + bind mount 场景下它会改变沙箱
# 容器写入 /workspace 的属主，需要先验证 SANDBOX_TRANSFER_DIR 的映射。
# 启用方式：在 /etc/subuid /etc/subgid 写入 dockremap:100000:65536，
# 在 deploy/dind-daemon.json 加 "userns-remap": "default"，
# 在 compose 的 dind volumes 挂载 /etc/subuid:/etc/subuid:ro 和 /etc/subgid:/etc/subgid:ro。

# ---------------------------------------------------------------- 配置
log "生成 deploy/.env"
if [ -f deploy/.env ]; then
    echo "  deploy/.env 已存在，保留不动（要重建就 mv 走再跑本脚本）"
else
    cp deploy/.env.example deploy/.env
    MONGO_PW="$(openssl rand -hex 16)"
    # 生成的是纯 hex，不含 @ : / 之类需要 URL 编码的字符。
    sed -i "s|^MONGO_INITDB_ROOT_PASSWORD=.*|MONGO_INITDB_ROOT_PASSWORD=$MONGO_PW|" deploy/.env
    sed -i "s|^MONGODB_URI=.*|MONGODB_URI=mongodb://erpadmin:$MONGO_PW@mongo:27017/erp_agent?authSource=admin|" deploy/.env
    sed -i "s|^PUBLIC_BASE_URL=.*|PUBLIC_BASE_URL=http://$PUBLIC_HOST|" deploy/.env
    sed -i "s|^CORS_ALLOW_ORIGINS=.*|CORS_ALLOW_ORIGINS=http://$PUBLIC_HOST|" deploy/.env
    if [ -n "$DEEPSEEK_API_KEY" ]; then
        sed -i "s|^DEEPSEEK_API_KEY=.*|DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY|" deploy/.env
    fi
    # Grafana 管理员密码：留空时用默认 admin（不安全），这里随机生成一份。
    # 与 MONGO 密码一样只生成一次，要换改 .env 重跑。
    GRAFANA_PW="$(openssl rand -hex 16)"
    sed -i "s|^GRAFANA_PASSWORD=.*|GRAFANA_PASSWORD=$GRAFANA_PW|" deploy/.env
    echo "  已生成（Mongo 密码 + Grafana 密码随机）"
fi

log "生成 nginx 共享密钥（挡住沙箱伪造身份头）"
# nginx.env 含密钥所以不入库，包里只带模板，这里补出来。
[ -f deploy/nginx.env ] || cp deploy/nginx.env.example deploy/nginx.env
sh deploy/set_internal_token.sh | sed 's/^/  /'

log "TLS 证书"
# 始终生成一份证书到 deploy/nginx/tls/{cert,key}.pem —— 即使 TLS_ENABLED
# 未设也生成：nginx.conf 里 ssl_certificate 指向固定路径，没有文件
# nginx -t 会失败。纯 HTTP 场景下这份证书没人用，但它在路径上就够了。
#
# TLS_ENABLED=1 时：有域名 + 80 通 → certbot 签真证书；否则用 openssl
# 自签一份（适合内网 / IP 访问）。
_self_signed_cert() {
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -keyout deploy/nginx/tls/key.pem \
        -out deploy/nginx/tls/cert.pem \
        -subj "/CN=$PUBLIC_HOST" \
        -addext "subjectAltName=IP:$PUBLIC_HOST" 2>/dev/null
}

mkdir -p deploy/nginx/tls
if [ "${TLS_ENABLED:-}" = "1" ]; then
    echo "  TLS_ENABLED=1，生成证书"
    # 判断 $PUBLIC_HOST 是不是域名（含字母）
    if printf '%s' "$PUBLIC_HOST" | grep -q '[a-zA-Z]'; then
        echo "  $PUBLIC_HOST 看起来是域名，尝试 certbot（需要 80 端口可达）"
        if command -v certbot >/dev/null 2>&1 || apt-get install -y -qq certbot >/dev/null 2>&1; then
            if certbot certonly --standalone \
                    --non-interactive --agree-tos \
                    -d "$PUBLIC_HOST" \
                    ${LETSENCRYPT_EMAIL:+--email "$LETSENCRYPT_EMAIL"} \
                    2>/dev/null; then
                cp "/etc/letsencrypt/live/$PUBLIC_HOST/fullchain.pem" deploy/nginx/tls/cert.pem
                cp "/etc/letsencrypt/live/$PUBLIC_HOST/privkey.pem"   deploy/nginx/tls/key.pem
                echo "  certbot 已签发真证书"
            else
                echo "  certbot 失败，回退到自签证书"
                _self_signed_cert
            fi
        else
            echo "  装不上 certbot，用自签证书"
            _self_signed_cert
        fi
    else
        echo "  $PUBLIC_HOST 是 IP，用自签证书"
        _self_signed_cert
    fi
else
    echo "  TLS_ENABLED 未设，生成自签占位证书（nginx -t 需要）"
    _self_signed_cert
fi

# 把 TLS_ENABLED 写进 nginx.env（envsubst 渲染 tls.conf.template 读它）。
# **无论开关与否都要显式留下这一行（包括纯 HTTP 的空值）**：nginx 镜像的
# envsubst 只替换容器环境里「已定义」的变量，这行缺失时 ${TLS_ENABLED} 会原样
# 残留进 tls.conf，被 nginx 当成变量引用、恰好与 map 目标 $tls_enabled 自引用，
# 于是每个请求都 "cycle while evaluating variable tls_enabled" → 500。
if grep -q '^TLS_ENABLED=' deploy/nginx.env 2>/dev/null; then
    sed -i "s|^TLS_ENABLED=.*|TLS_ENABLED=$TLS_ENABLED|" deploy/nginx.env
else
    printf 'TLS_ENABLED=%s\n' "$TLS_ENABLED" >> deploy/nginx.env
fi
# 公开地址改成 https（如果 TLS 开了）
if [ -n "$TLS_ENABLED" ] && [ -f deploy/.env ]; then
    sed -i "s|^PUBLIC_BASE_URL=.*|PUBLIC_BASE_URL=https://$PUBLIC_HOST|" deploy/.env
    sed -i "s|^CORS_ALLOW_ORIGINS=.*|CORS_ALLOW_ORIGINS=https://$PUBLIC_HOST|" deploy/.env
fi

log "镜像仓库"
if [ -n "$REGISTRY_URL" ]; then
    echo "  REGISTRY_URL=$REGISTRY_URL，配置 docker login"
    if [ -n "${REGISTRY_USER:-}" ] && [ -n "${REGISTRY_PASSWORD:-}" ]; then
        echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY_URL" \
            -u "$REGISTRY_USER" --password-stdin 2>/dev/null \
            && echo "  登录成功（凭据写入 ~/.docker/config.json）" \
            || echo "  !! 登录失败，build.sh 的 --push 会失败"
    else
        echo "  !! REGISTRY_USER 或 REGISTRY_PASSWORD 为空，跳过 docker login"
    fi
    # 把 REGISTRY_URL 写进 deploy/.env 供 build.sh / deploy.sh 读
    if [ -f deploy/.env ]; then
        if grep -q '^REGISTRY_URL=' deploy/.env 2>/dev/null; then
            sed -i "s|^REGISTRY_URL=.*|REGISTRY_URL=$REGISTRY_URL|" deploy/.env
        else
            printf 'REGISTRY_URL=%s\n' "$REGISTRY_URL" >> deploy/.env
        fi
    fi
else
    echo "  未配 REGISTRY_URL，构建/发布走本地模式（构建机 == 运行机）"
fi

log "生成 nginx Basic Auth 账号"
# Docker 在 bind mount 源不存在时会自动建一个同名**目录**，之后 nginx 报的是
# "is a directory" 而不是"文件不存在"，很难猜。这里先清掉这个坑。
if [ -d deploy/nginx/htpasswd ]; then
    rm -rf deploy/nginx/htpasswd
fi
if [ -f deploy/nginx/htpasswd ] && [ -z "${LOGIN_PASSWORD:-}" ]; then
    echo "  htpasswd 已存在，保留（要换密码传 LOGIN_PASSWORD=xxx 重跑）"
else
    LOGIN_PASSWORD="${LOGIN_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)}"
    printf '%s:%s\n' "$LOGIN_USER" "$(openssl passwd -apr1 "$LOGIN_PASSWORD")" \
        > deploy/nginx/htpasswd
    GENERATED_PW=1
    echo "  已生成"
fi
# 必须 644、不能是 600：nginx master 是 root，但请求期打开 htpasswd 校验口令的是
# worker（nginx / uid 101）。600 root:root 它读不了 → 每个**带凭据**请求都 500，
# 而 /healthz 因 auth_basic off 照常 200，表现成"站点活着但一登录就 500"。
# 文件里是 apr1 哈希不是明文；deploy/ci/prepare-stack.sh 同样按 644 处理（见其注释）。
# 对「已存在」的老文件也无条件 chmod，顺手修正历史那批改漏落成 600 的实例。
chmod 644 deploy/nginx/htpasswd

# ---------------------------------------------------------------- 起服务
log "构建镜像（frontend 的 next build 最慢，2核机器上十几分钟正常）"
HTTP_PORT="$HTTP_PORT" HTTPS_PORT="$HTTPS_PORT" docker compose build

log "启动"
HTTP_PORT="$HTTP_PORT" HTTPS_PORT="$HTTPS_PORT" docker compose up -d

log "等所有服务 healthy（backend 的 start_period 是 90s，要建沙箱预热池）"
DEADLINE=$((SECONDS + 420))
while [ $SECONDS -lt $DEADLINE ]; do
    UNHEALTHY=$(docker compose ps --format '{{.Service}} {{.Health}}' \
        | grep -vE 'healthy$' | grep -vE 'sandbox-image-loader' | wc -l)
    # 别写成 `[ ... ] && break`：本脚本是 set -e，判断为假时整条 AND 列表返回 1，
    # 会被 set -e 当成命令失败直接杀掉脚本（表现出来就是循环卡死、凭据不打印）。
    if [ "$UNHEALTHY" -eq 0 ]; then
        break
    fi
    sleep 10
done
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Health}}'

# 自检：经 nginx 打一次后端。401 = nginx 活着且 Basic Auth 在拦人（预期）。
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HTTP_PORT/healthz" || true)
CODE2=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HTTP_PORT/health" || true)

log "完成"
if [ "$TLS_ENABLED" = "1" ]; then
    echo "  访问      https://$PUBLIC_HOST"
else
    echo "  访问      http://$PUBLIC_HOST:$HTTP_PORT"
fi
echo "  用户名    $LOGIN_USER"
if [ -n "${GENERATED_PW:-}" ]; then
    echo "  密码      $LOGIN_PASSWORD          <-- 只打印这一次，自己存好"
fi
echo "  /healthz  $CODE（200 = nginx 存活）"
echo "  /health   $CODE2（200 = 后端就绪）"
echo "  Grafana   http://$PUBLIC_HOST:${GRAFANA_PORT:-13000}  admin / （见 deploy/.env 的 GRAFANA_PASSWORD）"
echo
if ! grep -q '^DEEPSEEK_API_KEY=.\+' deploy/.env; then
    echo "  !! deploy/.env 里 DEEPSEEK_API_KEY 还是空的，对话会全部失败。补上后："
    echo "       docker compose up -d backend mcp"
fi
echo "  !! 云厂商控制台的**安全组**是另一道墙，脚本改不了："
if [ "$TLS_ENABLED" = "1" ]; then
    echo "     入方向放行 TCP 80 + TCP $HTTPS_PORT，来源 0.0.0.0/0。不开的话外网打不开。"
else
    echo "     入方向放行 TCP $HTTP_PORT，来源 0.0.0.0/0。不开的话外网打不开。"
fi
echo
echo "  查日志：docker compose logs -f backend"
