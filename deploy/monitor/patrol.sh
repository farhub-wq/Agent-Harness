#!/usr/bin/env bash
# 机内巡检。erp-agent-patrol.timer 每 10 分钟跑一次；erp-agent-heartbeat.timer
# 每天调一次 --heartbeat。
#
#   bash deploy/monitor/patrol.sh               常规巡检：状态变了才发通知
#   bash deploy/monitor/patrol.sh --force       不管变没变都发（排查用）
#   bash deploy/monitor/patrol.sh --heartbeat   每日心跳：死信 ping + 一条汇总
#   bash deploy/monitor/patrol.sh --dry-run     只打印判定，不发通知不写状态
#
# 退出码：0 全绿 / 1 有问题 / 3 本轮跳过（正在发布，或另一轮巡检在跑）
#
# ---------------------------------------------------------------- 为什么要有「状态变迁」这一层
# timer 每 10 分钟响一次 = 一天 144 次。每次都发通知的话，真正要看的那条会被泡在
# 噪音里，而通知渠道的全部价值就在于「它响起来说明有事」。所以这里把判定结果压成
# 一组稳定的 (id, OK/FAIL) 对，排序后与上一次比：一样就安静，不一样才发。
#
# 关键在于**用 id 而不是用细节**做指纹。status.sh 的输出里有镜像名、digest、版本
# 号、可用空间数字 —— 它们每次发布都会变，拿全文做指纹等于每次发布都发一条假告警，
# 几次之后所有人都会把这套通知静音掉，而一套被静音的通知比没有通知更糟（你以为
# 它在看着）。id 是 status.sh 里手写的稳定标识符，细节随便变都不影响判定。
#
# 反过来，这个机制有一个必须写在明面上的失效模式：**状态在两次巡检之间坏了又好，
# 是看不见的。** 10 分钟窗口里发生又结束的一切都不在记录里。它对「持续性的坏状态」
# 有效，对「闪断」无效 —— 闪断要靠箱外的探活（阿里云云监控站点监控），而那个要在
# 控制台上注册，不在本次范围内。别把这里的绿灯读成「这十分钟里一切都好」。
#
# ---------------------------------------------------------------- 发布期间为什么整轮跳过
# 发布期间服务在重建、digest 天然对不上、pending 天然存在 —— 照常判定的话每次发布
# 都会产生一条告警加一条恢复，而发布本身已经有自己的四条通知了。所以 pending 文件
# 只要还「年轻」就跳过整轮；它老到超过 CD_DEPLOY_INFLIGHT_GRACE 才说明那是**卡住
# 的** pending，而卡住的 pending 正是这里最该报出来的东西之一。
set -uo pipefail

MON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../cd/lib.sh
source "$MON_DIR/../cd/lib.sh"

# 死信地址（healthchecks.io 一类）。与 webhook 同一个文件 —— 它们都是「往箱外发
# 一句话」，分成两个文件只会多一个没人记得去配的地方。
NOTIFY_ENV_FILE="${NOTIFY_ENV_FILE:-/etc/erp-agent/notify.env}"

usage() { sed -n '2,8p' "$0" >&2; }

# ---------------------------------------------------------------- 状态文件
# 内容只有「上一次那组 id|OK/FAIL」。它**刻意不在仓库树里**（见 lib.sh 的
# CD_PATROL_STATE_DIR）：tree 是 rsync --delete 刷出来的，放进去每次发布就丢一次。
p_read_fp() {
    [ -f "$CD_PATROL_LAST" ] || return 0
    grep '|' "$CD_PATROL_LAST" 2>/dev/null || true
}

p_write_fp() {
    local fp="$1"
    mkdir -p "$CD_PATROL_STATE_DIR" || {
        warn "建不出 $CD_PATROL_STATE_DIR —— 下一轮还会认为状态变了，会重复告警"
        return 1
    }
    {
        printf '# 由 deploy/monitor/patrol.sh 写，不要手改。\n'
        printf '# 下面每一行是 <检查 id>|<OK 或 FAIL>。指纹只由它们组成，不含任何\n'
        printf '# 会随发布变的细节（镜像名、digest、版本号、剩余空间）。\n'
        printf 'UPDATED_AT=%s\n' "$(date -Iseconds)"
        printf 'HOST=%s\n' "$(hostname)"
        [ -n "$fp" ] && printf '%s\n' "$fp"
    } > "$CD_PATROL_LAST"
}

# ---------------------------------------------------------------- 指纹
# 从 status.sh 的输出里抽出 (id, OK/FAIL) 对。格式是 status.sh 定下的接口，见它
# 文件头那段「输出格式是接口」。
p_fingerprint() {
    local line st id
    while IFS= read -r line; do
        case "$line" in
            "[OK] "*|"[FAIL] "*)
                st="${line%%]*}"; st="${st#[}"
                # 取 "] " 之后的东西，再削掉剩下的前导空白。**这一步不能省**：
                # status.sh 里 `[OK]   ` 是三个空格而 `[FAIL] ` 是一个（对齐用的），
                # 于是 OK 类的 id 会带着两个空格出来，被下面那条形状校验整体丢掉
                # —— 表现是**指纹里只剩 FAIL 项**，一个「只有失败项会变」的指纹，
                # 也就是「服务从 FAIL 变成 OK 时不会告警」。
                # 实测踩到过：deploy/ci/patrol-logic-test.sh 的第三条断言就是它。
                id="${line#*]}"
                id="${id#"${id%%[![:space:]]*}"}"
                id="${id%%:*}"
                # id 的形状是 status.sh 手写的那些。不像的那些（比如它哪天加了
                # 别的类型输出）直接跳过，而不是把一句散文当成检查项收进指纹 ——
                # 那样会得到一条每次都变的指纹，也就是每次都告警。
                case "$id" in
                    ''|*[!a-z0-9_-]*) continue ;;
                esac
                printf '%s|%s\n' "$id" "$st"
                ;;
        esac
    done | sort -u
}

# 两组指纹之间的差异，一句话。只在真的变过时叫。
p_diff_summary() {
    local prev="$1" now="$2" broken fixed
    broken="$(comm -13 <(printf '%s\n' "$prev") <(printf '%s\n' "$now") \
        | sed -n 's/|FAIL$//p' | tr '\n' ' ')"
    fixed="$(comm -23 <(printf '%s\n' "$prev") <(printf '%s\n' "$now") \
        | sed -n 's/|FAIL$//p' | tr '\n' ' ')"
    [ -n "$broken" ] && printf '新出现问题：%s\n' "$broken"
    [ -n "$fixed" ]  && printf '已恢复：%s\n' "$fixed"
    return 0
}

# ---------------------------------------------------------------- 跑 status.sh
# 去掉 ANSI 颜色再进指纹与通知正文：颜色码在聊天窗口里是乱码，而指纹里带上它们
# 则会让「同一状态」在两次运行之间被判成不同（转义序列本身是稳定的，但没必要
# 赌这个 —— 而且 status.sh 以后换了颜色方案就会无声地破坏指纹）。
p_strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

P_STATUS_CLEAN=""
p_collect() {
    local raw rc=0
    raw="$(bash "$CD_LIB_DIR/status.sh" "$CD_ENV" 2>&1)" || rc=$?
    P_STATUS_CLEAN="$(printf '%s' "$raw" | p_strip_ansi)"
    return "$rc"
}

# ---------------------------------------------------------------- 常规巡检
p_check() {
    local force="$1" dry="$2"
    local rc=0 fp prev changed=0 nfail event body

    # 判据在 lib.sh（cd_deploy_in_flight）：定时备份也用它，两边必须是同一句话。
    if cd_deploy_in_flight; then
        info "有一次发布正在进行（$CD_PENDING_FILE 还年轻）—— 本轮整轮跳过"
        return 3
    fi

    p_collect; rc=$?
    fp="$(printf '%s\n' "$P_STATUS_CLEAN" | p_fingerprint)"
    if [ -z "$fp" ]; then
        # status.sh 一行可识别的检查都没输出 = 它在半路就退出了（缺 docker、
        # 缺 deploy/.env、被 die 掉……）。这不是「全绿」，把它压成一个固定的
        # FAIL 项走同一条通知路径 —— 沉默是这里最不该有的反应。
        warn "status.sh 没有输出任何可识别的检查行（退出码 $rc）—— 当成一条 FAIL"
        printf '%s\n' "$P_STATUS_CLEAN" >&2
        fp="patrol-broken|FAIL"
    fi

    prev="$(p_read_fp)"
    [ "$fp" = "$prev" ] || changed=1
    nfail="$(printf '%s\n' "$fp" | grep -c '|FAIL$' || true)"

    if [ "$nfail" -gt 0 ]; then event=patrol_alert; else event=patrol_ok; fi

    if [ "$changed" -eq 0 ] && [ "$force" -eq 0 ]; then
        info "状态没变（$nfail 项失败）—— 不通知"
        return "$rc"
    fi

    body=""
    if [ "$changed" -eq 1 ] && [ -n "$prev" ]; then
        body="$(p_diff_summary "$prev" "$fp")"
    else
        body="首次巡检基线（$([ "$nfail" -gt 0 ] && echo "$nfail 项失败" || echo '全部通过')）"
    fi
    body="$body
$P_STATUS_CLEAN"

    if [ "$dry" = "1" ]; then
        printf '\n--- dry-run：会发 %s ---\n%s\n' "$event" "$body"
    else
        cd_notify "$event" --text "$body"
    fi

    # 状态文件在通知**之后**写：反过来的话，通知失败（网络抖、webhook 过期）会
    # 让这一轮的变化被记成"已经报过了"，而人从来没收到 —— 那正好是这套机制唯一
    # 不能有的失效方式。代价是通知失败时下一轮会重发一次，那是对的方向。
    [ "$dry" = "1" ] || p_write_fp "$fp"
    return "$rc"
}

# ---------------------------------------------------------------- 每日心跳
# 与巡检的区别是：**它无条件发**。心跳的全部意义就是「不管好不好，每天都有一条」，
# 所以它不受状态变迁的抑制 —— 一条只在出事时才来的心跳不是心跳。
#
# 它比站内通知多做一件事：往箱外的死信地址 ping 一下。站内那条证明不了「机器还
# 活着」（机器没了就什么都没有），而死信地址是**别人**在盯着 —— 该来的 ping 没
# 来，它就替我们报警。这也正是「巡检 timer 被人偷偷停掉」唯一能被发现的方式。
p_heartbeat() {
    local dry="$1" body rc=0 nfail total
    local url="${HEARTBEAT_URL:-}"

    if [ -z "$url" ] && [ -r "$NOTIFY_ENV_FILE" ]; then
        # 与 notify.sh 同一个约定：我们自己写的 KEY=VALUE，不含命令替换。
        # 只在需要时读，避免把一个含 webhook 的文件在无用的情况下载进环境。
        url="$(sed -n 's/^HEARTBEAT_URL=//p' "$NOTIFY_ENV_FILE" | head -1 | tr -d '"'"'"'')"
    fi

    if [ -z "$url" ]; then
        warn "没有配 HEARTBEAT_URL —— 死信 ping 跳过。"
        warn "  这意味着「巡检 timer 被停掉」这件事没有任何人会知道：站内通知发不"
        warn "  出去时，恰恰是它最该说话的时候。在 $NOTIFY_ENV_FILE 里加一行"
        warn "  HEARTBEAT_URL=<healthchecks.io 给的 ping 地址> 即可（见 deploy/dr/README.md）。"
    elif [ "$dry" = "1" ]; then
        info "--dry-run：会 ping $url"
    elif curl -fsS --max-time 10 -o /dev/null "$url"; then
        info "死信 ping 已送出"
    else
        warn "死信 ping 失败（curl 退出码 $?）—— 连续失败会被那边的服务判成失联"
    fi

    p_collect || true
    nfail="$(printf '%s\n' "$P_STATUS_CLEAN" | p_fingerprint | grep -c '|FAIL$' || true)"
    total="$(printf '%s\n' "$P_STATUS_CLEAN" | p_fingerprint | grep -c '|' || true)"

    body="每日心跳：$total 项检查里 $nfail 项失败"
    if [ "$nfail" -gt 0 ]; then
        body="$body
$(printf '%s\n' "$P_STATUS_CLEAN" | grep '^\[FAIL\]' || true)"
    fi

    if [ "$dry" = "1" ]; then
        printf '\n--- dry-run：会发 heartbeat ---\n%s\n' "$body"
    else
        cd_notify heartbeat --text "$body"
    fi
    return "$rc"
}

# ---------------------------------------------------------------- 入口
# BASH_SOURCE 守卫不是装饰：deploy/ci/patrol-logic-test.sh 会 source 本文件取上面
# 那几个纯函数（p_strip_ansi / p_fingerprint / p_diff_summary）。没有这个守卫，
# source 就会把测试进程当成一次真巡检跑起来，而它会发通知、写状态文件。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cd_load_env "${CD_ENV_NAME:-production}"

    FORCE=0
    DRY=0
    MODE=check
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --force)      FORCE=1; shift ;;
            --heartbeat)  MODE=heartbeat; shift ;;
            --dry-run)    DRY=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            warn "未知参数 '$1'"; usage; exit 2 ;;
        esac
    done

    # 巡检自己的锁，**与发布锁是两把**（见 lib.sh）。只防「手动重跑撞上 timer」
    # 造成的重复告警；拿不到就让路，不要等 —— 10 分钟后再来就是了。
    #
    # --dry-run 不取锁：它不写状态文件，重复跑也不会有任何后果，而「想看一眼时被
    # 一句'另一轮正在跑'挡回来」正是最不需要的摩擦。
    if [ "$DRY" != "1" ]; then
        mkdir -p "$CD_PATROL_STATE_DIR" \
            || { warn "建不出 $CD_PATROL_STATE_DIR"; exit 1; }
        if command -v flock >/dev/null 2>&1; then
            exec 9>"$CD_PATROL_LOCK"
            if ! flock -n 9; then
                info "另一轮巡检正在跑，本轮跳过"
                exit 3
            fi
        else
            # 生产机上不会发生（cd_assert_tools 要求 flock），但巡检是**唯一**
            # 一个无人值守的调用方 —— 在这里静默死掉的话，症状是「监控再也没报
            # 过警」，而那看起来和「一切正常」一模一样。
            warn "没有 flock —— 跳过巡检锁（同时跑两轮会重复告警，但不会漏报）"
        fi
    fi

    case "$MODE" in
        heartbeat) p_heartbeat "$DRY" ;;
        check)     p_check "$FORCE" "$DRY" ;;
    esac
fi
