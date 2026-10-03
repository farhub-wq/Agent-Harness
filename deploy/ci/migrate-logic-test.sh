#!/usr/bin/env bash
# deploy/dr/migrate.sh 里**不依赖 Docker** 那几段的桩测。
#
#   bash deploy/ci/migrate-logic-test.sh
#
# 为什么单独一个文件（与 dr-logic-test.sh 并存，不是合进去）：
# 那两个脚本 source 的对象不同、断言的东西也不同。合在一起会让「装配失败」
# 这一条断言分不清是 backup.sh 没装好还是 migrate.sh 没装好 —— 而装配失败时
# 后面的用例全部没有意义，第一件要知道的就是谁没装上。
#
# 端到端的部分在 deploy/ci/migrate-e2e.sh（真起 mongo、真查索引）。这里管的是
# 那几个纯函数：编号排序、账本比对、重复编号、账本里孤儿条目。它们的输入是两个
# 字符串，输出是一行行文本 —— 用真 mongo 反而构造不出这些边界。
set -uo pipefail

CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CI_LIB_DIR/../.." && pwd)"
MIGRATE="$REPO_ROOT/deploy/dr/migrate.sh"

PASS=0; FAIL=0
ok()   { printf '    ok  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '\033[33m !! %s\033[0m\n' "$*" >&2; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3（期望 '$2'，得到 '$1'）"; fi; }
__section() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

__tmp=()
__mk() { local d; d="$(mktemp -d)"; __tmp+=("$d"); printf '%s' "$d"; }
cleanup() {
    local d
    for d in ${__tmp[@]+"${__tmp[@]}"}; do
        case "$d" in /tmp/*|"${TMPDIR:-/tmp}"/*) rm -rf "$d" ;; esac
    done
}
trap cleanup EXIT

# migrate.sh 有 BASH_SOURCE 守卫，直接 source 就行 —— 它不会把测试进程当成一次
# 真迁移跑起来。不需要 dr-logic-test.sh 里那种 sed 预处理。
#
# 但**绝不能**调 dr_run_migrate：它在函数里装 EXIT trap（清理临时目录），会把
# 本文件的 cleanup 换掉。纯函数一个都不装 trap。
# shellcheck disable=SC1090
source "$MIGRATE"
# migrate.sh 头部有 set -euo pipefail，source 会把它带进本 shell。这里「函数返回
# 非零」正是被观察的对象，必须关掉 -e；-u 留着。
set +e +o pipefail

__section "被测函数都在（装配方式变了的话这里先红）"
for fn in dr_list_migrations dr_plan dr_check_orphans; do
    if [ "$(type -t "$fn")" = "function" ]; then ok "$fn"; else bad "$fn 没被 source 进来"; fi
done
[ "$FAIL" -eq 0 ] || { printf '\n装配失败，后面的用例没有意义\n' >&2; exit 1; }

# ---------------------------------------------------------------- 目录扫描
__section "dr_list_migrations：编号排序、只认 NNNN_*.js"
D="$(__mk)"
printf 'a\n' > "$D/0002_second.js"
printf 'b\n' > "$D/0001_first.js"
printf 'c\n' > "$D/0010_tenth.js"
# 这些都不该被当成迁移：编号位数不对、只是 .md、没有下划线。
printf 'x\n' > "$D/1_short.js"
printf 'x\n' > "$D/0003_note.md"
printf 'x\n' > "$D/0004nojunk.js"

list="$(dr_list_migrations "$D")"
check "$(printf '%s\n' "$list" | cut -f1 | tr '\n' ' ')" "0001 0002 0010 " \
      "只收 NNNN_*.js，且按编号升序（不是字典序、不是文件系统序）"

check "$(printf '%s\n' "$list" | awk -F'\t' 'NR==1{print length($2)}')" "64" \
      "每行带 64 位 sha256"

# 目录里一个迁移都没有时必须是**空输出 + 成功**：发布时"这次没有迁移"是最常见的
# 情况，它不该被当成错误。
EMPTY="$(__mk)"
check "$(dr_list_migrations "$EMPTY")" "" "空目录 → 空输出（glob 不展开时也不能吐出一个字面量路径）"

# ---------------------------------------------------------------- 账本比对
__section "dr_plan：待执行 / 已应用 / 历史被改"
L="$(dr_list_migrations "$D")"
D1="$(printf '%s\n' "$L" | awk -F'\t' '$1=="0001"{print $2}')"
D2="$(printf '%s\n' "$L" | awk -F'\t' '$1=="0002"{print $2}')"
D10="$(printf '%s\n' "$L" | awk -F'\t' '$1=="0010"{print $2}')"

# 账本为空 → 三条全待执行。
check "$(dr_plan "$L" "" | cut -f2 | tr '\n' ' ')" "0001 0002 0010 " \
      "空账本 → 全部待执行"

# 0001 应用过且哈希一致 → 只跳过它。
applied="$(printf '0001\t%s\t2026-10-03T00:00:00Z\n' "$D1")"
check "$(dr_plan "$L" "$applied" | cut -f2 | tr '\n' ' ')" "0002 0010 " \
      "已应用的 0001 被跳过，其余照常"
# APPLY 行的字段顺序是 APPLY / 编号 / sha256 / 路径 —— 记账要写的就是这个 sha256，
# 写错位的话账本从第一行起就是错的，而它只在下次发布时才会被发现。
check "$(dr_plan "$L" "$applied" | cut -f3 | tr '\n' ' ')" "$D2 $D10 " \
      "待执行项带的是自己文件的 sha256（字段没有错位）"

# 已应用但内容变了 → 必须**非零退出**。这是硬失败：数据库现在的形状是按旧内容
# 来的，账本说它是新的，之后所有判断都建在一个错的前提上。
dr_plan "$L" "$(printf '0001\tdeadbeef\t2026-10-03T00:00:00Z\n')" >/dev/null 2>&1
check "$?" "1" "已应用迁移的哈希对不上 → 返回非零（不执行任何迁移）"

dr_plan "$L" "$applied" >/dev/null 2>&1
check "$?" "0" "正向对照：哈希都对得上时返回 0"

# 编号撞车：0001_a.js 与 0001_b.js 会撞成同一个编号，而账本主键是编号 ——
# 第二个写不进去，而那时它已经跑过了。必须在执行之前停住。
DUP="$(__mk)"
printf 'a\n' > "$DUP/0001_a.js"
printf 'b\n' > "$DUP/0001_b.js"
dr_plan "$(dr_list_migrations "$DUP")" "" >/dev/null 2>&1
check "$?" "1" "两个文件抢同一个编号 → 返回非零"

# ---------------------------------------------------------------- 孤儿
__section "dr_check_orphans：账本里有、文件没了"
# 只告警不失败：丢的是记录不是正确性，为记账问题卡住生产发布不划算。
out="$(dr_check_orphans "$L" "$(printf '0001\tx\t\n0099\tx\t\n')" 2>&1)"
check "$?" "0" "孤儿条目不返回失败"
case "$out" in
    *0099*) ok "孤儿条目被点名了（0099）" ;;
    *)      bad "孤儿条目没被点出来：$out" ;;
esac
case "$out" in
    *0001*) bad "存在的 0001 被误报成孤儿" ;;
    *)      ok "存在的条目不误报" ;;
esac

printf '\n==== 通过 %d，失败 %d ====\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
