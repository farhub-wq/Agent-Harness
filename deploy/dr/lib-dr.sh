#!/usr/bin/env bash
# deploy/dr/ 下共用的原语：**绝大部分**是 mongo 直连的写法，另加备份产物的记账约定
# （dr_offsite_mark）。**只定义函数，source 它不产生副作用。**
#
# 为什么要单独一个文件，而不是让 migrate.sh 去 source backup.sh：这几个脚本都
# 需要「怎么在不把口令带进宿主机 ps 的前提下跟 mongo 说话」这一件事，而它的正确
# 写法只有一份 —— 所有操作都在**容器里**跑、口令从容器自己的环境取（$MONGODB_URI，
# 来自 deploy/.env 的 env_file）。复制第二份是这类代码漂移的标准起点；反过来让
# 迁移脚本去依赖备份脚本，则会让「为什么迁移要加载备份」变成一个每次都要重新
# 解释一遍的问题。
#
# 调用方式（backup.sh / migrate.sh / offsite.sh 的顶部）：
#   DR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$DR_DIR/../cd/lib.sh"      # cd_compose / warn / CD_MONGO_SERVICE
#   source "$DR_DIR/lib-dr.sh"
#
# 自己再 source 一遍 ../cd/lib.sh（它是幂等的：只定义函数与常量，见其文件头）。
# 这样本文件被单独拿到别处 source 时也不会缺符号。

DR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../cd/lib.sh
source "$DR_DIR/../cd/lib.sh"

# 迁移脚本成功执行的哨兵。定义在这里而不是调用处，是因为它是 dr_mongo_eval_checked
# 判据的一部分 —— 两边各写一份字面量的话，改了一处就会得到「永远不通过」。
DR_MONGO_SENTINEL="__DR_OK__"

# ---------------------------------------------------------------- 名字白名单
# 库名/集合名会进 mongosh 的 JS 正文。它们是应用自己建的，但「上游可信」不是一个
# 可以依赖的性质 —— 白名单校验比事后解释一次诡异报错便宜得多。
dr_valid_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_.-]*) return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------- 备份产物记账
# 把外推的结论写进备份目录（$dir/offsite.status，两行：结论词 + 原因）。
#
# 放在这个共用文件里，是因为**写它的和被读它的不是同一个进程**：backup.sh 与
# offsite.sh 各写各的路径（前者管「跳过」的两种情形，后者管真去推的那些），
# 而 deploy/cd/status.sh 几周之后来读。一处定义，三处认同一个格式。
#
# 结论词只有三个，status.sh 只认 ok：
#   ok       推上去了（且远端列过一遍）
#   skipped  没配凭据 / 显式跳过 —— 备份只在**同一块磁盘**上，不是成功
#   failed   推失败了（含被 BACKUP_OFFSITE_REQUIRED=0 降级放行的那种）
#
# 为什么需要它：外推的结果本来只活在**本次日志**里，而日志会滚、会被翻过去。
# 没有这个文件，status.sh 只能说「不知道」，而「不知道」在运维眼里和「没有」
# 是一个意思 —— 那就白报了。
dr_offsite_mark() {
    local dir="$1" status="$2"; shift 2
    [ -d "$dir" ] || return 0
    { printf '%s\n' "$status"; printf '%s\n' "$*"; } > "$dir/offsite.status" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------- 容器
dr_mongo_image() {
    # 按**正在跑的那个容器**取镜像，而不是写死版本号 —— 写死迟早会和 compose
    # 漂移。自检要起的恢复容器必须用它：恢复必须用不高于 dump 来源的 server 版本。
    local img=""
    img="$(cd_compose ps -q "$CD_MONGO_SERVICE" 2>/dev/null | head -1 \
        | xargs -r docker inspect -f '{{.Config.Image}}' 2>/dev/null || true)"
    printf '%s' "${img:-$CD_MONGO_IMAGE}"
}

dr_assert_mongo_up() {
    # 先断言容器在跑。不先做这一步的话，后面每个错误都会长得像「mongo 语法不对」
    # 或「库不存在」，而真正的原因是这套栈根本没起来 —— 排查方向从第一步就是错的。
    local cid state
    cid="$(cd_compose ps -q "$CD_MONGO_SERVICE" 2>/dev/null | head -1 || true)"
    if [ -z "$cid" ]; then
        warn "compose 里没有在跑的 '$CD_MONGO_SERVICE' 服务。先确认生产栈是起来的。"
        return 1
    fi
    state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)"
    if [ "$state" != "running" ]; then
        warn "mongo 容器状态是 '$state'，不是 running"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- JS 执行
# 所有 mongo 操作都在容器里跑，凭据从容器自己的环境里取（$MONGODB_URI）。也就是
# 说**这个脚本从头到尾不接触 Mongo 口令** —— 宿主机的进程列表里不会出现它，
# 脚本的变量里也没有它。
dr_mongo_eval() {
    # $1 = 一段 mongosh JS。用位置参数传，不拼进 sh -c 的正文里，避免 $ 与引号
    # 在容器 shell 里被二次解释。
    cd_compose exec -T "$CD_MONGO_SERVICE" sh -c \
        'mongosh "$MONGODB_URI" --quiet --eval "$1"' -- "$1"
}

# ---------------------------------------------------------------- 连接串：摘掉库名
# mongodump **拒绝**「URI 里带库名」与 `--db=` 同时出现：
#
#   Invalid Options: Cannot specify different database in connection URI and
#   command-line option — `erp_agent` was specified in the URI and
#   `checkpointing_db` was specified in the --db option
#
# 而 MONGODB_URI 里恰好带着库名（`.../erp_agent?authSource=admin`），备份又必须
# 逐库显式 `--db` —— 所以每一轮都会在**第一个非 URI 库**上当场退出。2026-10-03
# 由 CI 的 backup-dr job 首次真跑时抓到；这条在计划里就是「只能在真机验」清单上
# 的一项，现在有答案了。
#
# 摘除动作必须在**容器里**做：$MONGODB_URI 带口令，在宿主机上展开就等于把口令写进
# `docker exec` 的 argv，宿主机的 `ps` 里就能看到 —— 那正是本文件开头那条性质要
# 避免的事。所以下面存的**不是宿主机函数，而是一段在容器里执行的 shell 源码**；
# 调用处把它拼在 `sh -c` 的正文前面（见 backup.sh 的 dr_dump_db）。
#
# **摘完必须留下那个 `/`。** MongoDB 的连接串语法要求查询串前面有 `/`：
#
#   mongodb://host:27017?authSource=admin    → error parsing uri:
#                                              must have a / before the query ?
#   mongodb://host:27017/?authSource=admin   → 对
#
# 所以输出统一是 `scheme://authority/<query>`，路径部分永远是空的 `/`。这一条也是
# CI 抓到的：**桩测当时是绿的**，因为断言里写的「期望值」本身就是我照错误的理解
# 手写的 —— 桩测只能验证「代码符合我以为的规格」，规格本身得由真的解析器来判。
#
# 实现只用参数展开，不依赖 sed/awk：mongo 镜像里 /bin/sh 是 dash，而这个片段同时
# 要在宿主机（CI 的 sh、开发机的 Git Bash）被桩测跑一遍，能少一个外部依赖就少一个。
# 拆查询串刻意走 case 而不用 `${X#"$Y"}` 那种嵌套引号 —— 它在 bash 下没问题，但
# 这个片段真正的执行环境是 dash，而嵌套引号在 `"${...}"` 里的行为是那种「本机测
# 过了、换台机器才炸」的地方。口令里未编码的 `/` 不符合 RFC 3986，故
# `${_dr_rest%%/*}` 不会切错。
DR_MONGO_URI_NODB_SH='
dr_uri_nodb() {
    _dr_head=""
    _dr_query=""
    case "$MONGODB_URI" in
        *\?*) _dr_head="${MONGODB_URI%%\?*}"; _dr_query="?${MONGODB_URI#*\?}" ;;
        *)    _dr_head="$MONGODB_URI" ;;
    esac
    case "$_dr_head" in
        *://*) ;;
        *) printf %s "$MONGODB_URI"; return 0 ;;   # 不是 URI 形状，不猜，原样交出去
    esac
    _dr_rest="${_dr_head#*://}"        # [user:pass@]host[:port][/db]
    printf %s "${_dr_head%%://*}://${_dr_rest%%/*}/${_dr_query}"
}
'

# 把一整段 JS 交给容器里的 mongosh，并且**要求它自己回一个哨兵**。
#
# 为什么不能只看退出码：`mongosh --eval` 遇到脚本里的异常时报什么退出码，随版本
# 而变，而且它在某些情形下会「打印了错误、然后 0 退出」。迁移器把这个结果记成
# 「已应用」的后果是最坏的一种 —— 数据库没改，账本上写着改过了，下一次发布不会
# 再跑它。所以判据是输出里有没有哨兵：没有 = 失败，退出码只用来辅助报错。
#
# 哨兵由调用方拼在 JS 末尾（见 migrate.sh 的 dr_wrap_js），这样迁移文件本身可以
# 写得像一段普通脚本，不必知道迁移器的存在。
dr_mongo_eval_checked() {
    local js="$1" out rc=0
    out="$(dr_mongo_eval "$js" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
        warn "  mongosh 退出码 $rc"
        return 1
    fi
    case "$out" in
        *"$DR_MONGO_SENTINEL"*) return 0 ;;
    esac
    warn "  mongosh 退出码是 0，但输出里没有哨兵 $DR_MONGO_SENTINEL"
    warn "  这说明脚本中途抛了异常而 mongosh 没有把它变成非零退出码。"
    return 1
}
