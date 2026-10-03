#!/usr/bin/env bash
# 发布/回滚/巡检的通知出口。**任何失败都不影响发布**：调用方一律 `|| true`。
#
#   bash deploy/cd/notify.sh --event deploy_succeeded --version v1.0.0 \
#        --sha <40位> --tag sha-xxxxxxxxxxxx --duration 47 --exit-code 0
#   bash deploy/cd/notify.sh --event deploy_failed --dry-run      # 只打印 payload
#
# 事件：deploy_started / deploy_succeeded / deploy_failed / shadow_failed /
#       rollback_started / rollback_succeeded / rollback_failed /
#       backup_failed / migrate_failed / health_degraded / drill_report
#
# 通道由 ALERT_KIND + ALERT_WEBHOOK 选。两者都没配时**只告警不报错** ——
# 「没配通知」不应该让一次发布失败。
#
# 密钥从环境读；环境没有时回落到 /etc/erp-agent/notify.env（root 0600）。
# 这样 runner 触发的发布不必把 webhook 塞进 runner 的进程环境。
set -uo pipefail

CD_NOTIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${ALERT_WEBHOOK:-}" ] && [ -r /etc/erp-agent/notify.env ]; then
    set -a
    # shellcheck disable=SC1091
    . /etc/erp-agent/notify.env
    set +a
fi

EVENT=""
VERSION=""
SHA=""
TAG=""
EXIT_CODE=""
DURATION=""
OPERATOR="${DEPLOYED_BY:-$(id -un 2>/dev/null || echo unknown)}"
DRY_RUN=0
EXTRA=""

warn() { printf '\033[33m !! %s\033[0m\n' "$*" >&2; }

usage() {
    sed -n '2,12p' "$0" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --event)     EVENT="${2:-}"; shift 2 ;;
        --version)   VERSION="${2:-}"; shift 2 ;;
        --sha)       SHA="${2:-}"; shift 2 ;;
        --tag)       TAG="${2:-}"; shift 2 ;;
        --exit-code) EXIT_CODE="${2:-}"; shift 2 ;;
        --duration)  DURATION="${2:-}"; shift 2 ;;
        --operator)  OPERATOR="${2:-}"; shift 2 ;;
        --text)      EXTRA="${2:-}"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           warn "未知参数 '$1'"; usage; exit 2 ;;
    esac
done

[ -n "$EVENT" ] || { warn "缺 --event"; usage; exit 2; }

# 事件 -> 好不好消息。跨脚本复用同一份语义，别让每个调用点自己判断怎么措辞。
case "$EVENT" in
    deploy_succeeded|rollback_succeeded|drill_report) ICON="✅" ;;
    deploy_started|rollback_started)                  ICON="🚀" ;;
    deploy_failed|rollback_failed|backup_failed|shadow_failed|migrate_failed) ICON="❌" ;;
    health_degraded)                                  ICON="⚠️" ;;
    *)                                                ICON="ℹ️" ;;
esac

TEXT="$(printf '%s %s' "$ICON" "$EVENT")"
append() { [ -n "$2" ] && TEXT="$TEXT
$1: $2"; return 0; }
append "版本"   "$VERSION"
append "镜像"   "$TAG"
append "commit" "${SHA:0:12}"
append "退出码" "$EXIT_CODE"
append "耗时"   "${DURATION:+${DURATION}s}"
append "操作者" "$OPERATOR"
append ""       "$EXTRA"
append "时间"   "$(date '+%F %T %Z')"
unset -f append

KIND="${ALERT_KIND:-}"
WEBHOOK="${ALERT_WEBHOOK:-}"

if [ -z "$KIND" ] || [ -z "$WEBHOOK" ]; then
    warn "未配置通知（ALERT_KIND/ALERT_WEBHOOK 都为空），跳过 $EVENT"
    [ "$DRY_RUN" = "1" ] && { echo "--- payload（未配置通道，仅预览文本）---"; echo "$TEXT"; }
    exit 0
fi

# JSON 字符串转义。优先用 python3（消息里有换行、引号、中文），但不能假设它在。
#
# 这里有两个坑，都是"静默产出非法 JSON"这种最坏形态（飞书/企微对非法 JSON 的
# 响应是 HTTP 200 + 正文里的错误码，curl 退出码是 0，于是通知**消失**而日志干净）：
#
#   1. 不能用 `command -v python3` 判断可用性。真机实测：Windows 的应用执行别名
#      会放一个 python3 存根在 PATH 上，`command -v` 找得到，跑起来却失败 ——
#      于是命令替换返回空串，payload 变成 `{"text":}`。
#   2. 所以判断方式必须是"跑一下看有没有结果"，而不是"看有没有这个命令"。
#
# 兜底分支不追求通用正确，只求不产出非法 JSON：把 `\` 和 `"` 直接删掉（我们生成的
# 文本里从来没有这两个字符 —— 它是版本号、commit、退出码、状态这几样），换行折成
# 空格。信息量损失为零，正确性由构造保证而不是由转义表保证。
json_escape() {
    local s out
    s="$(cat)"
    if command -v python3 >/dev/null 2>&1; then
        out="$(printf '%s' "$s" | python3 -c \
            'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))' 2>/dev/null || true)"
        # 空串 = 失败（json.dumps 对空输入也返回 `""` 两个字符，不会是空）
        [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    fi
    printf '"%s"' "$(printf '%s' "$s" | tr -d '\r\\"' | tr '\n' ' ')"
}

payload=""
case "$KIND" in
    feishu)
        # 飞书自定义机器人的签名是**反直觉**的：HMAC 的 key 是 "<ts>\n<secret>"，
        # 而被签名的消息是**空字符串**（不是反过来）。
        #   sign = base64(HMAC-SHA256(key = "<ts>\n<secret>", msg = ""))
        # 官方文档与 Gitea PR #34788 的修法一致。写成 key=secret / msg="<ts>\n<secret>"
        # 是很自然的误读，而它的失败形态是飞书回 200 + code 19021，curl 退出码 0 ——
        # 通知静默消失。所以这里不用 openssl 的 -hmac 配管道（那条路容易写反），
        # 而是显式地把 key 算出来、管道喂空输入。
        #
        # 时间戳是秒级；飞书会校验时间偏差（3600s，也有说 300s），目标机要 NTP 正常。
        # 机器人没开签名校验时 FEISHU_SECRET 留空，不带这两个字段即可。
        if [ -n "${FEISHU_SECRET:-}" ]; then
            TS="$(date +%s)"
            SIGN_KEY="$(printf '%s\n%s' "$TS" "$FEISHU_SECRET")"
            SIGN="$(printf '' | openssl dgst -sha256 -hmac "$SIGN_KEY" -binary | base64 | tr -d '\n')"
            payload="{\"timestamp\":\"$TS\",\"sign\":\"$SIGN\",\"msg_type\":\"text\",\"content\":{\"text\":$(printf '%s' "$TEXT" | json_escape)}}"
        else
            payload="{\"msg_type\":\"text\",\"content\":{\"text\":$(printf '%s' "$TEXT" | json_escape)}}"
        fi
        ;;
    wecom|dingtalk)
        # 两家都是 {"msgtype":"text","text":{"content":"..."}}，形状一致。
        payload="{\"msgtype\":\"text\",\"text\":{\"content\":$(printf '%s' "$TEXT" | json_escape)}}"
        ;;
    serverchan)
        # Server酱用表单，不是 JSON。
        payload="title=$(printf '%s' "$EVENT" | json_escape)&desp=$(printf '%s' "$TEXT" | json_escape)"
        ;;
    generic-webhook)
        payload="{\"event\":$(printf '%s' "$EVENT" | json_escape),\"text\":$(printf '%s' "$TEXT" | json_escape)}"
        ;;
    *)
        warn "未知 ALERT_KIND='$KIND'（支持 feishu/wecom/dingtalk/serverchan/generic-webhook）"
        exit 2
        ;;
esac

if [ "$DRY_RUN" = "1" ]; then
    echo "--- ALERT_KIND=$KIND ---"
    printf '%s\n' "$payload"
    exit 0
fi

case "$KIND" in
    serverchan)
        resp="$(curl -sS --max-time 15 -X POST "$WEBHOOK" \
            --data-urlencode "title=$EVENT" --data-urlencode "desp=$TEXT" 2>&1)" && rc=0 || rc=$?
        ;;
    *)
        resp="$(curl -sS --max-time 15 -X POST "$WEBHOOK" \
            -H 'Content-Type: application/json' -d "$payload" 2>&1)" && rc=0 || rc=$?
        ;;
esac

if [ "${rc:-0}" -ne 0 ]; then
    warn "通知发送失败（curl exit=$rc）：$resp"
    exit 1
fi

# 飞书/企业微信/钉钉都是 HTTP 200 + 正文里的 code 表达业务结果，所以 curl 的
# 退出码只说明"送到了"，不说明"发出去了"。不解析 JSON（bash 里做这个不划算），
# 只把回执原文留在日志里 —— 通知没送到不该让发布失败。
printf '    notify: %s -> %s\n' "$EVENT" "$(printf '%s' "$resp" | head -c 200)"
exit 0
