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

# deploy.sh 的退出码语义。CI 靠它区分处置方式：
#   0  成功
#   1  前置检查失败 —— 完全没动过
#   2  备份失败     —— 完全没动过
#   3  同步失败     —— 已还原源码树，业务未受影响
#   4  影子启动失败 —— 完全没动过，生产未受影响
#   5  换版后验证失败，已自动回滚（手工 rollback 成功同样是 5）
#   6  观察窗失败，已自动回滚
#   7  回滚也失败   —— 服务可能是坏的，需要人立刻介入
CD_EXIT_OK=0
CD_EXIT_PRECHECK=1
CD_EXIT_BACKUP=2
CD_EXIT_SYNC=3
CD_EXIT_SHADOW=4
CD_EXIT_ROLLED_BACK=5
CD_EXIT_SOAK_ROLLED_BACK=6
CD_EXIT_ROLLBACK_FAILED=7

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
    local need_gb="${1:-8}" avail_gb
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
    cd_assert_disk 8
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
# tag 用不可变的 sha-<12>；语义化 tag（vX.Y.Z）只是给人看的标签。
cd_image_refs() {
    local tag="$1"
    export APP_IMAGE="erp-agent-app:$tag"
    export FRONTEND_IMAGE="erp-agent-frontend:$tag"
    export MOCK_ERP_IMAGE="erp-mock:$tag"
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
        warn "  前端与 /api 链路**未验证**。CI 里从 Secrets 注入这两个值。"
    fi
    return "$bad"
}

cd_diagnose() {
    warn "诊断信息（贴给维护者）："
    cd_compose ps --all --format 'table {{.Service}}\t{{.State}}\t{{.Health}}' >&2 || true
    echo >&2
    cd_compose logs --tail=120 backend >&2 || true
}
