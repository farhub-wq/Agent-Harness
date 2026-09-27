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
#   HTTP_PORT=80               对外端口
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
    echo "  已生成（Mongo 密码随机）"
fi

log "生成 nginx 共享密钥（挡住沙箱伪造身份头）"
# nginx.env 含密钥所以不入库，包里只带模板，这里补出来。
[ -f deploy/nginx.env ] || cp deploy/nginx.env.example deploy/nginx.env
sh deploy/set_internal_token.sh | sed 's/^/  /'

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

# ---------------------------------------------------------------- 起服务
log "构建镜像（frontend 的 next build 最慢，2核机器上十几分钟正常）"
HTTP_PORT="$HTTP_PORT" docker compose build

log "启动"
HTTP_PORT="$HTTP_PORT" docker compose up -d

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
echo "  访问      http://$PUBLIC_HOST:$HTTP_PORT"
echo "  用户名    $LOGIN_USER"
if [ -n "${GENERATED_PW:-}" ]; then
    echo "  密码      $LOGIN_PASSWORD          <-- 只打印这一次，自己存好"
fi
echo "  /healthz  $CODE（200 = nginx 存活）"
echo "  /health   $CODE2（200 = 后端就绪）"
echo
if ! grep -q '^DEEPSEEK_API_KEY=.\+' deploy/.env; then
    echo "  !! deploy/.env 里 DEEPSEEK_API_KEY 还是空的，对话会全部失败。补上后："
    echo "       docker compose up -d backend mcp"
fi
echo "  !! 云厂商控制台的**安全组**是另一道墙，脚本改不了："
echo "     入方向放行 TCP $HTTP_PORT，来源 0.0.0.0/0。不开的话外网打不开。"
echo
echo "  查日志：docker compose logs -f backend"
