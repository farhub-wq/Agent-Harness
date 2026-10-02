#!/usr/bin/env bash
# 发布 / 回滚生产栈。
#
#   bash deploy/cd/deploy.sh deploy   <env> <tag> <sha>   发布
#   bash deploy/cd/deploy.sh init     <env> <tag> <sha>   首次接管：树与镜像都在本机，只建立状态文件
#   bash deploy/cd/deploy.sh rollback <env> [--check]     回滚到上一版 / 只校验回滚能力
#
# <tag> 是不可变镜像 tag，形如 sha-79c3c3a1b2c3（或本机自测用的 local）。
# <sha> 是完整 40 位 commit，决定同步哪一版的源码树。**必填**：只换镜像不同步
# 源码树会让「运行中的代码」和「状态文件记的版本」脱节。
#
# 退出码见 lib.sh 的 CD_EXIT_*。回滚成功是 5 而不是 0 —— 回滚不算发布成功。
#
# 这个脚本刻意不做的事：
#   - 不编译。镜像必须已经在本地 docker daemon（--no-build）。构建由 CI 在跑
#     本脚本之前完成，且只在目标机本地构建。
#   - 不碰 mongo / dind 的容器。它们没有新镜像，up -d 不会重建它们，正在跑的
#     沙箱容器和 Mongo 数据都活着。
#   - 不修改仓库里的 docker-compose.yml。换版靠 state/<env>.override.yml。
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat >&2 <<'EOF'
用法：
  bash deploy/cd/deploy.sh deploy   <env> <tag> <sha>   发布（同步到 <sha> 的树，换到 <tag> 的镜像）
  bash deploy/cd/deploy.sh init     <env> <tag> <sha>   首次接管：用本机现有的树和镜像建立状态文件
  bash deploy/cd/deploy.sh rollback <env> [--check]     回滚 / --check 只校验回滚能力不执行

可选环境变量：
  SMOKE_BASIC_USER / SMOKE_BASIC_PASSWORD
      带认证的深链路冒烟（/ 与 /api/history）需要它们。不传则只探 /healthz 与
      /health 两个免认证端点，前端与 /api 链路不被验证。CI 里从 Secrets 注入。
  DEPLOYED_BY          写进状态文件的发布者，CI 里传 github-actions
  CD_ALLOW_INFRA_CHANGE=1
      允许把 docker-compose.yml / dind-daemon.json 的改动自动应用。默认拒绝。
  CD_SOAK_SECONDS      换版后的观察窗长度，默认 0（阶段 4 打开）
EOF
}

# ---------------------------------------------------------------- 阶段 5 占位
cd_backup() {
    # 阶段 5 会在这里做 mongodump + restore 自检，失败 exit 2。
    warn "备份尚未实现（阶段 5）：本次发布**没有**数据库备份。"
    warn "  Mongo 数据如果被这次改动搞坏，只能靠人工。"
    return 0
}

cd_shadow() {
    # 阶段 4 会在这里用新镜像起一次性容器做旁观者验证，失败 exit 4。
    warn "影子启动尚未实现（阶段 4）：新镜像**没有**在换版前单独验过。"
    return 0
}

cd_soak() {
    local seconds="${CD_SOAK_SECONDS:-0}"
    [ "$seconds" -gt 0 ] || { info "观察窗关闭（CD_SOAK_SECONDS=0，阶段 4 打开）"; return 0; }
    log "观察窗 ${seconds}s：每 15s 探一次 /health，并扫日志里的错误"
    local end=$((SECONDS + seconds)) code
    while [ "$SECONDS" -lt "$end" ]; do
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
            "http://127.0.0.1:$HTTP_PORT/health" 2>/dev/null || true)"
        if [ "$code" != "200" ]; then
            warn "观察窗内 /health 返回 $code"
            return 1
        fi
        sleep 15
    done
    local errs
    errs="$(cd_compose logs --since "${seconds}s" 2>/dev/null \
        | grep -cE 'CRITICAL|Traceback' || true)"
    if [ "${errs:-0}" -gt 0 ]; then
        warn "观察窗内日志出现 $errs 处 CRITICAL/Traceback"
        cd_compose logs --since "${seconds}s" 2>/dev/null | grep -E 'CRITICAL|Traceback' | tail -20 >&2 || true
        return 1
    fi
    info "观察窗通过"
    return 0
}

# ---------------------------------------------------------------- 起 + 验
cd_apply_and_verify() {
    local force_nginx="${1:-0}"
    local up_rc=0

    log "重建容器（--no-build：跑的就是本机那组镜像，不在目标机上编译）"

    # `up -d` 必须前台跑完再判健康。它的阻塞来自 depends_on 的健康条件，而这个
    # 阻塞有两个作用：一是保证「返回 0」意味着容器**确实换成新的了**，二是它
    # 自己就是坏版本的第一道探测器。2026-10-02 试过把它放后台并行等健康，结果
    # cd_wait_healthy 判在了换版**前**那批旧容器上直接通过 —— 部署会报成功而新
    # 镜像根本没起来，是个危险的竞态，不要那样写。
    #
    # 真正该省的是后面那 120s：compose 非 0 退出说明依赖链已经确定起不来了，
    # 再空等健康超时没有意义，直接进回滚。实测坏版本的停机窗口因此从 ~260s
    # 降到 ~140s（compose 探测 ~100s + 回滚 ~40s）。
    cd_compose up -d --no-build || {
        up_rc=$?
        warn "compose up 退出码 $up_rc —— 依赖链没起来，不再空等健康超时"
        cd_compose ps --all >&2 || true
        return 1
    }

    if [ "$force_nginx" = "1" ]; then
        # 约束 C 的推论二：bind mount 的文件**内容**变了，`up -d` 不会重建
        # nginx（Docker 只看容器配置，不看挂载文件内容）。--no-deps 是关键：
        # 不加它 compose 可能连带重建依赖，而重建 dind 会杀掉正在跑的沙箱容器。
        log "deploy/nginx/** 有变化 → 强制重建 nginx"
        cd_compose up -d --no-build --force-recreate --no-deps nginx
    fi

    log "等 healthy（实测换版 44s / 回退 39s，超时按一倍余量取 120s）"
    cd_wait_healthy 120 || return 1

    log "冒烟"
    cd_smoke || return 1
    return 0
}

# ---------------------------------------------------------------- deploy
cd_action_deploy() {
    [ -n "${TAG:-}" ] || die "deploy 需要 <tag>（形如 sha-79c3c3a1b2c3，或 local）" "$CD_EXIT_PRECHECK"
    [ -n "${SHA:-}" ] || die "deploy 需要完整的 <sha>（40 位）。只有 tag 不够：还要同步那一版的源码树。" "$CD_EXIT_PRECHECK"
    CD_RUN_TAG="$TAG"

    cd_preflight
    cd_lock

    cd_image_refs "$TAG"
    cd_assert_images_local \
        || die "本机没有 $(cd_all_images | tr '\n' ' ') 里的某些镜像。CI 应先在本机构建出这个 tag。" "$CD_EXIT_PRECHECK"
    cd_assert_repo_has "$SHA" || cd_fetch_repo || true
    cd_assert_repo_has "$SHA" \
        || die "裸仓库 $CD_IMAGE_REPO 里没有 $SHA，fetch 也没拿到。" "$CD_EXIT_PRECHECK"

    local old_sha old_nginx old_version
    old_sha="$(cd_state_get "$CD_STATE_FILE" GIT_SHA || true)"
    old_nginx="$(cd_state_get "$CD_STATE_FILE" NGINX_TREE_SHA256 || true)"
    old_version="$(cd_state_get "$CD_STATE_FILE" VERSION || true)"

    cd_check_infra_change "$old_sha" "$SHA"

    cd_backup || exit "$CD_EXIT_BACKUP"

    # prev 只在真的存在当前版本时才写，否则会把「首次发布」伪造出一个上一版。
    if [ -f "$CD_STATE_FILE" ]; then
        mkdir -p "$CD_STATE_DIR"
        cp "$CD_STATE_FILE" "$CD_PREV_FILE"
        info "上一版已记为 $old_version（$old_sha）"
    fi

    log "同步源码树到 $SHA"
    if ! cd_sync_tree "$SHA"; then
        warn "同步失败，尝试用上一版的树还原"
        if [ -n "$old_sha" ] && cd_sync_tree "$old_sha"; then
            info "已还原到 $old_sha"
        else
            warn "还原也失败（或没有上一版可还原）—— 生产树现在是半新半旧的状态，需要人工介入"
        fi
        exit "$CD_EXIT_SYNC"
    fi
    if ! cd_assert_synced; then
        warn "同步结果不完整，还原到上一版"
        [ -n "$old_sha" ] && cd_sync_tree "$old_sha" || true
        exit "$CD_EXIT_SYNC"
    fi
    CD_TREE_HASH="$(cd_content_hash "$SHA")"
    info "树快照 sha256=${CD_TREE_HASH:0:16}…"

    # pending 写在正式状态之前：中途被打断时它会留在磁盘上，巡检会告警 ——
    # 这是「发布卡在半途」唯一可靠的信号。
    cd_write_state "$CD_PENDING_FILE" "$TAG" "$SHA" "${DEPLOYED_BY:-$(whoami)@$(hostname)}"

    cd_shadow || exit "$CD_EXIT_SHADOW"

    cd_write_override

    local new_nginx force_nginx=0
    new_nginx="$(cd_nginx_hash)"
    if [ "$new_nginx" != "$old_nginx" ]; then force_nginx=1; fi

    if cd_apply_and_verify "$force_nginx"; then
        if ! cd_soak; then
            warn "观察窗未通过，开始回滚"
            cd_do_rollback "$CD_EXIT_SOAK_ROLLED_BACK"
        fi
        mv "$CD_PENDING_FILE" "$CD_STATE_FILE"
        cd_record_history
        log "发布成功：$TAG（$SHA）"
        cd_report_state
        exit "$CD_EXIT_OK"
    fi

    warn "tag=$TAG 换版后验证未通过，开始回滚"
    cd_do_rollback "$CD_EXIT_ROLLED_BACK"
}

# ---------------------------------------------------------------- init
cd_action_init() {
    [ -n "${TAG:-}" ] || die "init 需要 <tag>（本机现有镜像的 tag）" "$CD_EXIT_PRECHECK"
    [ -n "${SHA:-}" ] || die "init 需要完整的 <sha>（当前源码树对应的 commit）" "$CD_EXIT_PRECHECK"
    CD_RUN_TAG="$TAG"

    cd_preflight
    cd_lock
    cd_image_refs "$TAG"
    cd_assert_images_local \
        || die "本机没有 $(cd_all_images | tr '\n' ' ')。先 docker compose build。" "$CD_EXIT_PRECHECK"
    cd_assert_repo_has "$SHA" \
        || die "裸仓库 $CD_IMAGE_REPO 里没有 $SHA。init 需要能算出这一版的内容哈希。" "$CD_EXIT_PRECHECK"

    CD_TREE_HASH="$(cd_content_hash "$SHA")"
    cd_write_override
    mkdir -p "$CD_STATE_DIR"
    cd_write_state "$CD_STATE_FILE" "$TAG" "$SHA" "init@$(hostname)"
    log "已建立状态文件：$CD_STATE_FILE"
    cd_report_state
    exit "$CD_EXIT_OK"
}

# ---------------------------------------------------------------- rollback
# 只校验「回滚能力是否具备」，不执行。巡检 cron 调它，提前发现回滚能力已经
# 不具备了（比如 prev 快照被删、旧镜像被清）。0 = 具备，1 = 不具备。
cd_rollback_check() {
    local bad=0
    [ -f "$CD_PREV_FILE" ] || { warn "没有 $CD_PREV_FILE：从未成功发布过，或状态目录被清"; bad=1; }

    if [ "$bad" -eq 0 ]; then
        local sha
        sha="$(cd_state_get "$CD_PREV_FILE" GIT_SHA || true)"
        [ -n "$sha" ] || { warn "prev 里没有 GIT_SHA —— 回滚不出源码树"; bad=1; }
        if [ -n "$sha" ] && ! cd_assert_repo_has "$sha"; then
            warn "裸仓库里没有 prev 的 commit $sha（可 fetch 后再试）"
            cd_fetch_repo || true
            cd_assert_repo_has "$sha" || { warn "fetch 后仍然没有 $sha —— 回滚不出源码树"; bad=1; }
        fi

        # 状态里存的是 digest（tag 可以被重新指向，digest 不能）。回滚前必须
        # 确认「prev 记的那个 digest」和「本机这个 tag 现在指向的」是同一个 ——
        # 不一致说明有人动过 tag，这时回滚会滚到一个未知的东西上。
        local ref id key
        for key in APP_IMAGE:APP_IMAGE_ID FRONTEND_IMAGE:FRONTEND_IMAGE_ID MOCK_ERP_IMAGE:MOCK_ERP_IMAGE_ID; do
            ref="$(cd_state_get "$CD_PREV_FILE" "${key%%:*}" || true)"
            id="$(cd_state_get "$CD_PREV_FILE" "${key##*:}" || true)"
            if [ -z "$ref" ]; then
                warn "prev 里缺 ${key%%:*}"; bad=1; continue
            fi
            local now
            now="$(cd_image_id "$ref")"
            if [ -z "$now" ]; then
                warn "本机没有 prev 的镜像 $ref（回滚能力已丧失）"; bad=1; continue
            fi
            if [ -n "$id" ] && [ "$now" != "$id" ]; then
                warn "prev 的 $ref 指向的 digest 变了：记录 $id，现在 $now"
                bad=1
            fi
        done

        [ -n "$(cd_state_get "$CD_PREV_FILE" NGINX_TREE_SHA256 || true)" ] \
            || { warn "prev 里缺 NGINX_TREE_SHA256"; bad=1; }
    fi

    if [ "$bad" -ne 0 ]; then
        warn "回滚能力不具备 —— 现在出故障会滚不回去"
        return 1
    fi
    info "回滚能力具备（prev 完整、镜像在、源码树可取）"
    return 0
}

cd_action_rollback() {
    local check_only=0
    if [ "${CHECK_ONLY:-0}" = "1" ]; then check_only=1; fi

    cd_preflight
    cd_lock

    if [ "$check_only" = "1" ]; then
        # 只校验不执行：0 = 回滚能力具备，1 = 不具备。巡检 cron 用它提前发现
        # 「回滚能力已经没了」，而不是等真出事时才发现。
        if cd_rollback_check; then exit "$CD_EXIT_OK"; else exit "$CD_EXIT_PRECHECK"; fi
    fi

    # cd_do_rollback 自己会再校验一次（自动回滚也走那里），这里不重复。
    cd_do_rollback "$CD_EXIT_ROLLED_BACK"
}

cd_do_rollback() {
    local exit_code="$1"

    cd_compose logs --tail=120 backend >&2 || true

    # 自动回滚与手工回滚走同一道闸门：prev 不完整就拒绝执行。绝不做「半个
    # 回滚」—— 那会把状态搞得比现在更糟（比如树退了、镜像没退）。
    cd_rollback_check \
        || die "拒绝回滚：prev 快照不完整。服务状态未知，需要人工介入。" "$CD_EXIT_ROLLBACK_FAILED"

    cd_load_state "$CD_PREV_FILE" || die "读不出 $CD_PREV_FILE" "$CD_EXIT_ROLLBACK_FAILED"

    local rb_version rb_sha
    rb_version="$(cd_state_get "$CD_PREV_FILE" VERSION || true)"
    rb_sha="$(cd_state_get "$CD_PREV_FILE" GIT_SHA || true)"
    log "回滚到 ${rb_version:-?}（$rb_sha）"

    # 先还原源码树，再换版：镜像和树必须同时回到那一版，否则会出现「镜像旧、
    # 配置新」的不一致（宿主树是部署产物的一部分，见 README 的架构约束 C）。
    if ! cd_sync_tree "$rb_sha"; then
        warn "回滚时源码树还原失败"
        cd_diagnose
        exit "$CD_EXIT_ROLLBACK_FAILED"
    fi
    cd_assert_synced
    CD_TREE_HASH="$(cd_content_hash "$rb_sha")"

    local cur_nginx prev_nginx force_nginx=0
    cur_nginx="$(cd_nginx_hash)"
    prev_nginx="$(cd_state_get "$CD_PREV_FILE" NGINX_TREE_SHA256 || true)"
    if [ "$cur_nginx" != "$prev_nginx" ]; then force_nginx=1; fi

    cd_write_override

    if cd_apply_and_verify "$force_nginx"; then
        rm -f "$CD_PENDING_FILE"
        # 状态文件必须改成**实际在跑的**那一个。手工 rollback 时 state 指向的是
        # 刚被我们退掉的版本，不改的话巡检会报「运行中的镜像与状态文件不符」，
        # 而「线上跑的是哪个 commit」这个唯一真值源也就错了。
        CD_RUN_TAG="$rb_version"
        cd_write_state "$CD_STATE_FILE" "$rb_version" "$rb_sha" "rollback@$(hostname)"
        cd_record_history
        # prev **保持不变**（不与被退掉的版本对调）：对调的话 prev 就指向那个
        # 刚刚验证失败的版本，下次谁再敲一次 rollback 就会滚到已知坏的版本上。
        # 代价是重复 rollback 是幂等的（重新应用同一版），这是刻意选的。
        log "已回滚，服务正常"
        cd_report_state
        exit "$exit_code"
    fi

    warn "回滚失败 —— 服务可能是坏的，需要人工介入"
    cd_diagnose
    exit "$CD_EXIT_ROLLBACK_FAILED"
}

# ---------------------------------------------------------------- 入口
ACTION="${1:-}"
ENV_NAME="${2:-}"
TAG="${3:-}"
SHA="${4:-}"
CHECK_ONLY=0
if [ "${3:-}" = "--check" ]; then CHECK_ONLY=1; fi

case "$ACTION" in
    deploy|init|rollback) ;;
    ""|-h|--help|help)
        usage
        if [ -z "$ACTION" ]; then exit "$CD_EXIT_PRECHECK"; else exit 0; fi
        ;;
    *)
        warn "未知动作 '$ACTION'"
        usage
        exit "$CD_EXIT_PRECHECK"
        ;;
esac

if [ -z "$ENV_NAME" ]; then
    warn "缺少 <env>"
    usage
    exit "$CD_EXIT_PRECHECK"
fi

cd_load_env "$ENV_NAME"

case "$ACTION" in
    deploy)   cd_action_deploy ;;
    init)     cd_action_init ;;
    rollback) cd_action_rollback ;;
esac
