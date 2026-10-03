#!/usr/bin/env bash
# deploy/dr/backup.sh 里**不依赖真 Docker** 那几段的桩测。
#
#   bash deploy/ci/dr-logic-test.sh
#
# 为什么要有这一个而在 backup-dr.sh 之外单独存在：
# backup-dr.sh 跑的是端到端真链路，但它只能覆盖「正常输入」那一条路 —— 那些
# 输入是它自己造出来的。而 backup.sh 里真正容易错的是**解析与比较**：清单字段
# 有没有错位、区间比较的边界、剪枝的保护集。这些用真 mongo 反而不容易构造。
#
# 它不是补充，是抓到过真问题的：`local dir="$1" manifest="$dir/x"` 这种写法在
# bash 里是先展开后赋值，set -u 下 `--verify` 这个入口会当场 unbound 退出 ——
# 而 --verify 正是恢复演练和巡检要调的入口。端到端用例碰不到它（那条路走的是
# 函数内部已经赋好值的变量）。
set -uo pipefail

CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CI_LIB_DIR/../.." && pwd)"
DR="$REPO_ROOT/deploy/dr/backup.sh"

PASS=0; FAIL=0
ok()   { printf '    ok  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '\033[33m !! %s\033[0m\n' "$*" >&2; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3（期望 '$2'，得到 '$1'）"; fi; }
__section() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# 临时目录一律自己收。只删 mktemp 交出来的那些路径 —— 断言失败时脚本会中途
# 退出，没有 trap 就会在一次性 runner 上留一堆垃圾（本地则是留一堆垃圾在 /tmp）。
__tmp=()
__mk() { local d; d="$(mktemp -d)"; __tmp+=("$d"); printf '%s' "$d"; }
cleanup() {
    local d
    for d in ${__tmp[@]+"${__tmp[@]}"}; do
        case "$d" in /tmp/*|"${TMPDIR:-/tmp}"/*) rm -rf "$d" ;; esac
    done
}
trap cleanup EXIT

# 只喂「入口」之前的部分（函数定义 + 常量默认值），文件一行不改。
# 两处 sed 的原因：
#   - 入口那段会把 `bash dr-logic-test.sh` 当成一次真备份跑起来；
#   - DR_DIR 那行在进程替换下会算错（BASH_SOURCE[0] 是 /dev/fd/63）。
DR_DIR="$REPO_ROOT/deploy/dr"
# shellcheck disable=SC1090
source <(sed -e '/^# .*入口/,$d' -e '/^DR_DIR=/d' "$DR")
# backup.sh 头部有 set -euo pipefail，source 会把它带进本 shell。这里「命令失败」
# 正是被观察的对象，必须关掉 -e；-u 留着（它就是抓上面那个 bug 的东西）。
set +e +o pipefail

__section "被测函数都在（装配方式变了的话这里先红）"
for fn in dr_compare dr_prune dr_merge_counts dr_valid_name dr_write_manifest \
          dr_wrap_js dr_mongo_eval_checked; do
    if [ "$(type -t "$fn")" = "function" ]; then ok "$fn"; else bad "$fn 没被 source 进来"; fi
done
[ "$FAIL" -eq 0 ] || { printf '\n装配失败，后面的用例没有意义\n' >&2; exit 1; }

# ---------------------------------------------------------------- 连接串摘库名
__section "dr_uri_nodb：mongodump 不许 URI 与 --db 同时给库名"
# 这一节存在的理由就是它抓到过的那个 bug：MONGODB_URI 里带 `.../erp_agent`，
# 备份又逐库传 `--db`，于是 mongodump 报
#   Invalid Options: Cannot specify different database in connection URI and
#   command-line option
# 并在**第一个非 URI 库**上退出 —— 也就是备份从来没成功过。CI 首次真跑
# backup-dr 时抓到（2026-10-03），本机没有 Docker daemon 是看不见它的。
#
# 被测的 dr_uri_nodb 活在**容器里**（见 lib-dr.sh 的 DR_MONGO_URI_NODB_SH），所以
# 这里用 `sh` 起一个独立进程来喂它，而不是在宿主机 shell 里 source —— 后者测的
# 是另一个解释器里的另一份代码。mongo:6.0 的 /bin/sh 是 dash，CI 上 sh 也是
# dash，所以这一跑同时把「这个片段是不是真 POSIX」验掉了。
#
# **这一节第一版是全绿的，而线上照样炸** —— 断言里的「期望值」是我照自己的理解
# 手写的，写错的就是它：摘掉库名之后那个 `/` 不能一起摘掉，MongoDB 的语法要求
# 查询串前面有 `/`（`must have a / before the query ?`）。教训不是「多写用例」，
# 而是**桩测验证不了规格本身** —— 规格只能由真解析器来判，所以最终的判据是
# deploy/ci/backup-dr.sh 那一跑。
uri_nodb() { MONGODB_URI="$1" sh -c "$DR_MONGO_URI_NODB_SH"'
dr_uri_nodb'; }

check "$(uri_nodb 'mongodb://root:pw@mongo:27017/erp_agent?authSource=admin')" \
      'mongodb://root:pw@mongo:27017/?authSource=admin' \
      "带库名与查询串 → 库名摘掉、那个 / 留下、authSource 保留"
check "$(uri_nodb 'mongodb://root:pw@mongo:27017/erp_agent')" \
      'mongodb://root:pw@mongo:27017/' "只有库名（拼读时最容易漏掉的一格）"
check "$(uri_nodb 'mongodb://mongo:27017')" 'mongodb://mongo:27017/' \
      "本来没有库名 → 只补斜杠，不能把 host 切掉"
check "$(uri_nodb 'mongodb://mongo:27017/')" 'mongodb://mongo:27017/' "尾部已经是空库名"
check "$(uri_nodb 'mongodb+srv://u:p@c.example.net/erp_agent?retryWrites=true')" \
      'mongodb+srv://u:p@c.example.net/?retryWrites=true' "srv 形式：加号不能被协议名切分吃掉"
check "$(uri_nodb 'mongodb://h1:27017,h2:27017/erp_agent?replicaSet=rs0')" \
      'mongodb://h1:27017,h2:27017/?replicaSet=rs0' "多主机列表"
check "$(uri_nodb 'mongo:27017')" 'mongo:27017' "不是 URI 形状 → 原样，不猜"

# 输出**永远**是 `scheme://authority/` 开头：查询串前面那个 `/` 是 MongoDB 的
# 语法要求，不是装饰。形状断言放在这里，是为了让「哪天有人手滑把 `/` 去掉」
# 至少能撞上一条 —— 值断言我可能又写错，形状是死的。
for u in 'mongodb://h:27017/db?x=1' 'mongodb://h:27017' 'mongodb://h:27017/' \
         'mongodb+srv://a:b@c/?y=2' 'mongodb://h1,h2:27017/db'; do
    got="$(uri_nodb "$u")"
    # 判据是「? 之前那一截以 / 结尾」，不是「结果里有 /」—— 后者在 bug 版本上
    # 照样成立（`h:27017?x=1` 里也有 `/`，只是位置错了），等于不设防。
    case "${got#*://}" in
        */)  ok  "形状：$u → $got" ;;
        */\?*) ok "形状：$u → $got" ;;
        *)   bad "形状：$u → $got（查询串前面没有 '/'）" ;;
    esac
done

# ---------------------------------------------------------------- 哨兵
__section "dr_mongo_eval_checked：包装（哨兵）由函数自己加，调用方只给裸正文"
# 这里断言的不是「谁调用了谁」，是那个契约本身。2026-10-03 的 bug 正是契约没被
# 强制：dr_record 自己拼了 JS 直接调 dr_mongo_eval_checked，没走 dr_wrap_js ——
# 哨兵没打，「记账成功」于是**永远**被判成失败，而账本其实已经写进去了（症状
# 因此同时长得像两种毛病：账本里多了一行 + 记账写不进去）。
#
# 修法是把包装挪进被调函数，所以能被桩测锁住的正是这一条：给一段**裸正文**，
# 函数必须自己把哨兵加上。桩掉容器那一层就够了，不需要 mongo、也不需要 node。
# 桩要经**文件**回传收到的 JS：dr_mongo_eval_checked 里是 `out="$(dr_mongo_eval …)"`，
# 那是子 shell，函数里给变量赋值出不来。这个坑本身也值一条注释 —— 我第一次写这
# 一节就是被它骗的：断言全红，而代码是对的。
SEEN="$(__mk)/seen.js"
dr_mongo_eval() { printf '%s' "$1" > "$SEEN"; printf '%s\n' "$1"; }

out="$(dr_mongo_eval_checked 'print("BODY");')"; rc=$?
check "$rc" "0" "裸正文跑通 → 通过"
got="$(cat "$SEEN")"
case "$got" in
    *"print(\"$DR_MONGO_SENTINEL\")"*) ok "哨兵是函数自己打上的（调用方不需要知道它存在）" ;;
    *) bad "生成的 JS 里没有哨兵，记账那条路径会再次永远判失败：$got" ;;
esac
case "$got" in
    *BODY*) ok "正文原样带进去了" ;;
    *)      bad "正文没进生成的 JS：$got" ;;
esac
case "$got" in
    *"try {"*) ok "正文被包进 try（异常时才能打印原因再 quit 1）" ;;
    *)         bad "没有 try 包裹：$got" ;;
esac

# 判据是哨兵，不是退出码 —— mongosh 存在「打印了错误、然后 0 退出」的情形，而
# 把没跑成的迁移记成「已应用」是最坏的一种：数据库没改，账本说改过了。
dr_mongo_eval() { printf '一段输出，但没有哨兵\n'; }   # 退出码 0
out="$(dr_mongo_eval_checked 'print("X");' 2>&1)"; rc=$?
check "$rc" "1" "退出码 0 但输出里没哨兵 → 判失败"
# 报错本身要说得清是「哨兵没出现」，否则半夜看到的只是一句没头没尾的失败。
case "$out" in
    *"$DR_MONGO_SENTINEL"*) ok "报错点名了缺的是哪个哨兵" ;;
    *) bad "报错没说清缺哨兵：$out" ;;
esac
# 桩留在这个 shell 里不再还原：这个文件后面没有别的地方调 dr_mongo_eval。

# ---------------------------------------------------------------- 区间合成
__section "dr_merge_counts：dump 前后两次读数 → 期望区间"
T="$(__mk)"
printf 'conversations\t3\ndisplay_messages\t5\n' > "$T/c0"
printf 'conversations\t7\ndisplay_messages\t5\nbrand_new\t2\n' > "$T/c1"
check "$(dr_merge_counts erp_agent "$T/c0" "$T/c1" | tr '\t' ':' | tr '\n' ' ')" \
      "erp_agent:brand_new:0:2 erp_agent:conversations:3:7 erp_agent:display_messages:5:5 " \
      "写入期间只增不减的集合得到 3..7；dump 期间新建的集合下限记 0"

printf 'gone\t9\n' > "$T/c2"; : > "$T/c3"
check "$(dr_merge_counts d "$T/c2" "$T/c3" | tr '\t' ':' | tr '\n' ' ')" "d:gone:0:9 " \
      "dump 期间被删掉的集合 → 0..9"

: > "$T/c4"
check "$(dr_merge_counts d "$T/c4" "$T/c4")" "" "两边都空时不输出、不报错"

# ---------------------------------------------------------------- 保留策略
__section "dr_prune：保留 7 份 + 状态文件引用的那份永不删"
R="$(__mk)"
for n in 1 2 3 4 5 6 7 8 9; do mkdir -p "$R/2026010${n}T000000Z-v9.9.${n}"; done
# 把**最旧**那份写进状态文件：没有保护逻辑的话它会被第一个剪掉。
ST="$(__mk)/production.env"
printf 'DB_DUMP=%s\n' "$R/20260101T000000Z-v9.9.1" > "$ST"
CD_STATE_FILE="$ST"; CD_PREV_FILE="$ST.nope"
CD_BACKUP_DIR="$R"; CD_BACKUP_KEEP=7

dr_prune >/dev/null

check "$(find "$R" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "8" \
      "9 份剪成 8 份（最近 7 + 受保护的 1）"
[ -d "$R/20260101T000000Z-v9.9.1" ] && ok "最旧那份受状态文件保护，没被剪" \
    || bad "受保护的那份被剪了 —— 回滚就没得可回了"
[ -d "$R/20260102T000000Z-v9.9.2" ] && bad "超出保留份数的旧备份没被剪" \
    || ok "超出保留份数的旧备份被剪掉"
[ -d "$R/20260109T000000Z-v9.9.9" ] && ok "最新那份还在" || bad "最新那份被剪了"

R2="$(__mk)"
for n in 1 2 3 4 5 6 7 8 9; do mkdir -p "$R2/2026010${n}T000000Z-v9.9.${n}"; done
CD_STATE_FILE="$R2/none.env"; CD_PREV_FILE="$R2/none.prev.env"; CD_BACKUP_DIR="$R2"
dr_prune >/dev/null 2>&1
check "$(find "$R2" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "7" \
      "没有状态文件时不报错，按 7 份剪"

# ---------------------------------------------------------------- 清单比对
__section "dr_compare：桩掉 docker，只验比对逻辑"
BK="$(__mk)"
printf 'fake-archive-erp\n'        > "$BK/erp_agent.archive.gz"
printf 'fake-archive-checkpoint\n' > "$BK/checkpointing_db.archive.gz"
mkdir -p "$BK/dummy"; : > "$BK/dummy/f1"; : > "$BK/dummy/f2"
tar -czf "$BK/download-data.tar.gz" -C "$BK/dummy" .
sha() { sha256sum "$1" | cut -d' ' -f1; }
{
    printf 'META version test\n'
    printf 'DB erp_agent %s %s %s\n' erp_agent.archive.gz \
        "$(sha "$BK/erp_agent.archive.gz")" "$(stat -c%s "$BK/erp_agent.archive.gz")"
    printf 'DB checkpointing_db %s %s %s\n' checkpointing_db.archive.gz \
        "$(sha "$BK/checkpointing_db.archive.gz")" "$(stat -c%s "$BK/checkpointing_db.archive.gz")"
    printf 'COLL erp_agent conversations 3 3\n'
    printf 'COLL erp_agent display_messages 5 7\n'
    printf 'COLL checkpointing_db checkpoints 4 4\n'
    printf 'VOLUME erp-agent_download-data %s %s %s %s\n' download-data.tar.gz \
        "$(sha "$BK/download-data.tar.gz")" "$(stat -c%s "$BK/download-data.tar.gz")" 2
} > "$BK/manifest.txt"
cp "$BK/manifest.txt" "$BK/m.bak"

# 恢复容器里"实际"长什么样，由这两个桩决定。
FIX_DBS="erp_agent checkpointing_db"
FIX_count() {
    case "$1.$2" in
        erp_agent.conversations)      echo 3 ;;
        erp_agent.display_messages)   echo 6 ;;
        checkpointing_db.checkpoints) echo 4 ;;
        *)                            echo 0 ;;
    esac
}
# shellcheck disable=SC2317  # 被 dr_compare 调用
docker() {
    case "$1" in
        exec)
            local js="${*: -1}" db coll
            case "$js" in
                *listDatabases*) printf '%s\n' $FIX_DBS ;;
                *countDocuments*)
                    db="$(printf '%s' "$js" | sed -n 's/.*getSiblingDB("\([^"]*\)").*/\1/p')"
                    coll="$(printf '%s' "$js" | sed -n 's/.*getCollection("\([^"]*\)").*/\1/p')"
                    FIX_count "$db" "$coll" ;;
                *) : ;;
            esac ;;
        *) : ;;
    esac
    return 0
}

# 先立正向对照：没有它，一个「永远返回失败」的比对会把下面每条负向用例都
# 变成"通过"，整套用例其实什么都没证明。
dr_compare c "$BK" >/dev/null 2>&1 && ok "干净清单 → 通过" \
    || bad "干净清单被误判为失败（比对逻辑或桩有问题）"

expect_fail() {   # $1=描述  $2=篡改命令（$1 是 manifest 路径）
    bash -c "$2" _ "$BK/manifest.txt"
    if dr_compare c "$BK" >/dev/null 2>&1; then
        bad "$1 —— 自检本该失败却通过了"
    else
        ok "$1 → 失败"
    fi
    cp "$BK/m.bak" "$BK/manifest.txt"
}

expect_fail "恢复条数低于区间下限" \
    'sed -i "s/^COLL erp_agent conversations 3 3/COLL erp_agent conversations 4 4/" "$1"'
expect_fail "恢复条数高于区间上限" \
    'sed -i "s/^COLL erp_agent conversations 3 3/COLL erp_agent conversations 0 2/" "$1"'
expect_fail "清单漏掉一个库（漏备份 checkpointing_db 的等价物）" \
    'sed -i "/^DB checkpointing_db /d" "$1"'
expect_fail "清单记的 archive sha256 与文件不符（截断/坏块的等价物）" \
    'sed -i "0,/^DB /s/ [0-9a-f]\{64\} / 0000000000000000000000000000000000000000000000000000000000000000 /" "$1"'
expect_fail "清单里一条 COLL 都没有（counts.tsv 丢了）" \
    'grep -v "^COLL " "$1" > "$1.t" && mv "$1.t" "$1"'
expect_fail "卷的实际条目数与清单记的 0 不符" \
    'sed -i "s/^VOLUME \(.*\) 2$/VOLUME \1 0/" "$1"'

FIX_DBS="erp_agent checkpointing_db stray_db"
dr_compare c "$BK" >/dev/null 2>&1 && bad "恢复出清单外的库没被判失败" \
    || ok "恢复出清单外的库 → 失败"
FIX_DBS="erp_agent checkpointing_db"

rm -rf "$T" "$R" "$R2" "$BK"

printf '\n==== 通过 %d，失败 %d ====\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
