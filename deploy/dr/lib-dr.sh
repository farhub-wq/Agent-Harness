#!/usr/bin/env bash
# deploy/dr/ 下备份与迁移共用的 mongo 直连原语。**只定义函数，source 它不产生副作用。**
#
# 为什么要单独一个文件，而不是让 migrate.sh 去 source backup.sh：这两个脚本都需要
# 「怎么在不把口令带进宿主机 ps 的前提下跟 mongo 说话」这一件事，而它的正确写法
# 只有一份 —— 所有操作都在**容器里**跑、口令从容器自己的环境取（$MONGODB_URI，
# 来自 deploy/.env 的 env_file）。复制第二份是这类代码漂移的标准起点；反过来让
# 迁移脚本去依赖备份脚本，则会让「为什么迁移要加载备份」变成一个每次都要重新
# 解释一遍的问题。
#
# 调用方式（backup.sh / migrate.sh 的顶部）：
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
