#!/usr/bin/env bash
# 备份链路的 PR 门禁。真起 mongo、真灌数据、真跑部署前的那条备份路径。
#
#   bash deploy/ci/backup-dr.sh
#
# 为什么这件事必须进 PR 门禁而不是"第一次发布时再验"：
# 备份链路是**唯一的**数据保险。它出问题的形态恰好是「看起来一切正常」——
# 少备份了一个库、自检其实什么都没比、剪枝把要用的那份删了。这三件事都不会
# 报错，只会在需要它的那一天才暴露。所以这里跑的是真东西，不是桩。
#
# **负向用例比正向用例重要**：一个永远说「通过」的自检和一个好自检在正向用例
# 上表现完全一样。所以下面先做一个正向对照（证明这套比对确实会通过），再逐个
# 篡改清单，要求自检**必须**失败。
#
# 只起 mongo 一个服务：备份链路的依赖只有它。其余服务（backend/frontend/nginx/
# dind）在这条链路上一个都不参与，起了只是白等几分钟。
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-ci.sh"

DR_SH="$CI_REPO_ROOT/deploy/dr/backup.sh"
WORK="${CI_BACKUP_WORK:-/tmp/erp-backup-dr}"
BACKUP_ROOT="$WORK/backups"
RETAIN_ROOT="$WORK/retain"
STATE_FILE="$CI_REPO_ROOT/deploy/cd/state/production.env"
STATE_CREATED=0
FAILED=0

on_exit() {
    local rc=$?
    if [ "$STATE_CREATED" = "1" ]; then
        rm -f "$STATE_FILE"
    fi
    if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then
        ci_dump "$WORK/diagnostics" || true
        ci_warn "产物留在 $WORK（托管 runner 上它会随 VM 一起消失）"
    fi
}
trap on_exit EXIT

fail() { ci_warn "$*"; FAILED=$((FAILED + 1)); }
ok()   { ci_info "ok  $*"; }

# ---------------------------------------------------------------- 容器内 mongosh
# 与 backup.sh 用同一条路径拿凭据：$MONGODB_URI 由容器自己的 shell 展开，
# 这个脚本不碰口令。
ci_mongo_js() {
    ci_compose exec -T mongo sh -c \
        'mongosh "$MONGODB_URI" --quiet --eval "$1"' -- "$1"
}

# 起栈时把 docker-compose.yml 与真实生产共用，所以 mongo 的
# healthcheck（mongosh ping）也会一并被验证。
ci_log "起 mongo（只起它，备份链路不需要别的服务）"
ci_compose up -d --no-build mongo
ci_wait_healthy 240 || ci_die "mongo 没在 240s 内 healthy"

if [ -e "$STATE_FILE" ]; then
    ci_die "$STATE_FILE 已存在 —— 这个脚本会临时占用它做剪枝测试，拒绝覆盖"
fi

# ---------------------------------------------------------------- 种子数据
# 两个库都要灌。checkpointing_db 是这次的核心：它不在任何配置里，一个"按配置
# 里的库名备份"的实现会把它整段丢掉且不报错 —— 下面第 2 步专门断言它在。
ci_log "灌种子数据（两个库）"
ci_mongo_js '
    const a = db.getSiblingDB("erp_agent");
    ["conversations","display_messages","langgraph_store","sandbox_cache"]
        .forEach(n => a.getCollection(n).drop());
    a.conversations.insertMany([{_id:"c1"},{_id:"c2"},{_id:"c3"}]);
    a.display_messages.insertMany([{_id:"m1"},{_id:"m2"},{_id:"m3"},{_id:"m4"},{_id:"m5"}]);
    a.langgraph_store.insertMany([{_id:"s1"},{_id:"s2"}]);
    a.sandbox_cache.insertMany([{_id:"k1"}]);

    const c = db.getSiblingDB("checkpointing_db");
    ["checkpoints","checkpoint_writes"].forEach(n => c.getCollection(n).drop());
    c.checkpoints.insertMany([{_id:"cp1"},{_id:"cp2"},{_id:"cp3"},{_id:"cp4"}]);
    c.checkpoint_writes.insertMany([{_id:"w1"},{_id:"w2"}]);
    print("seeded");
' | tail -1

# download-data 卷在只有 mongo 在跑时并不存在。手工造一个带内容的 ——
# 那一卷在真实环境里装的是用户生成的报告文件，Mongo 里没有它们的索引。
VOL="${CI_PROJECT}_download-data"
# 只建不删：这个脚本有可能被人手工在**真机**上跑一遍，而那一卷在真机上是
# 用户的报告文件。删掉它换来的"测试更干净"完全不值。
docker volume create "$VOL" >/dev/null
docker run --rm -v "$VOL":/d mongo:6.0 sh -c \
    'echo "report one" > /d/report-1.txt; mkdir -p /d/2026; echo "report two" > /d/2026/report-2.txt' \
    >/dev/null
ci_info "已造卷 $VOL（2 个文件）"

# ---------------------------------------------------------------- 真跑一次备份
rm -rf "$WORK"; mkdir -p "$BACKUP_ROOT"
ci_log "跑 deploy/dr/backup.sh（真 dump → 真 restore 自检）"
if ! CD_BACKUP_DIR="$BACKUP_ROOT" CD_BACKUP_NO_OFFSITE=1 \
        CD_BACKUP_VERSION=ci CD_BACKUP_GIT_SHA=0000000000000000000000000000000000000000 \
        bash "$DR_SH" > "$WORK/backup.log" 2>&1; then
    cat "$WORK/backup.log" >&2
    ci_die "备份脚本失败（日志见上）"
fi
tail -5 "$WORK/backup.log"

BK="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$BK" ] || ci_die "没找到备份目录"

# 1) 产物形状：两个库各一个 archive，加上清单、逐集合计数、卷。
ci_log "断言产物"
for want in erp_agent.archive.gz checkpointing_db.archive.gz manifest.txt counts.tsv; do
    if [ -f "$BK/$want" ]; then ok "$want 在"; else fail "缺 $BK/$want"; fi
done
[ -f "$BK/download-data.tar.gz" ] && ok "download-data.tar.gz 在" \
    || fail "卷没有被备份"

# 2) 这条直接锁住本次最大的发现：备份里的库集合必须等于「运行时枚举到的
#    用户库」，而不是「MONGODB_URI 里写的那个」。
mapfile -t DBS < <(sed -n 's/^DB \([^ ]*\) .*/\1/p' "$BK/manifest.txt")
if printf '%s\n' "${DBS[@]}" | grep -qx checkpointing_db; then
    ok "checkpointing_db 在备份里（这正是配置里看不到的那个库）"
else
    fail "备份里没有 checkpointing_db —— 会话状态会被整段丢掉"
fi
if printf '%s\n' "${DBS[@]}" | grep -qx erp_agent; then
    ok "erp_agent 在备份里"
else
    fail "备份里没有 erp_agent"
fi

# ---------------------------------------------------------------- 自检的判据
# 单独跑一次 --verify（发布路径用的是内置调用，这里验的是入口本身，
# 恢复演练与巡检都用它）。
ci_log "单独跑一次 --verify"
if CD_BACKUP_DIR="$BACKUP_ROOT" bash "$DR_SH" --verify "$BK" > "$WORK/verify.log" 2>&1; then
    ok "--verify 通过"
else
    cat "$WORK/verify.log" >&2
    fail "--verify 失败"
fi

# expect_verify_fail <描述> <篡改函数>
expect_verify() {
    local desc="$1" expect="$2" mutate="$3" d
    d="$WORK/case-$RANDOM$RANDOM"
    cp -r "$BK" "$d"
    # 过一层 bash -c：篡改命令里有引号与 $，直接当命令名执行是跑不起来的。
    bash -c "$mutate" _ "$d/manifest.txt"
    local rc=0
    CD_BACKUP_DIR="$BACKUP_ROOT" bash "$DR_SH" --verify "$d" > "$WORK/case.log" 2>&1 || rc=$?
    if [ "$expect" = "fail" ]; then
        if [ "$rc" -eq 0 ]; then
            fail "负向用例未生效：$desc —— 自检本该失败却通过了"
        else
            ok "负向用例生效：$desc"
        fi
    else
        if [ "$rc" -eq 0 ]; then
            ok "正向对照通过：$desc"
        else
            sed -n '1,20p' "$WORK/case.log" >&2
            fail "正向对照失败：$desc —— 干净的备份不该被自检判为坏"
        fi
    fi
    rm -rf "$d"
}

# 先立对照。没有这一条，下面四个负向用例在一个「永远返回失败」的自检上
# 会全部"通过" —— 那样整套用例其实什么都没证明。
ci_log "自检的负向用例（先立一个正向对照）"
expect_verify "干净副本" ok true

# 漏库：把 checkpointing_db 那一行从清单里删掉。恢复出来的库集合就与清单不符。
expect_verify "清单里删掉一个库" fail \
    'sed -i "/^DB checkpointing_db /d" "$1"'

# 条数对不上：把 conversations 的期望区间压到 0..0，恢复出来的 3 条落在区间外。
expect_verify "把某个集合的期望条数改小" fail \
    'sed -i "s/^COLL erp_agent conversations .*/COLL erp_agent conversations 0 0/" "$1"'

# 恢复库里多出一个清单没记的东西：加一条不存在的集合，期望 5 条，实际 0 条。
expect_verify "清单里多出一个不存在的集合" fail \
    'echo "COLL erp_agent no_such_collection 5 5" >> "$1"'

# 文件完整性：archive 本身没坏，但清单记的 sha256 与它对不上 —— 这是截断、
# 断电半截写、磁盘坏块的等价物，而它们都可能让 mongorestore「成功但少恢复了一
# 部分」，那是最难事后发现的一类损坏。
expect_verify "清单里的 archive sha256 被改" fail \
    'sed -i "0,/^DB /s/ [0-9a-f]\{64\} / 0000000000000000000000000000000000000000000000000000000000000000 /" "$1"'

# ---------------------------------------------------------------- 保留策略
# 9 份、保留 7 份，且把**最旧**那份写进状态文件 —— 如果保护逻辑不存在，它
# 会被第一个删掉；存在的话它必须活下来（此时目录数会是 8 而不是 7）。
ci_log "保留策略（9 份，保留 7，最旧那份受状态文件保护）"
rm -rf "$RETAIN_ROOT"; mkdir -p "$RETAIN_ROOT" "$(dirname "$STATE_FILE")"
for n in 1 2 3 4 5 6 7 8 9; do
    mkdir -p "$RETAIN_ROOT/2026010${n}T000000Z-v9.9.${n}"
done
printf 'DB_DUMP=%s\n' "$RETAIN_ROOT/20260101T000000Z-v9.9.1" > "$STATE_FILE"
STATE_CREATED=1

CD_BACKUP_DIR="$RETAIN_ROOT" CD_BACKUP_KEEP=7 bash "$DR_SH" --prune > "$WORK/prune.log" 2>&1 \
    || fail "剪枝失败（见 $WORK/prune.log）"

left="$(find "$RETAIN_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)"
if [ "$left" -eq 8 ]; then
    ok "剩下 8 份（最近 7 份 + 状态文件引用的那份）"
else
    fail "剪枝后剩 $left 份，期望 8。留存：$(ls -1 "$RETAIN_ROOT" | tr '\n' ' ')"
fi
[ -d "$RETAIN_ROOT/20260101T000000Z-v9.9.1" ] \
    && ok "受保护的那份还在" \
    || fail "受保护的那份被删了 —— 回滚就没得可回了"
[ -d "$RETAIN_ROOT/20260102T000000Z-v9.9.2" ] \
    && fail "该被剪掉的 20260102 还在（保留策略没生效）" \
    || ok "超出保留份数的旧备份被剪掉"

# ---------------------------------------------------------------- 收尾
rm -f "$STATE_FILE"; STATE_CREATED=0

if [ "$FAILED" -ne 0 ]; then
    ci_die "backup-dr：$FAILED 项断言失败"
fi
ci_log "backup-dr 全部通过"
