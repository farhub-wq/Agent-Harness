#!/usr/bin/env bash
# 恢复演练。回答一个 `backup.sh --verify` 回答不了的问题：
# **灾难真的发生了，这份备份能把系统跑起来吗 —— 以及要跑多久。**
#
#   bash deploy/dr/restore-drill.sh                 演练最新的一份备份
#   bash deploy/dr/restore-drill.sh <备份目录>       演练指定的一份（补演、排查）
#   bash deploy/dr/restore-drill.sh --list           列出现有备份
#
# 退出码：0 通过 / 1 未通过 / 2 用法错
# 报告写到 <备份目录>/drill-report.txt，并发一条 drill_report 通知。
#
# ---------------------------------------------------------------- 它和 --verify 的分工
# 两者都验「这份备份能不能恢复」，但判据的**成本约束**完全不同：
#   backup.sh --verify  每次备份后都跑，是发布路径上的硬门槛 —— 必须便宜、只读。
#                       所以它对 download-data 卷只验「可读且条目数与清单相符」。
#   本脚本              是人工/定时的，可以慢。它把卷**真的解开**，测端到端耗时，
#                       并留下报告。它证明的是「演练过」，而不是「没坏」。
#
# ---------------------------------------------------------------- 为什么绝不碰生产卷
# 演练要把卷解出来才能算验过，但解到哪里是个会出人命的决定：解回生产的
# erp-agent_download-data 卷，就是拿唯一那份用户报告去覆盖它自己 —— 一次演练
# 毁掉数据，正是这套东西存在的理由的反面。所以解到一个临时目录比对，真正的
# 恢复命令写在报告末尾，由人在灾难处置时自己执行。
#
# ---------------------------------------------------------------- 为什么复用 --verify 而不是抄一份
# 数据库那一段直接调 `backup.sh --verify`，不把 dr_verify 复制进来：那条路径
# 发布时也在走，抄第二份就等于有了两个「恢复自检」，而它们漂开的那天没有任何
# 东西会告诉你 —— 演练说着「通过」，真正卡住发布的是另一个。
#
# ---------------------------------------------------------------- 为什么现在没有 timer
# 结伴的 systemd timer 刻意没建：演练要解一份完整的卷、起一个临时 mongo，
# 在 2 核 3.6G 的机器上耗时不明（方案里这一条本来就是「先测出来再决定」）。
# 第一次在真机上跑完，看报告里的耗时，再决定它是每天一次还是只做人工季度动作。
# 在那之前加 timer 是在猜一个会影响生产的频率。
set -euo pipefail

DR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../cd/lib.sh
source "$DR_DIR/../cd/lib.sh"
# shellcheck source=lib-dr.sh
source "$DR_DIR/lib-dr.sh"

CD_BACKUP_DIR="${CD_BACKUP_DIR:-/var/backups/erp-agent}"

usage() { sed -n '2,10p' "$0" >&2; }

# ---------------------------------------------------------------- 卷
# 清单行：VOLUME <卷名> <文件> <sha256> <字节数> <条目数>
# 返回 0 通过、1 有问题；无论哪种都把结论写进 $DRILL_NOTES 供报告引用。
DRILL_NOTES=""
drill_note() { DRILL_NOTES="${DRILL_NOTES:+$DRILL_NOTES$'\n'}$1"; }

drill_volume() {
    local dir="$1"
    local vname vfile vsha vbytes ventries
    local found=0 rc=0 tmp got_sha n want

    while read -r _ vname vfile vsha vbytes ventries; do
        [ -n "${vfile:-}" ] || continue
        found=1

        if [ ! -f "$dir/$vfile" ]; then
            warn "演练失败：清单记了卷 $vname，但 $vfile 不在"
            drill_note "卷 $vname：文件 $vfile 不存在 —— 失败"
            rc=1
            continue
        fi

        # sha256 先验：解一个被截断的 tar，tar 自己未必报错（它可能只是提前结
        # 束），而「解出来少了一半文件」正是最难事后发现的一类损坏。
        got_sha="$(sha256sum "$dir/$vfile" | cut -d' ' -f1)"
        if [ "$got_sha" != "$vsha" ]; then
            warn "演练失败：$vfile 的 sha256 与清单不符"
            warn "  清单 $vsha"
            warn "  实际 $got_sha"
            drill_note "卷 $vname：sha256 与清单不符 —— 失败"
            rc=1
            continue
        fi

        tmp="$(mktemp -d)"
        if ! tar -xzf "$dir/$vfile" -C "$tmp"; then
            warn "演练失败：$vfile 解不开"
            rm -rf "$tmp"
            drill_note "卷 $vname：解包失败 —— 失败"
            rc=1
            continue
        fi

        # 比的是**常规文件数**，且两侧用同一个口径现算：tar 里 grep -v '/$'（丢掉
        # 目录，连带丢掉 tar 自己写进去的 `./` 根条目），解出来 find -type f。
        #
        # 刻意**不**去比清单里那一栏「条目数」：它是 `tar -tzf | grep -c .`，把
        # `./` 也算了一个，而 find 数不出这个条目 —— 照它比会在真机上恒差 1，
        # 也就是每次演练都报一次假失败。本地实测踩到过，这正是这一条写这么长的原因。
        want="$(tar -tzf "$dir/$vfile" 2>/dev/null | grep -vc '/$' || true)"
        n="$(find "$tmp" -type f | wc -l | tr -d ' ')"
        rm -rf "$tmp"

        if [ "$n" -ne "$want" ]; then
            warn "演练失败：$vname 解出 $n 个文件，归档里应有 $want 个"
            drill_note "卷 $vname：解出 $n 个文件，归档里应有 $want 个 —— 失败"
            rc=1
            continue
        fi

        # 清单里的条目数只用来给人看，不参与判定（理由见上）。它是数字的时
        # 候一并写出来，方便对不上时手工核对。
        info "卷 $vname 解出 $n 个文件（清单记 $ventries 个条目）"
        drill_note "卷 $vname：sha256 相符，解出 $n 个文件（清单记 $ventries 个条目）"
    done < <(grep '^VOLUME ' "$dir/manifest.txt" || true)

    if [ "$found" -eq 0 ]; then
        info "清单里没有卷 —— 跳过（本机还没生成过任何下载文件）"
        drill_note "卷：清单里没有，跳过"
    fi
    return "$rc"
}

# ---------------------------------------------------------------- 报告
# 「真正恢复时怎么做」那一段。**用引号 heredoc 原样写**，不用 printf 转义：正文里
# 全是 `$`、`${}` 和成对引号，转义过去之后写的人和读的人都要先在脑子里解一层，
# 而这段字的目标读者是**半夜出事的人**。`@@X@@` 是占位符，展开在下面一行做。
drill_recovery_howto() {
    local dir="$1" report="$2" text
    text="$(cat <<'EOF'
# 1) 数据库：把每份 archive 灌回一个空的 mongo
#    docker compose -f /root/erp-agent/docker-compose.yml up -d mongo
#    for f in @@DIR@@/*.archive.gz; do
#      docker compose -f /root/erp-agent/docker-compose.yml exec -T mongo sh -c '
#        H="$MONGODB_URI"; Q=""
#        case "$H" in *\?*) Q="?${H#*\?}"; H="${H%%\?*}" ;; esac
#        R="${H#*://}"
#        mongorestore --uri="${H%%://*}://${R%%/*}$Q" --archive --gzip --drop' < "$f"
#    done
#
#    为什么不是简单的一句 mongorestore：
#      a) 生产 mongo 开了认证。不带 --uri 的话它以「command insert requires
#         authentication」失败 —— 而恢复现场没有第二次机会试错。
#      b) MONGODB_URI 里带着库名，mongodump/mongorestore 会把 URI 里的库当成
#         「只处理这个库」的选择器。直接用 "$MONGODB_URI" 的话，checkpointing_db
#         那几份要么被灌进 erp_agent，要么什么都没做 —— 而且它不会报错。
#         上面三行赋值就是把库名摘掉、同时保住 authSource。
#         （2026-10-03：CI 首次真跑 backup-dr 时，mongodump 正是死在这个冲突上。
#           改一处必须改两处。）
#    规则与 deploy/dr/lib-dr.sh 的 DR_MONGO_URI_NODB_SH 相同，但**不是同一份
#    文本** —— 那边还多一层「URI 形状不对就原样交出去」的兜底，这里为了让人看得
#    懂省掉了。真改规则时两处都要动。
#
# 2) 卷：**先确认生产卷里确实没有要保下来的东西**，再解包
#    docker run --rm -v @@PROJECT@@_download-data:/d -v @@DIR@@:/b:ro @@IMAGE@@ \
#      tar -xzf /b/download-data.tar.gz -C /d
#
# 3) 起来了先跑 bash deploy/cd/status.sh，再看 @@REPORT@@
EOF
)"
    text="${text//@@DIR@@/$dir}"
    text="${text//@@REPORT@@/$report}"
    text="${text//@@PROJECT@@/${PROJECT:-erp-agent}}"
    text="${text//@@IMAGE@@/$(dr_mongo_image)}"
    printf '%s' "$text"
}

drill_write_report() {
    local dir="$1" result="$2" started="$3"
    local db_secs="$4" vol_secs="$5" total="$6" db_log="$7"
    local manifest="$dir/manifest.txt"
    local report="$dir/drill-report.txt"
    local dbs colls

    dbs="$(grep -c '^DB ' "$manifest" || true)"
    colls="$(grep -c '^COLL ' "$manifest" || true)"

    {
        printf '# erp-agent 恢复演练报告\n'
        printf '# 由 deploy/dr/restore-drill.sh 生成，给人看的，不参与任何判定。\n'
        printf 'RESULT %s\n'      "$result"
        printf 'AT %s\n'          "$started"
        printf 'HOST %s\n'        "$(hostname)"
        printf 'BACKUP %s\n'      "$dir"
        printf 'SECONDS_DB %s\n'  "$db_secs"
        printf 'SECONDS_VOLUME %s\n' "$vol_secs"
        printf 'SECONDS_TOTAL %s\n'  "$total"
        printf 'MANIFEST %s 个库 / %s 个集合\n' "$dbs" "$colls"
        printf '\n## 卷\n%s\n' "$DRILL_NOTES"
        printf '\n## 数据库恢复自检（backup.sh --verify 的原样输出）\n%s\n' "$db_log"
        printf '\n## 真正恢复时怎么做\n%s\n' "$(drill_recovery_howto "$dir" "$report")"
    } > "$report"
    printf '%s\n' "$report"
}

# ---------------------------------------------------------------- 主体
# 存 --verify 原样的输出，供报告与通知引用。**刻意是全局而不是 drill_main 的
# local**：清理它的 EXIT trap 在函数返回**之后**才跑，那时 local 已经出栈，
# `set -u` 下 `rm -f "$局部变量"` 会当场报 unbound —— 结果是临时文件留在盘上，
# 而那正是这个 trap 要防的事。offsite.sh 里凭据文件踩的是同一个坑。
DR_DRILL_LOG=""

drill_main() {
    local ARG="" DIR="" STARTED db_rc vol_rc DB_SECS VOL_SECS TOTAL RESULT REPORT BODY
    PROJECT="${PROJECT:-erp-agent}"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --list)
                [ -d "$CD_BACKUP_DIR" ] || { echo "（还没有任何备份：$CD_BACKUP_DIR）"; exit 0; }
                ls -1 "$CD_BACKUP_DIR" | sed 's/^/  /'
                exit 0
                ;;
            -h|--help) usage; exit 0 ;;
            -*)        warn "未知参数 '$1'"; usage; exit 2 ;;
            *)         ARG="$1"; shift ;;
        esac
    done

    [ -n "${CD_ENV:-}" ] || cd_load_env "${CD_ENV_NAME:-production}"

    if [ -n "$ARG" ]; then
        DIR="$ARG"
    else
        # 命名是 <UTC 时间戳>-<版本>，字典序就是时间序，取最后一个即最新。
        DIR="$(ls -1d "$CD_BACKUP_DIR"/*/ 2>/dev/null | sort | tail -1 || true)"
        DIR="${DIR%/}"
    fi
    [ -n "$DIR" ] && [ -d "$DIR" ] || {
        warn "找不到要演练的备份${ARG:+：$ARG}"
        warn "  先跑 bash deploy/dr/backup.sh --list 看有哪些"
        exit 2
    }
    [ -f "$DIR/manifest.txt" ] || { warn "$DIR 里没有 manifest.txt —— 它不是一份完整的备份"; exit 1; }

    # 演练与发布**不能同时跑**：两者都要起一个临时 mongo，而机器只有 2 核 3.6G。
    # 判据与定时备份、巡检共用同一个（cd_deploy_in_flight）—— 三处对「发布在跑吗」
    # 必须是同一句话，否则总有一个会在发布中途撞上来。
    if cd_deploy_in_flight; then
        warn "有一次发布正在进行 —— 演练推后（不与发布抢内存）"
        exit 1
    fi

    STARTED="$(date -Iseconds)"
    SECONDS=0
    log "演练 $DIR"

    # --- 数据库：整段交给 backup.sh --verify，输出同时留档给报告
    DR_DRILL_LOG="$(mktemp)"
    # shellcheck disable=SC2064
    trap 'rm -f "${DR_DRILL_LOG:-}"' EXIT
    db_rc=0
    bash "$DR_DIR/backup.sh" --verify "$DIR" > "$DR_DRILL_LOG" 2>&1 || db_rc=$?
    sed 's/^/    /' "$DR_DRILL_LOG" >&2 || true
    DB_SECS=$SECONDS
    [ "$db_rc" -eq 0 ] || warn "数据库恢复自检未通过（退出码 $db_rc）"

    # --- 卷
    vol_rc=0
    drill_volume "$DIR" || vol_rc=1
    VOL_SECS=$((SECONDS - DB_SECS))

    TOTAL=$SECONDS
    if [ "$db_rc" -eq 0 ] && [ "$vol_rc" -eq 0 ]; then
        RESULT=PASS
    else
        RESULT=FAIL
    fi

    REPORT="$(drill_write_report "$DIR" "$RESULT" "$STARTED" \
        "$DB_SECS" "$VOL_SECS" "$TOTAL" "$(cat "$DR_DRILL_LOG")")"
    log "报告：$REPORT"

    BODY="恢复演练 $RESULT
备份：$(basename "$DIR")
耗时：数据库 ${DB_SECS}s / 卷 ${VOL_SECS}s / 合计 ${TOTAL}s
$(grep -E '\[FAIL\]|自检|!!' "$DR_DRILL_LOG" | tail -8 || true)"
    cd_notify drill_report --text "$BODY"

    echo
    if [ "$RESULT" = PASS ]; then
        info "演练通过：这份备份可以恢复（$DIR）"
        exit 0
    fi
    warn "演练**未通过** —— 这份备份不能算备份。报告：$REPORT"
    exit 1
}

# BASH_SOURCE 守卫，与 patrol.sh / offsite.sh 同一个理由：这个文件被 source 进来
# 只应该拿到上面的函数。没有它，任何一次 `source restore-drill.sh` 都会当场跑一
# 次真正的演练 —— 起容器、解卷、写报告、发通知。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    drill_main "$@"
fi
