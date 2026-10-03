#!/usr/bin/env bash
# deploy/monitor/patrol.sh 与 lib.sh 里 cd_deploy_in_flight 的**纯逻辑**桩测。
#
#   bash deploy/ci/patrol-logic-test.sh
#
# 为什么这几段值得单独测：它们是「状态变迁才告警」这个机制的全部实现，而它们的
# 失效方式**全都是静默的**——
#   指纹把细节也算进去  → 每次发布都发一条假告警 → 几天后所有人把它静音
#   指纹过于粗糙        → 真出的事被当成「没变化」→ 一条都不发
#   跳过判据反了        → 发布期间刷屏，或者卡住的 pending 永远不报
# 三种都不会报错。前两种在真机上要等好几天才看得出来，第三种要等下一次发布。
#
# 不需要 Docker、不需要 mongo、不需要 status.sh 真的能跑 —— 这里喂的是**构造出来
# 的 status.sh 输出文本**，那正是这些函数的输入类型。
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CI_DIR/../.." && pwd)"
PATROL="$REPO_ROOT/deploy/monitor/patrol.sh"

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

# patrol.sh 有 BASH_SOURCE 守卫，直接 source 就不会把本进程当成一次真巡检
#（否则它会发通知、写 /var/lib/erp-agent/patrol.last）。
# shellcheck disable=SC1090
source "$PATROL"
source "$REPO_ROOT/deploy/cd/lib.sh"
# patrol.sh 带进来的是 set -uo pipefail（没有 -e），但 lib.sh 是给 set -e 的调用方
# 写的；这里被观察的对象正是「函数返回非零」，显式关掉 -e 与 pipefail。
set +e +o pipefail

__section "被测函数都在（装配方式变了的话这里先红）"
for fn in p_strip_ansi p_fingerprint p_diff_summary; do
    if [ "$(type -t "$fn")" = "function" ]; then ok "$fn"; else bad "$fn 没被 source 进来"; fi
done
if [ "$(type -t cd_deploy_in_flight)" = "function" ]; then ok cd_deploy_in_flight
else bad "cd_deploy_in_flight 没被 source 进来"; fi
[ "$FAIL" -eq 0 ] || { printf '\n装配失败，后面的用例没有意义\n' >&2; exit 1; }

# ---------------------------------------------------------------- ANSI
__section "p_strip_ansi：颜色码不能进指纹"
# 这几条是 status.sh 真正会打出来的形状（见它的 ok()/bad()/head_()）。
raw="$(printf '\033[32m[OK]\033[0m   disk: 可用 30G\n\033[1m== 备份 ==\033[0m\n')"
check "$(printf '%s' "$raw" | p_strip_ansi)" "[OK]   disk: 可用 30G
== 备份 ==" "颜色码被剥掉，正文一字不改"

# ---------------------------------------------------------------- 指纹
__section "p_fingerprint：只认 [OK]/[FAIL] 那一行，且只取 id"
FAKE_STATUS='\033[32m[OK]\033[0m   docker: daemon 可达
\033[32m[OK]\033[0m   service-mongo: healthy（mongo:6.0）
\033[31m[FAIL]\033[0m service-nginx: state=exited health=none（erp-agent-frontend:sha-1a2b3c4d5e6f）
\033[32m[OK]\033[0m   pending: 没有 pending 残留
\033[31m[FAIL]\033[0m disk: docker 分区可用 3G < 8G
'
fp="$(printf "$FAKE_STATUS" | p_strip_ansi | p_fingerprint)"
check "$fp" "disk|FAIL
docker|OK
pending|OK
service-mongo|OK
service-nginx|FAIL" "id 与 OK/FAIL 对，按 id 排序，细节一律丢弃"

# 这条是整个机制的核心不变式：**同一状态、两次不同的细节，指纹必须相同**。
# 镜像名、digest、版本号、剩余空间全都随发布变，它们要是进了指纹，每次发布都会
# 发一条「状态变了」——而那是假的。
V1='\033[32m[OK]\033[0m   service-mcp: healthy（erp-agent-app:sha-aaaaaaaaaaaa）
\033[32m[OK]\033[0m   disk: docker 分区可用 31G（门槛 8G）
\033[32m[OK]\033[0m   state-file: VERSION=v1.0.0 GIT_SHA=aaa DEPLOYED_AT=2026-10-01T00:00:00+08:00
'
V2='\033[32m[OK]\033[0m   service-mcp: healthy（erp-agent-app:sha-bbbbbbbbbbbb）
\033[32m[OK]\033[0m   disk: docker 分区可用 12G（门槛 8G）
\033[32m[OK]\033[0m   state-file: VERSION=v1.1.0 GIT_SHA=bbb DEPLOYED_AT=2026-10-03T12:00:00+08:00
'
check "$(printf "$V2" | p_strip_ansi | p_fingerprint | sha256sum)" \
      "$(printf "$V1" | p_strip_ansi | p_fingerprint | sha256sum)" \
      "发布造成的细节变化（镜像/digest/版本/空间）不改变指纹"

# 反过来：状态真变了必须**改变**指纹，否则告警永远不会响。
V3='\033[31m[FAIL]\033[0m service-mcp: state=restarting health=none（erp-agent-app:sha-bbbbbbbbbbbb）
\033[32m[OK]\033[0m   disk: docker 分区可用 12G（门槛 8G）
\033[32m[OK]\033[0m   state-file: VERSION=v1.1.0 GIT_SHA=bbb DEPLOYED_AT=2026-10-03T12:00:00+08:00
'
if [ "$(printf "$V3" | p_strip_ansi | p_fingerprint)" = "$(printf "$V2" | p_strip_ansi | p_fingerprint)" ]; then
    bad "一个服务从 OK 变成 FAIL，指纹却没变 —— 告警永远不会响"
else
    ok "OK → FAIL 会改变指纹"
fi

# detail 里的第一个冒号之后全都是细节，不能再切第二次（否则 id 会被截断）。
check "$(printf '\033[31m[FAIL]\033[0m offsite: 已推送到 oss://b/p（3 个对象）: 后半个\n' \
    | p_strip_ansi | p_fingerprint)" "offsite|FAIL" "id 只取到第一个冒号为止"

# 不是我们写的那些行（分隔线、空行、其它格式）不能被当成检查项。
check "$(printf '\n== 服务 ==\n   \033[32m[OK]\033[0m x\nnot a check line\n  == 磁盘 ==  \n' \
    | p_strip_ansi | p_fingerprint)" "" \
      "非 [OK]/[FAIL] 行一律不收（否则会得到一条每次都变的指纹）"

# 同一 id 出现两次（status.sh 将来把某个检查拆成多行）只算一次，避免「两次之间
# 行数变了」被误判成状态变迁。
check "$(printf '\033[32m[OK]\033[0m disk: a\n\033[32m[OK]\033[0m disk: b\n' \
    | p_strip_ansi | p_fingerprint)" "disk|OK" "同一 id 的重复行去重"

# id 形状不对的（含空格/大写/中文）跳过而不是收进来 —— 收进来就等于把一句散文
# 变成指纹的一部分。
check "$(printf '\033[31m[FAIL]\033[0m Foo Bar: x\n\033[31m[FAIL]\033[0m 服务: y\n' \
    | p_strip_ansi | p_fingerprint)" "" "形状不对的 id 被跳过"

# ---------------------------------------------------------------- 差异摘要
__section "p_diff_summary：只报**新坏**和**恢复**"
prev='a|OK
b|FAIL
c|OK'
now='a|FAIL
b|OK
c|OK'
d="$(p_diff_summary "$prev" "$now")"
case "$d" in
    *"新出现问题：a"*) ok "新坏的被点名（a）" ;;
    *) bad "新坏的没被点名：$d" ;;
esac
case "$d" in
    *"已恢复：b"*) ok "恢复的被点名（b）" ;;
    *) bad "恢复的没被点名：$d" ;;
esac
case "$d" in
    *"c"*) bad "没变的 c 被算进了差异：$d" ;;
    *) ok "没变的不出现在差异里" ;;
esac

check "$(p_diff_summary "$prev" "$prev")" "" "状态完全没变时摘要为空"

# ---------------------------------------------------------------- 发布进行中？
__section "cd_deploy_in_flight：年轻 = 在跑，老 = 卡住"
cd_load_env production
D2="$(__mk)"
export CD_PENDING_FILE="$D2/production.pending.env"

printf 'VERSION=v1\n' > "$CD_PENDING_FILE"
if cd_deploy_in_flight; then ok "刚写的 pending → 视为发布在进行"; else bad "刚写的 pending 没被认成发布中"; fi

# 这个边界是整段代码里最要紧的一处判断：**卡住的 pending 必须被当成故障报出来**，
# 而不是永远躲开。躲开的表现是「有一次发布烂在半路，从此巡检再也不提它」。
touch -d '3 hours ago' "$CD_PENDING_FILE"
if cd_deploy_in_flight; then bad "3 小时前的 pending 仍被当成发布中（卡住的那次永远不报）"
else ok "3 小时前的 pending → 不再算发布中（交给巡检报出来）"; fi

rm -f "$CD_PENDING_FILE"
if cd_deploy_in_flight; then bad "没有 pending 文件却说是发布中"; else ok "没有 pending → 不在发布中"; fi

printf '\n==== 通过 %d，失败 %d ====\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
