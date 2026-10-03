#!/usr/bin/env bash
# 执行 migrations/ 下的迁移。由 deploy/cd/deploy.sh 在**备份之后、同步源码树之前**
# 调用，也可以单独跑（演练、排查、--status）。
#
#   bash deploy/dr/migrate.sh --sha <commit>            对那个 commit 里的 migrations/ 执行
#   bash deploy/dr/migrate.sh --dir <目录>               对本地目录执行
#   bash deploy/dr/migrate.sh --dir <目录> --status      只报告，不碰数据库
#   bash deploy/dr/migrate.sh --dir <目录> --dry-run     只列出将要执行的
#
# 退出码：0 成功（含「没有迁移」）/ 1 失败。调用方 deploy.sh 把它映射成 8。
#
# ---------------------------------------------------------------- 为什么是 --sha 而不是读本地树
# 发布路径上这个脚本跑在 rsync **之前**，那时生产树里还是**上一版**的 migrations/。
# 所以迁移必须从**新 commit** 里取（git archive 到临时目录），读本地树会跑到旧
# 文件上 —— 而且跑得"成功"，因为旧文件本来就是合法的。位置在同步之前换来的是：
# 迁移失败时生产一个字节都没动过，与备份失败同一个语义。
#
# ---------------------------------------------------------------- 为什么只前进
# 没有 down 迁移，见 migrations/README.md。回滚靠备份，不靠 undo 脚本 ——
# undo 脚本只有被验证过才可信，而验证它的唯一办法是真的滚一遍，那等于把发布
# 流程的复杂度翻一倍，去换一个备份已经提供了的东西。
#
# ---------------------------------------------------------------- 账本放在哪
# 放在**应用库**（进程环境里的 MONGODB_DB_NAME）的 schema_version 集合里，而不是
# 单独建一个库。理由是备份：deploy/dr/backup.sh 逐库 dump + 恢复自检，账本在应用
# 库里就跟着数据一起被备份、一起被回滚。放到别处的话，从一份旧备份恢复之后，
# 账本会记着"迁移都已应用"，而实际的数据是旧结构 —— 那是最糟的一种不一致。
#
# 这个库名**从容器自己的环境读**（process.env.MONGODB_DB_NAME），不在宿主机上
# 解析 deploy/.env，也不写死。这与 backup.sh 里"库清单必须运行时枚举、不信配置"
# 的决定看起来相反，但两处面对的是不同的问题：备份要发现的是**配置里根本没有
# 的那个库**（checkpointing_db 是库默认值），而这里要的正是应用配置里那一个。
set -euo pipefail

DR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../cd/lib.sh
source "$DR_DIR/../cd/lib.sh"
# shellcheck source=lib-dr.sh
source "$DR_DIR/lib-dr.sh"

DR_LEDGER_COLLECTION="${DR_LEDGER_COLLECTION:-schema_version}"
# 迁移文件必须长这样：四位编号 + 下划线 + 名字 + .js。宽一点或窄一点都会让
# 「按什么顺序跑」变成一个可以被误解的问题，所以它是写死的。
DR_MIGRATION_GLOB='[0-9][0-9][0-9][0-9]_*.js'

usage() { sed -n '2,11p' "$0" >&2; }

# 刻意**不用** lib.sh 的 cd_assert_tools：它要求 rsync/flock/curl/openssl，而迁移
# 一个都不用，少了任何一件时报的还是"这台机器没跑过 bootstrap.sh"—— 那句话会把
# 只想看一眼迁移账本的人指到完全错误的方向。这里只断言真的会用到的。
dr_assert_migrate_tools() {
    local need_git="$1" missing="" t
    for t in docker sha256sum; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    # git 只有 --sha 那条路要（--dir 不碰裸仓库）
    if [ -n "$need_git" ]; then
        command -v git >/dev/null 2>&1 || missing="$missing git"
    fi
    [ -n "$missing" ] || return 0
    warn "缺工具:$missing"
    return 1
}

# 取 --sha 的迁移目录时用的临时目录。只在本进程内用，用完即删。
DR_MIG_TMP=""
dr_mig_cleanup() {
    [ -n "${DR_MIG_TMP:-}" ] && rm -rf "$DR_MIG_TMP"
    DR_MIG_TMP=""
}

# ---------------------------------------------------------------- 纯逻辑（不碰 docker）
# 下面三个函数刻意不依赖 docker，也不依赖任何外部状态 —— 它们的输入是两个字符串。
# deploy/ci/dr-logic-test.sh 直接调它们，这样「排序对不对、账本比对对不对、
# 重复编号抓不抓得住」这几件事在本地和 PR 上都能验，不必起一套栈。

# $1 = migrations 目录。输出 "id<TAB>sha256<TAB>路径"，按 id 升序。
dr_list_migrations() {
    local dir="$1" f base id
    for f in "$dir"/$DR_MIGRATION_GLOB; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        id="${base%%_*}"
        printf '%s\t%s\t%s\n' "$id" "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
    done | sort
}

# $1 = dr_list_migrations 的输出，$2 = 账本（"id<TAB>checksum<TAB>applied_at"）。
# 输出待执行项 "APPLY<TAB>id<TAB>sha256<TAB>路径"；已经应用过的跳过。
#
# 已应用但**内容变了**是硬失败，不是跳过：那说明有人回头改了历史。数据库当前
# 的形状是按旧内容来的，而账本说它是新的 —— 接下来所有判断都建在一个错的
# 前提上。宁可在这里停住让人来认。
dr_plan() {
    local list="$1" applied="$2" bad=0 dup
    local id sha path a_sha

    dup="$(printf '%s\n' "$list" | cut -f1 | sort | uniq -d)"
    if [ -n "$dup" ]; then
        # 0001_a.js 与 0001_b.js 会撞成同一个编号，而账本的主键是编号 —— 第二个
        # 会写不进去，而那时它已经跑过了。
        warn "migrations/ 里有重复编号：$(printf '%s' "$dup" | tr '\n' ' ')"
        bad=1
    fi

    while IFS=$'\t' read -r id sha path; do
        [ -n "$id" ] || continue
        a_sha="$(printf '%s\n' "$applied" | awk -F'\t' -v i="$id" '$1==i{print $2; exit}')"
        if [ -n "$a_sha" ]; then
            if [ "$a_sha" != "$sha" ]; then
                warn "迁移 $id 已经应用过，但文件内容变了（账本 ${a_sha:0:12}… / 现在 ${sha:0:12}…）"
                warn "  已应用的迁移是**只读历史**。要改结构就新加一个编号，不要改旧的。"
                bad=1
            fi
            continue
        fi
        printf 'APPLY\t%s\t%s\t%s\n' "$id" "$sha" "$path"
    done <<< "$list"

    return "$bad"
}

# $1 = dr_list_migrations 的输出，$2 = 账本。账本里记着、但文件没了的编号。
# 只告警不失败：丢的是"当时做了什么"的记录，不是数据库的正确性，而为了一个
# 记账问题卡住生产发布是不划算的。
dr_check_orphans() {
    local list="$1" applied="$2" id
    while IFS=$'\t' read -r id _ _; do
        [ -n "$id" ] || continue
        if ! printf '%s\n' "$list" | awk -F'\t' -v i="$id" '$1==i{f=1} END{exit !f}'; then
            warn "账本里的迁移 $id 在 migrations/ 里没有对应文件 —— 迁移文件不该被删或改名"
        fi
    done <<< "$applied"
    return 0
}

# ---------------------------------------------------------------- 与 mongo 说话
# 账本里的每一行 -> "id<TAB>checksum<TAB>applied_at"。
dr_applied() {
    dr_mongo_eval '
        if (!process.env.MONGODB_DB_NAME) {
            throw new Error("MONGODB_DB_NAME 在 mongo 容器里没设 —— 它是 deploy/.env 里的一行（compose 的 env_file），先确认它在");
        }
        const L = db.getSiblingDB(process.env.MONGODB_DB_NAME);
        L.getCollection("'"$DR_LEDGER_COLLECTION"'")
         .find({}, {checksum: 1, applied_at: 1}).sort({_id: 1})
         .forEach(d => print(d._id + "\t" + (d.checksum || "") + "\t" + (d.applied_at || "")));
    ' | tr -d '\r' | grep -v '^[[:space:]]*$' || true
}

# 记账。**与迁移脚本分两次执行**：迁移成功的证据是它自己跑完，记账成功的证据是
# 这次往返跑通了。合成一次的话，"跑了一半断掉"会被记成"成功"。
#
# 参数是裸的 JS 正文 —— 哨兵由 dr_mongo_eval_checked 统一加（dr_wrap_js 在
# lib-dr.sh）。这里原先自己拼 JS 却没走那层包装，于是它**永远**被判成失败。
dr_record() {
    local id="$1" sha="$2" host
    host="$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-' || echo unknown)"
    dr_mongo_eval_checked "
        const L = db.getSiblingDB(process.env.MONGODB_DB_NAME);
        L.getCollection(\"$DR_LEDGER_COLLECTION\").insertOne({
            _id: \"$id\",
            checksum: \"$sha\",
            applied_at: new Date(),
            host: \"$host\"
        });
    "
}

dr_apply_one() {
    local id="$1" sha="$2" path="$3"
    dr_mongo_eval_checked "$(cat "$path")" || {
        warn "迁移 $id 执行失败（$path）"
        return 1
    }
    dr_record "$id" "$sha" || {
        warn "迁移 $id 跑完了，但记账写不进去 —— 下次发布会重跑它"
        return 1
    }
    return 0
}

# ---------------------------------------------------------------- 取迁移目录
# --dir 直接用；--sha 从裸仓库 archive 出来。输出目录路径；**输出为空 = 那个
# commit 里没有 migrations/ 目录**，那不是错误：回滚到阶段 5 之前的版本就是这样，
# 那条路必须还能走通。
dr_resolve_dir() {
    local sha="$1" dir="$2"
    if [ -n "$dir" ]; then
        [ -d "$dir" ] || { warn "不是目录：$dir"; return 1; }
        printf '%s' "$dir"
        return 0
    fi

    cd_assert_repo_has "$sha" || cd_fetch_repo || true
    cd_assert_repo_has "$sha" || { warn "裸仓库 $CD_IMAGE_REPO 里没有 $sha，取不出迁移"; return 1; }

    # 先问「那个 commit 里有没有 migrations/」再 archive。直接 archive 的话，
    # 路径不存在和别的原因失败都是同一条非零退出码 —— 于是「阶段 5 之前的版本
    # 没有这个目录」（正常）和「git 坏了」（不正常）会得到同一句报错。
    if ! git -C "$CD_IMAGE_REPO" cat-file -e "$sha:migrations" 2>/dev/null; then
        printf '%s' ""
        return 0
    fi

    DR_MIG_TMP="$(mktemp -d)"
    if ! git -C "$CD_IMAGE_REPO" archive --format=tar "$sha" migrations \
            | tar -x -C "$DR_MIG_TMP"; then
        warn "从 $sha 取 migrations/ 失败"
        return 1
    fi
    if [ ! -d "$DR_MIG_TMP/migrations" ]; then
        warn "archive $sha 成功，但解出来没有 migrations/ 目录 —— 这不该发生"
        return 1
    fi
    printf '%s' "$DR_MIG_TMP/migrations"
}

# ---------------------------------------------------------------- 主体
dr_run_migrate() {
    local sha="$1" dir="$2" status="${3:-0}" dry="${4:-0}"
    local d list applied plan rc=0 n

    dr_assert_migrate_tools "$sha" || return 1
    dr_assert_mongo_up || return 1

    trap dr_mig_cleanup EXIT

    d="$(dr_resolve_dir "$sha" "$dir")" || { rc=1; dr_mig_cleanup; return "$rc"; }
    if [ -z "$d" ]; then
        info "这个版本里没有 migrations/ 目录 —— 没有迁移要做"
        dr_mig_cleanup
        return 0
    fi

    list="$(dr_list_migrations "$d")"
    if [ -z "$list" ]; then
        info "migrations/ 里还没有迁移文件"
        dr_mig_cleanup
        return 0
    fi

    applied="$(dr_applied)"
    dr_check_orphans "$list" "$applied"

    if [ "$status" = "1" ]; then
        dr_print_status "$list" "$applied"
        dr_mig_cleanup
        return 0
    fi

    plan="$(dr_plan "$list" "$applied")" || {
        warn "迁移清单校验没通过，**一个迁移都没执行**"
        dr_mig_cleanup
        return 1
    }

    if [ -z "$plan" ]; then
        n="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
        info "数据库已是最新（$n 个迁移都已应用）"
        dr_mig_cleanup
        return 0
    fi

    info "待执行："
    printf '%s\n' "$plan" | while IFS=$'\t' read -r _ id _ _; do
        [ -n "$id" ] || continue
        printf '      %s\n' "$id"
    done

    if [ "$dry" = "1" ]; then
        info "--dry-run：什么都没执行"
        dr_mig_cleanup
        return 0
    fi

    while IFS=$'\t' read -r _ id psha path; do
        [ -n "$id" ] || continue
        log "应用迁移 $id"
        dr_apply_one "$id" "$psha" "$path" || { rc=1; break; }
    done <<< "$plan"

    dr_mig_cleanup
    return "$rc"
}

dr_print_status() {
    local list="$1" applied="$2" id sha path a_sha a_at
    echo "已应用："
    if [ -z "$applied" ]; then
        echo "  （无）"
    else
        while IFS=$'\t' read -r id a_sha a_at; do
            [ -n "$id" ] || continue
            printf '  %s  %s  %s\n' "$id" "${a_sha:0:12}" "${a_at:0:19}"
        done <<< "$applied"
    fi
    echo "待应用："
    local any=0
    while IFS=$'\t' read -r id sha path; do
        [ -n "$id" ] || continue
        if ! printf '%s\n' "$applied" | awk -F'\t' -v i="$id" '$1==i{f=1} END{exit !f}'; then
            printf '  %s  %s\n' "$id" "$(basename "$path")"
            any=1
        fi
    done <<< "$list"
    [ "$any" = "1" ] || echo "  （无）"
}

# ---------------------------------------------------------------- 入口
# BASH_SOURCE 守卫不是装饰：deploy/ci/dr-logic-test.sh 会 source 本文件取上面那几个
# 纯逻辑函数（dr_list_migrations / dr_plan / dr_check_orphans）。没有这个守卫，
# source 就会把测试进程当成一次真迁移跑起来。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    ARG_SHA=""
    ARG_DIR=""
    ARG_STATUS=0
    ARG_DRY=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --sha)      ARG_SHA="${2:-}"; shift 2 ;;
            --dir)      ARG_DIR="${2:-}"; shift 2 ;;
            --status)   ARG_STATUS=1; shift ;;
            --dry-run)  ARG_DRY=1; shift ;;
            -h|--help)  usage; exit 0 ;;
            *)          warn "未知参数 '$1'"; usage; exit 2 ;;
        esac
    done

    if [ -z "$ARG_SHA" ] && [ -z "$ARG_DIR" ]; then
        warn "要给 --sha <commit> 或 --dir <目录>"
        usage
        exit 2
    fi
    [ -n "${CD_ENV:-}" ] || cd_load_env "${CD_ENV_NAME:-production}"

    dr_run_migrate "$ARG_SHA" "$ARG_DIR" "$ARG_STATUS" "$ARG_DRY"
fi
