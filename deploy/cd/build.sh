#!/usr/bin/env bash
# 在**目标机本地**构建三个版本化镜像。由 .github/workflows/build.yml 调起。
#
#   bash deploy/cd/build.sh v1.0.0
#
# 产物：erp-agent-app / erp-agent-frontend / erp-mock 各两个 tag
#   <name>:v1.0.0        人读的语义化版本
#   <name>:sha-<12>      机器读的不可变 tag（deploy.sh 用的就是它）
# 两个 tag 指向同一个 image ID；发布时以 state 里记录的 digest 为准。
#
# 不推任何 registry —— 构建机 == 运行机（方案「已定决策」第一条）。
#
# 三件事在这个脚本里，而不是写在 workflow 的 run: 里：
#   1. path-filter  只改 src/** 就不重建前端（最贵的那次构建）
#   2. builder      用带内存/CPU 限额的那个，不用宿主 daemon 的默认构建器
#   3. 保留策略     显式 rmi 旧版本，**绝不**用 prune -a（那会让回滚能力归零）
# 阶段 2 的教训：能单独重跑的脚本才定位得动问题。
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

VERSION="${1:-}"
BUILDER="${BUILDER:-erp-agent-builder}"
IMAGE_KEEP="${IMAGE_KEEP:-5}"

[ -n "$VERSION" ] || die "用法：bash deploy/cd/build.sh <vX.Y.Z>" 64

# 镜像名从 lib.sh 取（CD_*_IMAGE_NAME），不在这里重写一遍 —— 名字只有在
# 「构建时打的 tag」和「发布时找的 tag」完全一致时才有意义。
# registry 前缀也来自 lib.sh（cd_registry_prefix）：留空时镜像名不加前缀，
# 行为与引入 registry 支持之前完全一致。
APP_IMAGE_NAME="${CD_APP_IMAGE_NAME}"
FRONTEND_IMAGE_NAME="${CD_FRONTEND_IMAGE_NAME}"
MOCK_IMAGE_NAME="${CD_MOCK_IMAGE_NAME}"
REGISTRY_PREFIX="$(cd_registry_prefix)"
[ -n "$REGISTRY_PREFIX" ] && info "registry 模式：前缀 $REGISTRY_PREFIX（构建后 --push）"

cd "$CD_REPO_ROOT"

# 这个脚本只在 CI 的 checkout 里跑 —— 它要读 git 历史算变更集。生产树
# /root/erp-agent 不是 git 仓库，在那里跑会在一堆 rev-parse 上失败，
# 报错还看不出原因。
git rev-parse --git-dir >/dev/null 2>&1 \
    || die "$CD_REPO_ROOT 不是 git 工作树。build.sh 在 CI 的 checkout 里跑，不在 /root/erp-agent 里跑。"

# ---------------------------------------------------------------- 版本与 sha
SHA="$(git rev-parse HEAD)"
SHA12="${SHA:0:12}"
TAG_SHA="sha-$SHA12"

TAG_SHA_OF_VERSION="$(git rev-parse --verify --quiet "${VERSION}^{commit}" || true)"
if [ -z "$TAG_SHA_OF_VERSION" ]; then
    die "本地没有 tag $VERSION。先 fetch（build.yml 里 fetch-depth: 0 就是为了这个）。"
fi
if [ "$TAG_SHA_OF_VERSION" != "$SHA" ]; then
    die "checkout 的 HEAD ($SHA) 不等于 $VERSION 指向的 commit ($TAG_SHA_OF_VERSION)。
    构建出的镜像会被打上一个它并不对应的版本号 —— 停在这里。"
fi

log "构建 $VERSION（$SHA12，镜像 tag $TAG_SHA）"

# ---------------------------------------------------------------- path-filter
# 判据是「**哪些构建上下文真的变了**」，不是「哪些路径变了」。
# 三个镜像的输入集是已知的、很小的：
#   app    ← src/**、Dockerfile、requirements*.txt、.dockerignore
#   frontend ← frontend/**
#   mock   ← deploy/mock-erp/**
# 其余路径（文档、deploy/cd、deploy/ci、deploy/runner、.github）不影响镜像内容，
# 不触发重建。
#
# 例外：docker-compose.yml / dind-daemon.json 变了就全量重建。拓扑文件不能
# 自动应用（deploy.sh 的 cd_check_infra_change 会拒），但"拒"发生在**发布**时，
# 那时镜像已经构建好了；全量重建保证这种情况下手上一定有一份完整的、对应当前
# 树的镜像，不会出现"三个镜像来自三个不同版本"的混合体。

# --match 是防御性的（当前远程一个书签 tag 都没有，所以它暂时不承重）：开发机上
# 有几个手打的书签 tag（memory-*-20260917），哪天它们被推上来，不带 --match 的
# git describe 就可能挑中那样一个跟发布无关的 tag，「上一个版本」于是变成一个
# 错误的值 —— 变更集会算错而输出看不出来。加这一个参数的代价是零。
PREV_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "${VERSION}^" 2>/dev/null || true)"
need_app=0; need_front=0; need_mock=0

if [ -z "$PREV_TAG" ]; then
    info "找不到上一个 tag —— 首次构建，三个镜像全建"
    need_app=1; need_front=1; need_mock=1
else
    info "上个版本 $PREV_TAG，按它算变更集"
    CHANGED="$(git diff --name-only "$PREV_TAG" "$VERSION")"
    if [ -z "$CHANGED" ]; then
        die "$PREV_TAG 与 $VERSION 之间没有任何改动 —— 这不该发生（release-please 只在有改动时发版）"
    fi
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            src/*|Dockerfile|requirements.txt|requirements-dev.txt|.dockerignore) need_app=1 ;;
            frontend/*)                                                        need_front=1 ;;
            deploy/mock-erp/*)                                                 need_mock=1 ;;
            docker-compose.yml|deploy/dind-daemon.json)
                warn "拓扑文件变了（$f）—— 三个镜像全量重建，保证手上有一套完整对应当前树的镜像"
                need_app=1; need_front=1; need_mock=1 ;;
            *) : ;;
        esac
    done <<<"$CHANGED"
fi

building=""
[ "$need_app" = 1 ]   && building="$building app"
[ "$need_front" = 1 ] && building="$building frontend"
[ "$need_mock" = 1 ]  && building="$building mock-erp"
info "需要构建：${building:-（无 —— 三个镜像都与上一版一致）}"

# ---------------------------------------------------------------- 工具
command -v docker >/dev/null || die "没有 docker"
docker buildx inspect "$BUILDER" >/dev/null 2>&1 \
    || die "找不到 buildx builder '$BUILDER'。跑 bash deploy/runner/setup-builder.sh。"

build_image() {
    # build_image <镜像名> <上下文> <Dockerfile>
    # 镜像名已含 registry 前缀（由调用方拼接），这里只负责构建 + 打 tag。
    local name="$1" context="$2" dockerfile="$3"
    info "构建 $name（context=$context）"
    # --builder 指到带限额的那个：宿主 daemon 的默认构建器跑在 docker.service 的
    # cgroup 里，runner 的 MemoryMax 管不到它（见 runner-limits.conf 的说明）。
    #
    # --provenance=false：docker-container 驱动下 provenance 默认开启，配合
    # --load 会尝试导出 manifest list，而 docker exporter 不支持 —— 报错信息
    #（"docker exporter does not currently support exporting manifest lists"）
    # 与真正的原因（我们要的是本地镜像，不是可推送的产物）离得很远。
    docker buildx build \
        --builder "$BUILDER" \
        --load \
        --provenance=false \
        -t "$name:$TAG_SHA" \
        -t "$name:$VERSION" \
        -f "$dockerfile" \
        "$context"
}

# 未变更的镜像：从**正在运行的容器**取 digest 再打新 tag，而不是重新构建。
# 比"从上一个版本的 tag 取"更可靠 —— 不依赖那个 tag 还在不在，也不依赖 state
# 文件（它在 /root 下，runner 读不到）。这也让「跳过构建」这件事在输出里看得见。
retag_from_running() {
    local service="$1" name="$2" cid image_id
    cid="$(docker ps -q --filter "label=com.docker.compose.service=$service" | head -1 || true)"
    if [ -z "$cid" ]; then
        warn "$service 没有正在运行的容器，取不到可沿用的 digest"
        return 1
    fi
    image_id="$(docker inspect -f '{{.Image}}' "$cid")"
    [ -n "$image_id" ] || return 1
    docker tag "$image_id" "$name:$TAG_SHA"
    docker tag "$image_id" "$name:$VERSION"
    info "$name 沿用运行中容器的镜像 ${image_id:0:19}…（未重建）"
    return 0
}

# registry 模式下把三个镜像推上去。--load 已经把它们打进本地 daemon 了，
# 这里用 docker push 推到 registry。推失败不 die —— 本地镜像仍在，发布可以
# 走本地模式（deploy.sh 的 docker pull 会因为找不到远程镜像而跳过，退化成本地）。
# 但要 warn：不推成功，新机器上 docker pull 会 404，远程发布退化。
push_to_registry() {
    [ "${CD_HAS_REGISTRY:-0}" = "1" ] || return 0
    local name
    for name in "$MOCK_FULL" "$APP_FULL" "$FRONT_FULL"; do
        info "推送 $name:$TAG_SHA"
        docker push "$name:$TAG_SHA" >/dev/null 2>&1 \
            || { warn "push $name:$TAG_SHA 失败 —— 本地镜像仍在，但远程发布会退化"; return 1; }
        info "推送 $name:$VERSION"
        docker push "$name:$VERSION" >/dev/null 2>&1 \
            || { warn "push $name:$VERSION 失败"; return 1; }
    done
    info "三个镜像已推到 $REGISTRY_PREFIX"
}

# 带 registry 前缀的完整镜像名（构建 / push / pull 都用它）
APP_FULL="${REGISTRY_PREFIX}${APP_IMAGE_NAME}"
FRONT_FULL="${REGISTRY_PREFIX}${FRONTEND_IMAGE_NAME}"
MOCK_FULL="${REGISTRY_PREFIX}${MOCK_IMAGE_NAME}"
export CD_HAS_REGISTRY="${CD_HAS_REGISTRY:-0}"

# ---------------------------------------------------------------- 构建
if [ "$need_mock" = 1 ]; then
    build_image "$MOCK_FULL" "./deploy/mock-erp" "./deploy/mock-erp/Dockerfile"
else
    retag_from_running mock-erp "$MOCK_FULL" \
        || build_image "$MOCK_FULL" "./deploy/mock-erp" "./deploy/mock-erp/Dockerfile"
fi

if [ "$need_app" = 1 ]; then
    build_image "$APP_FULL" "." "./Dockerfile"
else
    retag_from_running backend "$APP_FULL" \
        || build_image "$APP_FULL" "." "./Dockerfile"
fi

if [ "$need_front" = 1 ]; then
    build_image "$FRONT_FULL" "./frontend" "./frontend/Dockerfile"
else
    retag_from_running frontend "$FRONT_FULL" \
        || build_image "$FRONT_FULL" "./frontend" "./frontend/Dockerfile"
fi

# ---------------------------------------------------------------- 断言
# 三个都要在。只建了 app 而断言漏掉前端的话，发布会在换版时才报"本机没有
# erp-agent-frontend:sha-xxx" —— 那时已经动过生产树了。构建阶段断言比发布阶段
# 断言便宜得多：此刻生产还没被碰。
log "断言三个镜像都在本地且指向同一个 digest"
for name in "$MOCK_FULL" "$APP_FULL" "$FRONT_FULL"; do
    id_sha="$(cd_image_id "$name:$TAG_SHA")"
    id_ver="$(cd_image_id "$name:$VERSION")"
    [ -n "$id_sha" ] || die "$name:$TAG_SHA 不存在 —— buildx --load 没把它导进宿主 daemon"
    [ "$id_sha" = "$id_ver" ] || die "$name 的两个 tag 指向不同 digest：$TAG_SHA=$id_sha / $VERSION=$id_ver"
    info "$name  $id_sha"
done

# ---------------------------------------------------------------- 保留策略
# 只删 sha-* 这种构建产物的 tag，且**从不**用 `docker image prune -a`
#（那会删掉未被运行容器引用的全部镜像 = 回滚能力归零，不可逆）。
#
# 保留策略与回滚能力的关系要说清楚：**正在跑的那一版永远保留**（它被运行中的
# 容器引用着，下面的 running_ids 检查会跳过它）；上一版则在最近 N 个的窗口里 ——
# 连发 5 次版而一次都不部署的话，上一版会被挤出窗口。这正是 `rollback --check`
# 存在的理由（它会在你需要回滚之前发现这件事，见 deploy/runner/README.md）。
log "每个镜像保留最近 $IMAGE_KEEP 个版本，更老的显式 rmi"

# 正在被运行中容器引用的镜像 → 完整 image ID（sha256:…）。
# 必须和下面 cd_image_id 的 {{.Id}} 用同一种形式比：docker image ls 的
# {{.ID}} 是 12 位短 ID，和容器的 {{.Image}} 直接比永远不相等，
# 那会得到一个「检查过了、其实没检查」的假象。
running_ids="$(docker ps -q | xargs -r docker container inspect -f '{{.Image}}' 2>/dev/null | sort -u || true)"

prune_repo() {
    local repo="$1" kept=0 id tag ref full_id
    # 只把 sha-* 行当作「第几个版本」来数 —— 每个镜像恰好一个 sha-* tag，
    # 语义化 tag 不参与计数（它只是给人看的别名）。
    # 按 CreatedAt 倒序：新版本排前面，数过 IMAGE_KEEP 个之后的全是老的。
    while IFS=$'\t' read -r created id tag; do
        [ -n "$tag" ] || continue
        case "$tag" in sha-*) ;; *) continue ;; esac
        kept=$((kept + 1))
        [ "$kept" -le "$IMAGE_KEEP" ] && continue

        ref="$repo:$tag"
        full_id="$(cd_image_id "$ref")"
        [ -n "$full_id" ] || continue
        if printf '%s\n' "$running_ids" | grep -qx "$full_id"; then
            info "跳过 $ref（正在被运行中的容器使用）"
            continue
        fi
        # 按 ID 删，连同它的 vX.Y.Z 别名一起删 —— 只删 sha-* tag 的话，
        # 镜像本体被语义化 tag 拽着不放，磁盘一点没省，保留策略就成了摆设。
        if docker rmi "$full_id" >/dev/null 2>&1; then
            info "已删除 $ref（$full_id）"
        else
            warn "删除 $ref 失败（可能还有已停止的容器引用它），跳过"
        fi
    done < <(docker image ls "$repo" --format '{{.CreatedAt}}\t{{.ID}}\t{{.Tag}}' | sort -r)
}
prune_repo "$APP_FULL"
prune_repo "$FRONT_FULL"
prune_repo "$MOCK_FULL"
unset running_ids

# ---------------------------------------------------------------- 推送
# registry 模式：构建完成后统一 push。--load 已经打进本地 daemon 了，这里推。
# 推失败只 warn 不 die：本地镜像仍在，deploy.sh 的 docker pull 找不到远程镜像
# 时会退化成本地模式（见 deploy.sh 的 cd_pull_images）。
if [ "${CD_HAS_REGISTRY:-0}" = "1" ]; then
    log "推送镜像到 registry（$REGISTRY_PREFIX）"
    push_to_registry
fi

# 构建缓存会吃满 40G 磁盘。keep-storage 是**上限**，超了才回收。
log "回收 buildx 缓存（保留 6G）"
docker buildx prune --builder "$BUILDER" --keep-storage 6GB --force >/dev/null 2>&1 \
    || warn "buildx prune 失败（不影响本次构建）"

log "构建完成：$VERSION / $TAG_SHA"
info "三个镜像现在的 tag：$VERSION 与 $TAG_SHA（指向同一 digest）"
info "下一步：GitHub 上 dispatch deploy.yml，version=$VERSION，需要 production 环境的审批。"
