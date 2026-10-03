#!/usr/bin/env bash
# 迁移链路的 PR 门禁。真起 mongo、真跑 deploy/dr/migrate.sh、真查库里的索引。
#
#   bash deploy/ci/migrate-e2e.sh
#
# 为什么迁移也要进门禁：迁移是唯一一个**直接改生产数据库结构**的自动步骤，而它
# 出错的形态比备份更隐蔽 —— 备份少一个库时至少文件还是好的，迁移写错时的结果是
# 数据库处于一个"没人设计过"的形状，而且是在发布路径上、在旧代码还在服务的
# 那几分钟里。这里不验语法（那个 mongosh 会告诉你），验的是：
#   - 记账真的写进去了（而不是"跑完了"就算数）
#   - 重跑是幂等的、不会重复应用
#   - 一个已经应用过的迁移被人改了内容 → 必须停住，且**一个迁移都不执行**
#   - 编号撞车 → 必须在执行之前就停住
#
# 与 backup-dr.sh 同一个 job 里跑，共用它已经起好的 mongo（CI 的 step 之间
# 容器是活着的）。所以要放在 backup-dr 那步**之后**。
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-ci.sh"

MIGRATE_SH="$CI_REPO_ROOT/deploy/dr/migrate.sh"
MIGRATIONS_DIR="$CI_REPO_ROOT/migrations"
WORK="${CI_MIGRATE_WORK:-/tmp/erp-migrate-e2e}"
FAILED=0

on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then
        ci_dump "$WORK/diagnostics" || true
        ci_warn "产物留在 $WORK"
    fi
}
trap on_exit EXIT

fail() { ci_warn "$*"; FAILED=$((FAILED + 1)); }
ok()   { ci_info "ok  $*"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else fail "$3（期望 '$2'，得到 '$1'）"; fi; }

mkdir -p "$WORK"

# 与 deploy/dr/ 同一条路径拿凭据：$MONGODB_URI 由容器自己的 shell 展开，
# 这个脚本从头到尾不碰口令。
ci_mongo_js() {
    ci_compose exec -T mongo sh -c \
        'mongosh "$MONGODB_URI" --quiet --eval "$1"' -- "$1"
}

# 账本行数。迁移器写完账之后这里必须涨，且只能涨它该涨的那么多。
ledger_rows() {
    ci_mongo_js 'print(db.getSiblingDB(process.env.MONGODB_DB_NAME)
        .getCollection("schema_version").countDocuments({}));' | tr -d '\r' | tail -1
}

# langgraph_store 上的索引名，排序后逗号连接。
store_indexes() {
    ci_mongo_js 'print(db.getSiblingDB(process.env.MONGODB_DB_NAME)
        .getCollection("langgraph_store").getIndexes()
        .map(i => i.name).sort().join(","));' | tr -d '\r' | tail -1
}

# $1=描述  $2=日志里必须出现的串  $3..=命令
expect_fail() {
    local desc="$1" needle="$2"; shift 2
    local log="$WORK/fail.log"
    if "$@" > "$log" 2>&1; then
        fail "$desc —— 本该失败却成功了（见 $log）"
        return 1
    fi
    if grep -qF -- "$needle" "$log"; then
        ok "$desc → 失败，且给出了原因"
    else
        # 退出码对了但原因不对，在大方向上仍然是坏的：这类断言的价值就在于
        # 「失败得对」，只判非零的话，一个语法错误也能让用例变绿。
        fail "$desc → 失败了，但日志里没有 '$needle'（见 $log）"
    fi
}

ci_log "确认 mongo 在跑（backup-dr 那步应该已经起过了）"
ci_wait_healthy 120 || ci_die "mongo 没起来"

# 起点必须是干净的：这个脚本断言的是"从 0 到 1"和"从 1 到 1"，不是"从 N 到 N+1"。
# 托管 runner 上每次都是新 VM，所以这里红就等于有人改了 job 的顺序 —— 那正是
# 我们想知道的（放错位置的迁移测试会变得毫无意义）。
before="$(ledger_rows)"
check "$before" "0" "起点：账本为空"

# 前置条件：langgraph_store 里已有的文档得能撑起一个 (namespace,key) 唯一索引 ——
# 0001_baseline 要建的正是它。这个集合的内容是**上一个脚本**（backup-dr.sh，同一个
# job、同一个 mongo）灌的，所以这里实际是在断言那个种子的形状。
#
# 为什么值得单独判一次：种子形状不对时，症状是建索引报
#   E11000 duplicate key error ... dup key: { namespace: null, key: null }
# 那个报错长得像「迁移写错了」或者「库里有脏数据」，而真正的原因在另一个文件的
# 几行 JS 里。2026-10-03 这套断言第一次真跑时就撞上了这个：9 项失败里有 8 项是它
# 的下游。把它拆成一条具名断言，下次红的时候第一行就指对了地方。
dups="$(ci_mongo_js '
    const c = db.getSiblingDB(process.env.MONGODB_DB_NAME).getCollection("langgraph_store");
    const r = c.aggregate([
        {$group: {_id: {n: "$namespace", k: "$key"}, c: {$sum: 1}}},
        {$match: {c: {$gt: 1}}},
        {$count: "dups"}
    ]).toArray();
    print(r.length ? r[0].dups : 0);' | tr -d '\r' | tail -1)"
check "$dups" "0" "前置：langgraph_store 里没有重复的 (namespace,key)"

# ---------------------------------------------------------------- status / dry-run 不写库
ci_log "--status 与 --dry-run：只报告，不碰数据库"
bash "$MIGRATE_SH" --dir "$MIGRATIONS_DIR" --status > "$WORK/status.log" 2>&1 \
    || fail "status 失败（见 $WORK/status.log）"
grep -q '0001' "$WORK/status.log" && ok "status 列出了 0001" \
    || fail "status 没列出待应用的 0001：$(tr '\n' ' ' < "$WORK/status.log")"

bash "$MIGRATE_SH" --dir "$MIGRATIONS_DIR" --dry-run > "$WORK/dry.log" 2>&1 \
    || fail "dry-run 失败（见 $WORK/dry.log）"
check "$(ledger_rows)" "0" "dry-run 之后账本仍然是空的"

# ---------------------------------------------------------------- 真跑
ci_log "真的执行一次"
bash "$MIGRATE_SH" --dir "$MIGRATIONS_DIR" > "$WORK/run1.log" 2>&1 || {
    fail "迁移执行失败（见 $WORK/run1.log）"
    cat "$WORK/run1.log" >&2
}

check "$(ledger_rows)" "1" "账本里多了一行"

# 这一条才是「迁移真的做了它说的事」的证据。只断言账本的话，一个什么都不做、
# 只管记账的迁移器也能全绿 —— 而那正是最坏的一种"通过"。
check "$(store_indexes)" "_id_,namespace_1_key_1,updated_at_1" \
      "langgraph_store 上的两个索引真的建出来了"

# ---------------------------------------------------------------- 幂等
ci_log "再跑一次：应该什么都不做"
bash "$MIGRATE_SH" --dir "$MIGRATIONS_DIR" > "$WORK/run2.log" 2>&1 \
    || fail "第二次执行失败（见 $WORK/run2.log）"
check "$(ledger_rows)" "1" "重跑没有重复记账"
grep -q '已是最新' "$WORK/run2.log" && ok "重跑报告的是「已是最新」" \
    || fail "重跑没有报告已是最新：$(tr '\n' ' ' < "$WORK/run2.log")"

# ---------------------------------------------------------------- 负向：历史被改
# 已经应用过的迁移文件，内容一变，说明"数据库现在的形状"和"文件现在说的"对不上。
# 这时**必须一个迁移都不执行** —— 停在一个已知状态，好过一个半新半旧的库。
ci_log "负向：已应用迁移的内容被改"
cp -r "$MIGRATIONS_DIR" "$WORK/bad-content"
printf '\n// 有人回头改了已应用的迁移\n' >> "$WORK/bad-content/0001_baseline.js"
expect_fail "改掉已应用迁移的内容" "已经应用过，但文件内容变了" \
    bash "$MIGRATE_SH" --dir "$WORK/bad-content" || true
check "$(ledger_rows)" "1" "被拒之后账本没变"

# ---------------------------------------------------------------- 负向：编号撞车
# 0001_a.js 与 0001_b.js 会撞成同一个编号，而账本的主键就是编号 —— 第二个会写
# 不进去，而那时它已经跑过了。所以必须在执行之前停住。
ci_log "负向：两个文件抢同一个编号"
cp -r "$MIGRATIONS_DIR" "$WORK/bad-dup"
: > "$WORK/bad-dup/0001_another.js"
expect_fail "编号撞车" "重复编号" \
    bash "$MIGRATE_SH" --dir "$WORK/bad-dup" || true
check "$(ledger_rows)" "1" "被拒之后账本没变"

if [ "$FAILED" -ne 0 ]; then
    ci_die "migrate-e2e：$FAILED 项断言失败"
fi
ci_log "migrate-e2e 全部通过"
