#!/usr/bin/env bash
# deploy/cd 共享库 —— 被 deploy.sh / status.sh source。只定义函数与常量，
# source 它不产生副作用。
#
# 环境模型（v2：只有一套生产栈）：
#   production  project=erp-agent  HTTP_PORT=80  mcp-sandbox 172.31.0.0/24
#
# 为什么这些必须集中在一处而不是每个脚本各写一份：
#   1) 所有 compose 调用要统一带 -p，否则会和别的 project 抢；
#   2) 要物理禁掉 `compose down` / `prune` / `rm`：
#      down 会重建网络，mcp-sandbox 的静态 IP 会变，而沙箱容器 /etc/hosts 里
#      写死的地址不会跟着变，沙箱内所有 MCP 工具挂掉；
#      prune 会删掉未被运行容器引用的镜像，也就是全部历史版本，回滚能力归零；
#   3) 健康判据、退出码、状态文件格式只能有一处权威实现。

CD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CD_REPO_ROOT="$(cd "$CD_LIB_DIR/../.." && pwd)"

# 发布锁。flock 独占，避免两次发布并发改同一棵树。
CD_LOCK_FILE="${CD_LOCK_FILE:-/var/lock/erp-agent-deploy.lock}"

# 裸镜像仓库：git archive 的取源。它让「同步源码树」和「回滚源码树」都变成
# `git archive <sha> | rsync`，不依赖 GitHub 可达，也不依赖工作区是否干净。
CD_IMAGE_REPO="${CD_IMAGE_REPO:-/srv/erp-agent.git}"

# ---- 备份（阶段 5，实现在 deploy/dr/）----
# 备份目录**刻意不在**生产树里：生产树每次发布都会被 rsync --delete 刷一遍，
# 放在里面等于每次发布删一次备份。也刻意不在 /var/lib/docker 所在的子目录 ——
# 它要能被单独统计空间（见 status.sh 与 patrol.sh）。
CD_BACKUP_DIR="${CD_BACKUP_DIR:-/var/backups/erp-agent}"
CD_BACKUP_KEEP="${CD_BACKUP_KEEP:-7}"
# mongo 的 **服务名**（不是容器名）：备份与自检都通过 compose 找到它，
# 这样 CI 与生产走的是同一条代码路径。
CD_MONGO_SERVICE="${CD_MONGO_SERVICE:-mongo}"
# 自检用的一次性容器要跑的镜像。默认按 compose 里声明的来 —— 恢复必须用
# **不高于** dump 来源的 server 版本，写死一个版本号迟早会和 compose 漂移。
CD_MONGO_IMAGE="${CD_MONGO_IMAGE:-mongo:6.0}"

# 磁盘门槛。**一处定义**：deploy.sh 的前置检查、status.sh 的巡检、patrol.sh 的
# 告警都读它。原先这个 8 同时写在 cd_assert_disk 的默认参数和 status.sh 的字面量
# 里 —— 两个地方各改一次的话，会出现「前置检查说不够、巡检说够」这种互相打脸的
# 输出，而那种输出会让人开始不信这两条检查。
CD_DISK_MIN_GB="${CD_DISK_MIN_GB:-8}"

# 备份新鲜度门槛（天）。备份在发布时做、外加每天的 erp-agent-backup.timer，
# 所以超过这个天数说明两条路都断了 —— 那是个真问题，不是噪音。
CD_BACKUP_MAX_AGE_DAYS="${CD_BACKUP_MAX_AGE_DAYS:-3}"

# ---- 巡检（阶段 5，实现在 deploy/monitor/）----
# 巡检状态目录。**刻意不在仓库树里**：patrol 每 10 分钟写一次，放进仓库等于每 10
# 分钟弄脏一次工作区；而且 tree 是 rsync --delete 刷出来的，状态会跟着没。
CD_PATROL_STATE_DIR="${CD_PATROL_STATE_DIR:-/var/lib/erp-agent}"
# 上一次的判定结果（一组 id|OK/FAIL）。不是机密，root 0644 即可。
CD_PATROL_LAST="${CD_PATROL_LAST:-$CD_PATROL_STATE_DIR/patrol.last}"
# 巡检自己的锁：防手动重跑与 timer 撞车导致重复告警。**与发布锁是两把**——
# 巡检去抢发布锁会拦住正在进行的发布，那是比漏报更糟的事。
CD_PATROL_LOCK="${CD_PATROL_LOCK:-$CD_PATROL_STATE_DIR/patrol.lock}"

# 「一次发布正在进行中」的判据阈值（秒）：pending 文件比它年轻就算发布在跑。
# 由 cd_deploy_in_flight 用，两个调用方：巡检验它决定整轮跳过，定时备份验它决定
# 跳过本轮（2 核 3.6G 上两个 mongodump + 两个 512m 恢复容器能把生产挤到 OOM）。
#
# 1200s 是实测发布耗时的十倍以上（换版 44s、回退 39s），刻意留得宽：这里宁可
# 少报也不要误报，因为误报的表现是「发布时必来一条告警 + 一条恢复」。
# 另一侧的边界同样重要 —— 卡住不动的 pending 超过这个岁数就不再被当成「在跑」，
# 于是它会被巡检当成故障报出来，而那正是不该漏的那一种。
CD_DEPLOY_INFLIGHT_GRACE="${CD_DEPLOY_INFLIGHT_GRACE:-1200}"

# deploy.sh 的退出码语义。CI 靠它区分处置方式：
#   0  成功
#   1  前置检查失败 —— 完全没动过
#   2  备份失败     —— 完全没动过
#   3  同步失败     —— 已还原源码树，业务未受影响
#   4  影子启动失败 —— 完全没动过，生产未受影响
#   5  换版后验证失败，已自动回滚（手工 rollback 成功同样是 5）
#   6  观察窗失败，已自动回滚
#   7  回滚也失败   —— 服务可能是坏的，需要人立刻介入
#   8  迁移失败     —— 完全没动过（迁移在同步源码树之前）
#
# 8 是**刻意**新开的一个码，而不是并进 2。2 的含义与通知文案都是「备份失败 ——
# 多半是磁盘空间」，把迁移失败报成这个，运维会去查磁盘，而真正的原因是迁移脚本
# 在一个新结构上碰到了老数据。一个退出码的价值全在于它把处置方向指对。
CD_EXIT_OK=0
CD_EXIT_PRECHECK=1
CD_EXIT_BACKUP=2
CD_EXIT_SYNC=3
CD_EXIT_SHADOW=4
CD_EXIT_ROLLED_BACK=5
CD_EXIT_SOAK_ROLLED_BACK=6
CD_EXIT_ROLLBACK_FAILED=7
CD_EXIT_MIGRATE=8

# ---------------------------------------------------------------- 输出
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m !! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m !! %s\033[0m\n' "$1" >&2; exit "${2:-1}"; }

# ---------------------------------------------------------------- 环境参数
# 用一次 case 把常量一起定下来，而不是几个 $(子函数) —— 在命令替换里 die 只会
# 杀掉子 shell，外层拿到空字符串继续跑，失败变成静默。
cd_load_env() {
    local env_name="${1:-}"

    case "$env_name" in
        production)
            CD_ENV=production
            PROJECT=erp-agent
            HTTP_PORT="${HTTP_PORT:-80}"
            MCP_SANDBOX_SUBNET="${MCP_SANDBOX_SUBNET:-172.31.0.0/24}"
            MCP_SANDBOX_IP="${MCP_SANDBOX_IP:-172.31.0.10}"
            ;;
        *)
            die "未知环境 '$env_name'，v2 只有 production 一套栈" "$CD_EXIT_PRECHECK"
            ;;
    esac
    export HTTP_PORT MCP_SANDBOX_SUBNET MCP_SANDBOX_IP

    CD_STATE_DIR="$CD_LIB_DIR/state"
    CD_STATE_FILE="$CD_STATE_DIR/$CD_ENV.env"
    CD_PREV_FILE="$CD_STATE_DIR/$CD_ENV.prev.env"
    CD_PENDING_FILE="$CD_STATE_DIR/$CD_ENV.pending.env"
    # 版本覆盖文件：用 compose override 换 image，而不是改仓库里的
    # docker-compose.yml —— 生产树是同步出来的，改它下次同步就没了，而且
    # 「改 docker-compose.yml 的拓扑」是明令禁止自动应用的（见 package.filter
    # 与 README 的路径分级）。
    CD_OVERRIDE_FILE="$CD_STATE_DIR/$CD_ENV.override.yml"
}

# ---------------------------------------------------------------- compose 包装
cd_compose() {
    # 所有 compose 调用必须走这里。
    local verb="${1:-}"
    case "$verb" in
        down|prune|rm)
            die "compose $verb 被禁止（见 deploy/cd/README.md 的架构约束）：down 会重建网络让沙箱内地址失效，prune 会删掉全部历史镜像让回滚归零" "$CD_EXIT_PRECHECK"
            ;;
    esac
    local -a files=(-f "$CD_REPO_ROOT/docker-compose.yml")
    [ -f "$CD_OVERRIDE_FILE" ] && files+=(-f "$CD_OVERRIDE_FILE")
    ( cd "$CD_REPO_ROOT" && docker compose -p "$PROJECT" "${files[@]}" "$@" )
}

cd_assert_tools() {
    local missing="" t
    for t in docker curl flock openssl rsync git sha256sum; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    [ -n "$missing" ] || return 0
    die "缺工具:$missing（部署机应先跑过 deploy/cloud/bootstrap.sh）" "$CD_EXIT_PRECHECK"
}

cd_assert_compose_version() {
    local v major minor rest
    v="$(docker compose version --short 2>/dev/null | sed 's/^v//')" \
        || die "拿不到 compose 版本" "$CD_EXIT_PRECHECK"
    major="${v%%.*}"
    rest="${v#*.}"
    minor="${rest%%.*}"
    case "$major$minor" in
        *[!0-9]*) die "compose 版本无法解析：'$v'" "$CD_EXIT_PRECHECK" ;;
    esac
    # --wait-timeout 需要 >= 2.5。真正的健康判据是 cd_wait_healthy，这里只做
    # 前置断言（各版本对一次性服务的 --wait 语义有差异，不能依赖它）。
    if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 5 ]; }; then
        die "compose $v 太旧，需要 >= 2.5" "$CD_EXIT_PRECHECK"
    fi
    info "compose $v"
}

cd_assert_daemon_address_pools() {
    # compose 里 edge/data/sandbox 三张网没写死 subnet，Docker 会从
    # default-address-pools 里挑。没跑过 bootstrap.sh 的机器用默认池（含
    # 172.17-172.31），而 mcp-sandbox 写死 172.31.0.0/24，有概率被别的网络先
    # 占掉。把「没跑过 bootstrap」变成一条显式断言，而不是诡异的网络报错。
    local f=/etc/docker/daemon.json
    [ -r "$f" ] || die "$f 不存在：这台机器没跑过 deploy/cloud/bootstrap.sh" "$CD_EXIT_PRECHECK"
    grep -q '10\.201\.0\.0/16' "$f" \
        || die "$f 里没有 default-address-pools 10.201.0.0/16，先跑 deploy/cloud/bootstrap.sh" "$CD_EXIT_PRECHECK"
    info "daemon.json 地址池 ok"
}

cd_assert_token_consistency() {
    # nginx 用 deploy/nginx.env 渲染 X-Internal-Auth，backend 用 deploy/.env
    # 校验。两处不一致的表现是「/healthz 与 /health 都 200，所有 /api 401」，
    # 极难定位。放在前置里直接拦住。
    local a b
    a="$(sed -n 's/^INTERNAL_AUTH_TOKEN=//p' "$CD_REPO_ROOT/deploy/.env" | head -1 | tr -d '"'"'"'')"
    b="$(sed -n 's/^INTERNAL_AUTH_TOKEN=//p' "$CD_REPO_ROOT/deploy/nginx.env" | head -1 | tr -d '"'"'"'')"
    [ -n "$a" ] || die "deploy/.env 缺 INTERNAL_AUTH_TOKEN。跑 sh deploy/set_internal_token.sh" "$CD_EXIT_PRECHECK"
    [ -n "$b" ] || die "deploy/nginx.env 缺 INTERNAL_AUTH_TOKEN。跑 sh deploy/set_internal_token.sh" "$CD_EXIT_PRECHECK"
    [ "$a" = "$b" ] \
        || die "deploy/.env 与 deploy/nginx.env 的 INTERNAL_AUTH_TOKEN 不一致（当前状态：/health 会 200 但所有 /api 401）。跑 sh deploy/set_internal_token.sh 修" "$CD_EXIT_PRECHECK"
    info "共享密钥两处一致（len=${#a}，前 4 位 ${a:0:4}…）"
}

cd_assert_disk() {
    local need_gb="${1:-$CD_DISK_MIN_GB}" avail_gb
    avail_gb="$(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')"
    [ -n "$avail_gb" ] || { warn "读不出 /var/lib/docker 可用空间，跳过磁盘门槛"; return 0; }
    if [ "$avail_gb" -lt "$need_gb" ]; then
        die "磁盘可用 ${avail_gb}G < 门槛 ${need_gb}G。发布要拉新镜像，空间不够会中途失败。" "$CD_EXIT_PRECHECK"
    fi
    info "磁盘可用 ${avail_gb}G"
}

cd_preflight() {
    log "前置检查（env=$CD_ENV project=$PROJECT port=$HTTP_PORT）"
    cd_assert_tools
    docker info >/dev/null 2>&1 || die "docker daemon 不可达（systemctl status docker）" "$CD_EXIT_PRECHECK"
    cd_assert_compose_version
    cd_assert_daemon_address_pools
    [ -f "$CD_REPO_ROOT/docker-compose.yml" ] || die "找不到 $CD_REPO_ROOT/docker-compose.yml" "$CD_EXIT_PRECHECK"
    [ -f "$CD_REPO_ROOT/deploy/.env" ] \
        || die "缺 deploy/.env：这台机器没跑过 bootstrap.sh，或包没解全" "$CD_EXIT_PRECHECK"
    [ -f "$CD_REPO_ROOT/deploy/nginx/htpasswd" ] \
        || die "缺 deploy/nginx/htpasswd：nginx 起不来。见 deploy/README.md「创建登录账号」" "$CD_EXIT_PRECHECK"
    cd_assert_token_consistency
    cd_assert_disk "$CD_DISK_MIN_GB"
}

# ---------------------------------------------------------------- 发布锁
cd_lock() {
    # FD 200 持锁。必须在调用进程里 exec —— 放子 shell 里锁会随子 shell 退出而
    # 释放，等于没锁。
    mkdir -p "$(dirname "$CD_LOCK_FILE")"
    exec 200>"$CD_LOCK_FILE"
    if ! flock -n 200; then
        die "另一处发布/巡检正在跑（$CD_LOCK_FILE 被占）。等它结束再试；确认是残留进程的话手工删掉该文件。" "$CD_EXIT_PRECHECK"
    fi
    printf 'pid=%s env=%s\n' "$$" "${CD_ENV:-?}" >&200
}

# ---------------------------------------------------------------- 镜像坐标
# 无 registry：镜像就在本机 docker daemon 里（构建机 == 运行机）。
# 有 registry：镜像名前面加 REGISTRY_URL/ 前缀，build.sh --push 推上去，deploy.sh
# 在 up 之前 docker pull 拉下来。留空 = 完全本地模式（机器丢 = 镜像全丢 + 回滚归零）。
#
# tag 用不可变的 sha-<12>；语义化 tag（vX.Y.Z）只是给人看的标签。
# 镜像名的**唯一**出处。build.sh（CI，构建并打 tag）和 deploy.sh（生产机，换版）
# 必须对同一个名字达成一致 —— 不一致的表现是构建成功了但发布说"本机没有这个镜像"，
# 两边的输出都看不出问题出在名字上。
CD_APP_IMAGE_NAME=erp-agent-app
CD_FRONTEND_IMAGE_NAME=erp-agent-frontend
CD_MOCK_IMAGE_NAME=erp-mock

# registry 前缀从 deploy/.env 的 REGISTRY_URL 读。**只在这里读一次**：build.sh
# 和 deploy.sh 都 source lib.sh，各自再读一遍迟早漂（一处加斜杠一处没加）。
# 留空时所有镜像名不加前缀，行为与引入 registry 支持之前完全一致。
cd_registry_prefix() {
    local url
    url="$(sed -n 's/^REGISTRY_URL=//p' "$CD_REPO_ROOT/deploy/.env" 2>/dev/null | head -1 | tr -d '"'"'"'')"
    # 去掉末尾斜杠再加一个：registry URL 形如 registry.cn-hangzhou.aliyuncs.com，
    # 也可能带 namespace（registry.../my-ns）。统一处理成 "prefix/" 形式。
    url="${url%/}"
    # 必须用 if/else，不能写 `[ -n "$url" ] && printf`：后者在 url 为空时返回 1，
    # 会让 `prefix=$(cd_registry_prefix)` 在 set -e 下让整个脚本退出 —— 这是真机
    # 测试发现的 bug（没配 registry 的机器 deploy 100% 死在前置检查后、断言镜像前）。
    if [ -n "$url" ]; then
        printf '%s/' "$url"
    fi
}

cd_image_refs() {
    local tag="$1" prefix
    prefix="$(cd_registry_prefix)" || true
    export APP_IMAGE="${prefix}${CD_APP_IMAGE_NAME}:$tag"
    export FRONTEND_IMAGE="${prefix}${CD_FRONTEND_IMAGE_NAME}:$tag"
    export MOCK_ERP_IMAGE="${prefix}${CD_MOCK_IMAGE_NAME}:$tag"
    export CD_HAS_REGISTRY=0
    # 必须用 if，不能写 `[ -n "$prefix" ] && export ...`：这是函数最后一条
    # 语句，prefix 为空时整体返回 1，调用方（deploy.sh）在 set -e 下静默退出 ——
    # 与 cd_registry_prefix 是同一类真机踩出来的 bug，表现为 deploy 死在
    # 「磁盘可用」之后、版本号打印之前，退出码 1 且没有任何 !! 信息。
    if [ -n "$prefix" ]; then
        export CD_HAS_REGISTRY=1
    fi
}

cd_all_images() { printf '%s\n' "$APP_IMAGE" "$FRONTEND_IMAGE" "$MOCK_ERP_IMAGE"; }

# 发布引用 digest 而不是 tag（tag 可以被重新指向，digest 不能）。
cd_image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null; }

cd_assert_images_local() {
    local ref
    while IFS= read -r ref; do
        [ -n "$(cd_image_id "$ref")" ] || return 1
    done < <(cd_all_images)
    return 0
}

# tag -> state/<env>.override.yml。只覆盖会换版的四个服务；mongo / dind /
# nginx / sandbox-image-loader 不动（重建 dind 会杀掉在跑的沙箱容器）。
cd_write_override() {
    mkdir -p "$CD_STATE_DIR"
    {
        printf '# 由 deploy/cd/deploy.sh 生成，不要手改。\n'
        printf '# 只覆盖会换版的服务的 image。别在这里加 mongo/dind/nginx。\n'
        printf 'services:\n'
        printf '  mock-erp:\n    image: %s\n' "$MOCK_ERP_IMAGE"
        printf '  mcp:\n    image: %s\n' "$APP_IMAGE"
        printf '  backend:\n    image: %s\n' "$APP_IMAGE"
        printf '  frontend:\n    image: %s\n' "$FRONTEND_IMAGE"
    } > "$CD_OVERRIDE_FILE"
}

# ---------------------------------------------------------------- 源码树同步
cd_assert_repo_has() {
    local sha="$1"
    git -C "$CD_IMAGE_REPO" cat-file -e "$sha^{commit}" 2>/dev/null
}

cd_fetch_repo() {
    # 裸仓库里没有这个 commit 时才 fetch。github 不可达时回滚仍然工作。
    git -C "$CD_IMAGE_REPO" fetch --prune origin '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*' >&2
}

# 内容哈希：同一 commit 的 `git archive` 输出是可复现的（已验证），所以它既
# 是「这一版源码长什么样」的权威指纹，也不需要碰磁盘上的易变目录。
#
# 先落盘再哈希，而不是直接管道：`git archive 失败 | sha256sum` 会得到**空输入的
# sha256**（e3b0c442…），看起来是个合法结果 —— 校验就变成了永远通过。
cd_content_hash() {
    local sha="$1" tmp
    cd_assert_repo_has "$sha" || { warn "裸仓库 $CD_IMAGE_REPO 里没有 $sha，算不出内容哈希"; return 1; }
    tmp="$(mktemp)"
    if ! git -C "$CD_IMAGE_REPO" archive --format=tar "$sha" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"; warn "git archive $sha 产出为空"; return 1
    fi
    sha256sum < "$tmp" | cut -d' ' -f1
    rm -f "$tmp"
}

# 落盘哈希：只覆盖那些**被 bind mount 进容器**的路径。state/、下载目录、
# 日志会一直变，把它们算进去只会得到假的「不一致」告警。
# 注意不含 deploy/nginx/htpasswd —— 它是受保护的（同步时不覆盖），轮换密码
# 属于正常操作，不该让它触发漂移告警。
CD_BIND_PATHS=(src/skills deploy/nginx/nginx.conf deploy/nginx/templates deploy/dind-daemon.json)

# 同样先取内容再哈希：`find` 一个文件都没找到时会给 sha256sum 喂空输入，
# 那也是 e3b0c442…，与「真实的哈希」无法区分。
cd_hash_files() {
    local inner
    inner="$( cd "$CD_REPO_ROOT" && find "$@" -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum )"
    if [ -z "$inner" ]; then
        warn "这些路径下一个文件都没有：$* —— 算不出快照哈希"
        return 1
    fi
    printf '%s' "$inner" | sha256sum | cut -d' ' -f1
}

cd_bind_hash()  { cd_hash_files "${CD_BIND_PATHS[@]}"; }

# deploy/nginx/** 的内容，决定换版时要不要 --force-recreate nginx。
cd_nginx_hash() { cd_hash_files deploy/nginx; }

cd_sync_tree() {
    local sha="$1" staging rc=0
    [ -n "$sha" ] || return 1
    cd_assert_repo_has "$sha" || cd_fetch_repo || true
    cd_assert_repo_has "$sha" || return 1

    staging="$(mktemp -d)"
    if ! git -C "$CD_IMAGE_REPO" archive --format=tar "$sha" | tar -x -C "$staging"; then
        rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        # --delete 让「新 commit 里被删掉的文件」也从目标机消失（tar -x 覆盖做不到）。
        # --chown=root:root 不是可选项：生产树现在的属主是 tar 带过来的 Windows UID
        # (197609:197121)，rsync -a 会忠实地把它一路保留下去。
        #
        # 不用 --inplace：rsync 默认「写临时文件再 rename」，正在跑的 bash 持有旧
        # deploy.sh 的 fd，改名不影响它；--inplace 会就地覆盖正在执行的脚本。
        rsync -a --delete --chown=root:root \
            --filter="merge $CD_LIB_DIR/package.filter" \
            "$staging"/ "$CD_REPO_ROOT"/ || rc=1
    fi
    rm -rf "$staging"
    return "$rc"
}

cd_assert_synced() {
    # 反向断言：同步**后**必须存在的文件。漏了 deploy/.env.example 会让新机器
    # 上的 bootstrap.sh 生成不出 deploy/.env，而这条要等下次部署才暴露。
    # 返回 1 而不是 die：调用方要先把树还原回上一版再决定退出码。
    local f missing=""
    for f in docker-compose.yml \
             deploy/.env.example deploy/nginx.env.example deploy/nginx/nginx.conf \
             deploy/nginx/templates/internal_token.conf.template \
             deploy/cd/lib.sh deploy/cd/deploy.sh deploy/cd/package.filter \
             deploy/dr/backup.sh deploy/dr/lib-dr.sh \
             deploy/dr/offsite.sh deploy/dr/ossutil-install.sh deploy/dr/migrate.sh \
             deploy/dr/restore-drill.sh \
             deploy/monitor/patrol.sh \
             deploy/prometheus/prometheus.yml \
             deploy/grafana/provisioning/datasources.yml \
             deploy/grafana/provisioning/dashboards.yml \
             src/agent/main_agent.py; do
        [ -e "$CD_REPO_ROOT/$f" ] || missing="$missing $f"
    done
    if [ -n "$missing" ]; then
        warn "同步后缺文件:$missing（package.filter 是不是排除多了？）"
        return 1
    fi
    return 0
}

cd_check_infra_change() {
    # 路径分级：dind / 网络 / 拓扑的改动**不允许**被流水线自动应用。重建 dind
    # 会停掉在跑的沙箱容器。检出变化即失败，要人工用 CD_ALLOW_INFRA_CHANGE=1
    # 显式确认，或在维护窗口上机操作。
    local old_sha="$1" new_sha="$2"
    [ -n "$old_sha" ] || return 0
    local changed
    changed="$(git -C "$CD_IMAGE_REPO" diff --name-only "$old_sha" "$new_sha" -- \
        docker-compose.yml deploy/dind-daemon.json 2>/dev/null || true)"
    [ -z "$changed" ] && return 0
    if [ "${CD_ALLOW_INFRA_CHANGE:-0}" = "1" ]; then
        warn "拓扑文件有改动，但 CD_ALLOW_INFRA_CHANGE=1，继续："
        printf '      %s\n' $changed >&2
        return 0
    fi
    die "这批改动动了拓扑文件：$(printf '%s ' $changed)
    重建 dind 会停掉正在跑的沙箱容器。确认要自动应用就重跑并加 CD_ALLOW_INFRA_CHANGE=1；
    否则请在维护窗口人工上机操作（见 deploy/cd/README.md 的路径分级）。" "$CD_EXIT_PRECHECK"
}

# ---------------------------------------------------------------- 状态文件 v2
cd_write_state() {
    local file="$1" version="$2" sha="$3" who="$4"
    mkdir -p "$(dirname "$file")"
    {
        printf '# 由 deploy/cd/deploy.sh 生成，不要手改。\n'
        printf '# 回滚读的是同目录的 <env>.prev.env。\n'
        printf 'VERSION=%s\n'   "$version"
        printf 'GIT_SHA=%s\n'   "$sha"
        printf 'TAG=%s\n'       "${CD_RUN_TAG:-$version}"
        # ref 是给 compose override 用的（compose 只认 image 引用），ID 是权威的
        # digest（tag 可以被重新指向，digest 不能）。回滚时会断言两者仍然一致。
        printf 'APP_IMAGE=%s\n'         "$APP_IMAGE"
        printf 'FRONTEND_IMAGE=%s\n'    "$FRONTEND_IMAGE"
        printf 'MOCK_ERP_IMAGE=%s\n'    "$MOCK_ERP_IMAGE"
        printf 'APP_IMAGE_ID=%s\n'      "$(cd_image_id "$APP_IMAGE")"
        printf 'FRONTEND_IMAGE_ID=%s\n' "$(cd_image_id "$FRONTEND_IMAGE")"
        printf 'MOCK_ERP_IMAGE_ID=%s\n' "$(cd_image_id "$MOCK_ERP_IMAGE")"
        printf 'TREE_SNAPSHOT_SHA256=%s\n' "${CD_TREE_HASH:-}"
        printf 'BIND_SNAPSHOT_SHA256=%s\n' "$(cd_bind_hash)"
        printf 'NGINX_TREE_SHA256=%s\n'    "$(cd_nginx_hash)"
        printf 'DB_DUMP=%s\n'           "${CD_DB_DUMP:-}"
        printf 'DB_DUMP_SHA256=%s\n'    "${CD_DB_DUMP_SHA256:-}"
        printf 'DEPLOY_ID=%s\n'         "$(date +%Y%m%dT%H%M%S)-$version"
        printf 'DEPLOYED_AT=%s\n'       "$(date -Iseconds)"
        printf 'DEPLOYED_BY=%s\n'       "$who"
    } > "$file"
}

cd_state_get() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 1
    sed -n "s/^$key=//p" "$file" | head -1
}

# 一次发布是否**正在跑**（而不是「历史上有过一次没走完的」）。判据是 pending 文件
# 还年轻 —— 卡住的 pending 是另一回事：那个要**报出来**，不是要躲开它。
#
# 两个调用方，理由不同但都需要它：
#   patrol.sh  发布期间服务在重建、digest 天然对不上，照常判定会让每次发布都产生
#              一条告警加一条恢复，而发布本身已经有自己的四条通知了；
#   backup.sh  定时备份不该和一次发布抢 mongodump。
cd_deploy_in_flight() {
    [ -f "$CD_PENDING_FILE" ] || return 1
    local now mtime
    now="$(date +%s)"
    mtime="$(stat -c '%Y' "$CD_PENDING_FILE" 2>/dev/null || echo 0)"
    [ "$mtime" -gt 0 ] || return 1
    [ "$(( now - mtime ))" -lt "$CD_DEPLOY_INFLIGHT_GRACE" ]
}

cd_load_state() {
    local file="$1"
    [ -f "$file" ] || return 1
    set -a
    # 状态文件是我们自己生成的 KEY=VALUE，不含命令替换。
    . "$file"
    set +a
    export APP_IMAGE FRONTEND_IMAGE MOCK_ERP_IMAGE
}

cd_report_state() {
    [ -f "$CD_STATE_FILE" ] || { warn "没有状态文件 $CD_STATE_FILE"; return 0; }
    info "当前版本（$CD_STATE_FILE）："
    grep -E '^(VERSION|TAG|GIT_SHA|APP_IMAGE_ID|DEPLOYED_AT|DEPLOYED_BY)=' "$CD_STATE_FILE" | sed 's/^/      /'
}

cd_record_history() {
    mkdir -p "$CD_STATE_DIR/history"
    cp "$CD_STATE_FILE" "$CD_STATE_DIR/history/$(date +%Y%m%dT%H%M%S)-${CD_RUN_TAG:-unknown}.env"
}

# ---------------------------------------------------------------- 健康与冒烟
cd_wait_healthy() {
    # 实测：换版 44s、回退 39s（含 compose 自己等的健康）。默认 120s 是留了
    # 一倍余量的值，不是拍脑袋的 420s。
    local deadline="${1:-120}"
    local end=$((SECONDS + deadline))
    local bad line
    while [ "$SECONDS" -lt "$end" ]; do
        # --all：不带它的话，崩掉退出的容器根本不出现在列表里，健康判定会把
        # 「已经死了」误判成「没问题」。
        #
        # 别写成 `[ ... ] && break`：调用方多是 set -e，判断为假时整条 AND 列表
        # 返回 1，会被当成命令失败直接杀掉脚本（bootstrap.sh 里记过这个坑，表现
        # 出来是循环卡死）。
        line="$(cd_compose ps --all --format '{{.Service}} {{.Health}}' 2>/dev/null || true)"
        bad="$(printf '%s\n' "$line" \
            | grep -v '^sandbox-image-loader' \
            | grep -vE 'healthy$' \
            | grep -c . || true)"
        if [ "$bad" -eq 0 ] && [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ]; then
            cd_compose ps --format 'table {{.Service}}\t{{.Status}}'
            return 0
        fi
        sleep 5
    done
    warn "健康检查超时（${deadline}s）"
    cd_compose ps --all --format 'table {{.Service}}\t{{.State}}\t{{.Health}}' >&2 || true
    return 1
}

cd_smoke() {
    local base="http://127.0.0.1:$HTTP_PORT"
    local bad=0 code body

    # /healthz 与 /health 是 nginx 里仅有的两个 auth_basic off 端点
    #（见 deploy/nginx/nginx.conf），所以探针不需要密码。
    body="$(curl -sS --max-time 10 "$base/healthz" 2>/dev/null || true)"
    if [ "$body" = "ok" ]; then info "/healthz ok"
    else warn "/healthz 返回 '$body'（期望 'ok'）"; bad=1; fi

    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$base/health" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then info "/health 200（nginx 已代理到 backend）"
    else warn "/health 返回 $code（期望 200）"; bad=1; fi

    # 带认证的深链路：这一条同时验证 nginx 活着、Basic Auth 在放行、以及
    # nginx→backend 的 X-Internal-Auth 共享密钥两边一致。密钥不一致的表现就是
    # 所有 /api 401（前置检查里已拦，这里是运行时的第二道）。
    if [ -n "${SMOKE_BASIC_USER:-}" ] && [ -n "${SMOKE_BASIC_PASSWORD:-}" ]; then
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
            -u "$SMOKE_BASIC_USER:$SMOKE_BASIC_PASSWORD" "$base/api/history" 2>/dev/null || true)"
        case "$code" in
            200) info "/api/history 200（认证 + 内部密钥链 + Mongo 都通）" ;;
            401) warn "/api/history 401：密码错，或 nginx 与 backend 的 INTERNAL_AUTH_TOKEN 不一致"
                 bad=1 ;;
            *)   warn "/api/history 返回 $code"; bad=1 ;;
        esac

        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
            -u "$SMOKE_BASIC_USER:$SMOKE_BASIC_PASSWORD" "$base/" 2>/dev/null || true)"
        if [ "$code" = "200" ]; then info "/ 200（前端在跑）"
        else warn "/ 返回 $code（期望 200）"; bad=1; fi
    else
        warn "未提供 SMOKE_BASIC_USER / SMOKE_BASIC_PASSWORD，跳过认证后的冒烟："
        warn "  前端与 /api 链路**未验证**（探活全绿说明不了代理链路是好的）。"
        warn "  在部署机上填 /etc/erp-agent/smoke.env —— 它由发布闸门以 root 读取，"
        warn "  不经过 runner 的进程环境。"
    fi
    return "$bad"
}

cd_diagnose() {
    warn "诊断信息（贴给维护者）："
    cd_compose ps --all --format 'table {{.Service}}\t{{.State}}\t{{.Health}}' >&2 || true
    echo >&2
    cd_compose logs --tail=120 backend >&2 || true
}

# ---------------------------------------------------------------- 影子启动
# 换版**之前**让新镜像以旁观者身份跑一遍（方案 5.5）。单副本 + 进程内状态决定了
# 真流量切分做不到，这是这个约束下唯一有意义的 canary。
#
# 它存在的理由是约束 A 里那个数字：坏版本一旦走到换版，停机窗口是 ~134s
#（compose 探测依赖失败 ~100s + 回滚 ~40s）。影子阶段拦下的故障，生产一秒都不用停。
#
# 为什么**不**接 sandbox 网络、不设 DOCKER_HOST、不挂 docker.sock（原始行为）：
# 让第二个 backend 进程碰到 dind，它的 prune_orphans() 会无条件删掉所有
# erp-sandbox-warm-*（见 README 架构约束 B）—— 影子启动会把生产的预热池清空，
# 自己把自己变成一次故障。docker 不可达时那两条启动路径都是优雅降级的
#（prune 打一行 warning 后 return 0，ensure_warm_pool 逐容器 catch），所以影子
# 容器照常起得来，验证的也正好是"除沙箱外的一切"。
#
# == 沙箱链路验证（CD_SHADOW_SANDBOX=1，默认关） ==
# 开启时影子启动**额外**用一个独立 compose project 起一个临时 dind，
# 在里面跑沙箱容器创建 + 代码执行。它**不碰**：
#   - 生产的 dind（erp-agent_dind_1）—— 用独立 project 的 dind
#   - 生产预热池（erp-sandbox-warm-*）—— 独立 dind 里的容器和生产 dind 隔离
#   - mcp-sandbox 网络 —— 临时 dind 不接 mcp-sandbox
# 代价：多起一个 dind 容器（~256m），验证完即销毁。开关默认关：沙箱链路较稳，
# 多一个 dind 让影子启动从 ~30s 变成 ~120s，不值得每次都付。
cd_shadow_sandbox() {
    local shadow_name="$1" timeout="${CD_SHADOW_SANDBOX_TIMEOUT:-120}"
    local proj="erp-shadow-sandbox-$$"
    local dind_name="${proj}-dind-1"
    local net="${proj}_default"
    local rc=0

    log "影子沙箱验证（独立 project $proj，不碰生产 dind / 预热池）"

    # 起一个临时 dind：用独立 network，不接 mcp-sandbox。
    # --privileged 是 dind 的硬需求，与生产 dind 一致。
    if ! docker run -d --name "$dind_name" \
            --privileged \
            --network "$net" \
            -e DOCKER_TLS_CERTDIR="" \
            -v /tmp:/tmp:ro \
            docker:27-dind \
            --storage-driver=overlay2 --mtu=1400 >/dev/null 2>&1; then
        # 网络可能不存在，先建一个
        docker network create "$net" >/dev/null 2>&1 || true
        if ! docker run -d --name "$dind_name" \
                --privileged \
                --network "$net" \
                -e DOCKER_TLS_CERTDIR="" \
                -v /tmp:/tmp:ro \
                docker:27-dind \
                --storage-driver=overlay2 --mtu=1400 >/dev/null 2>&1; then
            warn "影子沙箱：临时 dind 起不来"
            return 1
        fi
    fi

    # 等 dind 就绪
    local waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if docker exec "$dind_name" docker info >/dev/null 2>&1; then
            info "影子沙箱：dind 就绪（${waited}s）"
            break
        fi
        sleep 3
        waited=$((waited + 3))
    done
    if [ "$waited" -ge "$timeout" ]; then
        warn "影子沙箱：dind ${timeout}s 内没就绪"
        docker rm -f "$dind_name" >/dev/null 2>&1 || true
        docker network rm "$net" >/dev/null 2>&1 || true
        return 1
    fi

    # 在临时 dind 里拉沙箱镜像 + 跑一个容器 + 执行代码。
    # 这三步覆盖了沙箱链路的核心路径：daemon 可达 → 容器创建 → 代码执行。
    # 不接 MCP 网络：影子阶段只验「沙箱能跑代码」，不验「沙箱能调 MCP」（那是
    # 换版后的冒烟 + 集成测试的事）。
    local sandbox_img
    sandbox_img="$(sed -n 's/^SANDBOX_IMAGE=//p' "$CD_REPO_ROOT/deploy/.env" 2>/dev/null | head -1 | tr -d '"'"'"'')"
    sandbox_img="${sandbox_img:-python:3.11-slim}"

    info "影子沙箱：pull $sandbox_img"
    if ! docker exec "$dind_name" docker pull "$sandbox_img" >/dev/null 2>&1; then
        warn "影子沙箱：pull $sandbox_img 失败（dind 出网有问题？）"
        docker rm -f "$dind_name" >/dev/null 2>&1 || true
        docker network rm "$net" >/dev/null 2>&1 || true
        return 1
    fi

    # 起一个沙箱容器并执行代码：echo + python 一行。两个断言：
    #   1. 容器能创建（docker run 成功）
    #   2. 代码能在里面执行（python 输出预期值）
    local out
    out="$(docker exec "$dind_name" docker run --rm \
        --read-only --tmpfs /tmp:rw,size=64m --memory=256m --cpus=0.5 \
        "$sandbox_img" \
        python -c 'print("shadow-sandbox-ok")' 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -q 'shadow-sandbox-ok'; then
        warn "影子沙箱：沙箱容器创建或代码执行失败："
        printf '%s\n' "$out" | tail -10 >&2
        docker rm -f "$dind_name" >/dev/null 2>&1 || true
        docker network rm "$net" >/dev/null 2>&1 || true
        return 1
    fi
    info "影子沙箱：沙箱容器创建 + 代码执行通过"

    # 清理
    docker rm -f "$dind_name" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
    return 0
}

cd_shadow() {
    local timeout="${CD_SHADOW_TIMEOUT:-180}"
    local name="erp-shadow-$(date +%s)-$$"
    local net_edge="${PROJECT}_edge" net_data="${PROJECT}_data"
    local rc=0

    log "影子启动（$APP_IMAGE，旁观者身份）"

    docker network inspect "$net_edge" >/dev/null 2>&1 \
        || { warn "找不到网络 $net_edge（compose project 名变了？）"; return 1; }
    docker network inspect "$net_data" >/dev/null 2>&1 \
        || { warn "找不到网络 $net_data"; return 1; }

    docker rm -f "$name" >/dev/null 2>&1 || true

    # 先接 edge：多网络容器只有一条默认路由，指向**第一个**接入的网络。edge 不是
    # internal 的，默认路由必须走它，否则影子容器出不了网、真实 LLM 那条断言必挂。
    # environment 逐条抄 compose 里 backend 的覆盖项（那些是"容器内不可达地址"的
    # 修正），不抄的话影子容器会去连 localhost:9000 而把 mcp 判成不可用。
    if ! docker run -d --name "$name" \
            --network "$net_edge" \
            --env-file "$CD_REPO_ROOT/deploy/.env" \
            -e MCP_SERVER_URL=http://mcp:9000 \
            -e ERP_BASE_URL=http://mock-erp:8081 \
            -e ALLOW_LOCAL_SHELL_FALLBACK=false \
            -e AUTH_MODE=proxy \
            -e CD_SHADOW_LLM="${CD_SHADOW_LLM:-1}" \
            -v "$CD_REPO_ROOT/src/skills:/app/src/skills:ro" \
            --tmpfs /app/src/download \
            "$APP_IMAGE" >/dev/null; then
        warn "影子容器起不来（docker run 失败）"
        return 1
    fi

    if ! docker network connect "$net_data" "$name" >/dev/null 2>&1; then
        warn "把影子容器接进 $net_data 失败"
        docker rm -f "$name" >/dev/null 2>&1 || true
        return 1
    fi

    # 等 /health。等的是"进程起来 + Mongo 连上"，不是"预热池建好"—— 后者在
    # 这里必然失败且不影响健康（见上）。
    local waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if docker exec "$name" python -c \
            "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=3).status==200 else 1)" \
            >/dev/null 2>&1; then
            info "影子容器 /health 就绪（${waited}s）"
            break
        fi
        sleep 3
        waited=$((waited + 3))
    done
    if [ "$waited" -ge "$timeout" ]; then
        warn "影子容器 ${timeout}s 内 /health 没到 200"
        docker logs --tail=60 "$name" >&2 || true
        docker rm -f "$name" >/dev/null 2>&1 || true
        return 1
    fi

    # 探针用 docker cp 送进去再跑，而不是把断言塞成一行 python -c：阶段 2 的教训是
    # 能单独重跑的脚本才定位得动问题，一行 -c 做不到。
    if ! docker cp "$CD_LIB_DIR/shadow_probe.py" "$name:/tmp/shadow_probe.py" >/dev/null 2>&1; then
        warn "把探针拷进影子容器失败"
        docker rm -f "$name" >/dev/null 2>&1 || true
        return 1
    fi

    docker exec "$name" python /tmp/shadow_probe.py || rc=1

    # 沙箱链路验证（CD_SHADOW_SANDBOX=1 时）。在影子容器主探针之后、清理之前：
    # 影子容器还在跑时做沙箱验证，用完后一起清理。
    if [ "${CD_SHADOW_SANDBOX:-0}" = "1" ]; then
        if ! cd_shadow_sandbox "$name"; then
            warn "影子沙箱验证未通过"
            rc=1
        fi
    else
        info "影子沙箱验证跳过（CD_SHADOW_SANDBOX 未设 1）"
    fi

    if [ "$rc" -ne 0 ]; then
        warn "影子容器日志尾部："
        docker logs --tail=40 "$name" >&2 || true
    fi
    docker rm -f "$name" >/dev/null 2>&1 || true
    return "$rc"
}

# ---------------------------------------------------------------- 通知
# 永远返回 0：通知发不出去不该让一次发布变成失败。webhook 从
# /etc/erp-agent/notify.env 读（root 0600），不经过 runner 的进程环境。
cd_notify() {
    local event="$1"
    shift || true
    [ -f "$CD_LIB_DIR/notify.sh" ] || return 0
    bash "$CD_LIB_DIR/notify.sh" \
        --event "$event" \
        --version "${CD_NOTIFY_VERSION:-}" \
        --tag  "${CD_RUN_TAG:-}" \
        --sha  "${CD_NOTIFY_SHA:-}" \
        --exit-code "${CD_NOTIFY_EXIT:-}" \
        --duration "${CD_DEPLOY_SECONDS:-}" \
        "$@" >&2 || warn "通知发送失败（不影响发布结果）"
    return 0
}
