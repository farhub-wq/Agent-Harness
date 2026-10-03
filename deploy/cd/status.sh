#!/usr/bin/env bash
# 只读巡检。给运维人和 deploy/monitor/patrol.sh 用，绝不修改任何状态。
#
#   bash deploy/cd/status.sh [production]
#   echo $?     # 0 = 全绿，1 = 有问题
#
# 它回答六个问题：
#   1) 七个服务都在跑且 healthy 吗
#   2) 跑着的镜像和 state 文件记的是同一版吗（不一致 = 有人绕过脚本手工 up）
#   3) 有发布卡在半途吗
#   4) 共享密钥一致吗
#   5) 磁盘还够吗
#   6) 回滚能力还具备吗（prev 快照 + 旧镜像 + 源码树都还在吗）
#   7) 备份还在吗、新鲜吗、推出去过吗
#
# ---------------------------------------------------------------- 输出格式是接口
# 每一行都是 `[OK] <id>: <给人看的细节>` 或 `[FAIL] <id>: <细节>`。**id 是稳定的
# 标识符，细节是易变的散文** —— patrol.sh 按 id 做状态变迁判定（见它文件头）。
#
# 所以：加一条检查必须给它一个 id；id 的集合与含义不要随手改（改了等于让 patrol
# 在下一轮认为"状态变了"，发一条假告警）。细节里出现的镜像名、digest、版本号都会
# 随每次发布变，但那不影响判定，因为判定只看 id 与 OK/FAIL。
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd_load_env "${1:-production}"

BAD=0
ok()   { printf '\033[32m[OK]\033[0m   %s: %s\n' "$1" "$2"; }
bad()  { printf '\033[31m[FAIL]\033[0m %s: %s\n' "$1" "$2"; BAD=1; }
note() { printf '       %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------- 1. 服务
head_ 服务
if ! docker info >/dev/null 2>&1; then
    bad docker "docker daemon 不可达"
else
    ok docker "daemon 可达"
    # 一次性服务 sandbox-image-loader 跑完就退出，不算异常。
    ps_out="$(cd_compose ps --all --format '{{.Service}}\t{{.Image}}\t{{.State}}\t{{.Health}}' 2>/dev/null || true)"
    if [ -n "$ps_out" ]; then
        expected="mongo dind mock-erp mcp backend frontend nginx"
        while IFS=$'\t' read -r svc img state health; do
            case "$svc" in sandbox-image-loader|"") continue ;; esac
            expected="$(printf '%s\n' $expected | grep -vx "$svc" | tr '\n' ' ')"
            if [ "$state" = "running" ] && [ "$health" = "healthy" ]; then
                ok "service-$svc" "healthy（$img）"
            else
                bad "service-$svc" "state=$state health=${health:-none}（$img）"
            fi
        done <<< "$ps_out"

        leftover="$(printf '%s' "$expected" | tr -d ' ')"
        [ -z "$leftover" ] || bad service-missing "compose 里没有这些服务：$leftover"
    else
        bad service-list "拿不到 compose 服务列表（project=$PROJECT）"
    fi
fi

# ---------------------------------------------------------------- 2. 版本一致性
head_ 版本一致性
if [ ! -f "$CD_STATE_FILE" ]; then
    bad state-file "没有状态文件 $CD_STATE_FILE（这台机器还没被 deploy.sh 接管过）"
else
    ok state-file "$(grep -E '^(VERSION|GIT_SHA|DEPLOYED_AT|DEPLOYED_BY)=' "$CD_STATE_FILE" | tr '\n' ' ')"

    # 比的是**容器实际在跑的 image ID**，不是镜像引用名。引用名会合理地不同：
    # `init` 接管一台已经在跑的机器时状态记的是 v0，而容器仍是创建时的 :local，
    # 两者 digest 相同 —— 方案里「发布以 digest 为准」说的就是这个。
    running="$(cd_compose ps -q 2>/dev/null | xargs -r docker inspect \
        --format '{{index .Config.Labels "com.docker.compose.service"}} {{.Image}}' 2>/dev/null \
        | grep -E '^(mock-erp|mcp|backend|frontend) ' | sort || true)"
    want="$( {
        sed -n 's/^MOCK_ERP_IMAGE_ID=/mock-erp /p' "$CD_STATE_FILE"
        sed -n 's/^APP_IMAGE_ID=/mcp /p'           "$CD_STATE_FILE"
        sed -n 's/^APP_IMAGE_ID=/backend /p'       "$CD_STATE_FILE"
        sed -n 's/^FRONTEND_IMAGE_ID=/frontend /p' "$CD_STATE_FILE"
    } | sort )"
    if [ "$running" = "$want" ]; then
        ok digest-consistency "四个换版服务的运行 digest 与 state 一致"
    else
        bad digest-consistency "运行中的镜像 digest 与 state 不一致 —— 有人绕过脚本手工换过版？"
        diff <(printf '%s\n' "$want") <(printf '%s\n' "$running") | sed 's/^/       /' >&2 || true
    fi

    # 引用完整性：state 记的 digest 必须还是本机那个 tag 现在指着的那个
    #（tag 可以被重新指向，digest 不能）。
    for key in APP_IMAGE:APP_IMAGE_ID FRONTEND_IMAGE:FRONTEND_IMAGE_ID MOCK_ERP_IMAGE:MOCK_ERP_IMAGE_ID; do
        ref="$(cd_state_get "$CD_STATE_FILE" "${key%%:*}" || true)"
        id="$(cd_state_get "$CD_STATE_FILE" "${key##*:}" || true)"
        [ -n "$ref" ] && [ -n "$id" ] || continue
        now="$(cd_image_id "$ref")"
        [ "$now" = "$id" ] || bad "digest-ref-${key%%:*}" "$ref 的 digest 变了（state=$id 现在=${now:-缺失}）"
    done
fi

# ---------------------------------------------------------------- 3. 半途发布
head_ 半途发布
if [ -f "$CD_PENDING_FILE" ]; then
    bad pending "存在 $CD_PENDING_FILE —— 有一次发布卡在半途没走完，需要人工确认"
    note "$(grep -E '^(VERSION|GIT_SHA|DEPLOYED_AT)=' "$CD_PENDING_FILE" | tr '\n' ' ')"
else
    ok pending "没有 pending 残留"
fi

# ---------------------------------------------------------------- 4. 共享密钥
head_ 共享密钥
a="$(sed -n 's/^INTERNAL_AUTH_TOKEN=//p' "$CD_REPO_ROOT/deploy/.env" 2>/dev/null | head -1 | tr -d '"'"'"'')"
b="$(sed -n 's/^INTERNAL_AUTH_TOKEN=//p' "$CD_REPO_ROOT/deploy/nginx.env" 2>/dev/null | head -1 | tr -d '"'"'"'')"
if [ -z "$a" ] || [ -z "$b" ]; then
    bad secret "INTERNAL_AUTH_TOKEN 缺失（.env='${a:+有}' nginx.env='${b:+有}'）—— 共享密钥校验是关的"
elif [ "$a" = "$b" ]; then
    ok secret "两处一致（len=${#a}，前 4 位 ${a:0:4}…）"
else
    bad secret "两处不一致 —— /health 会 200 但所有 /api 会 401。跑 sh deploy/set_internal_token.sh"
fi

# ---------------------------------------------------------------- 5. 磁盘
head_ 磁盘
avail="$(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -z "$avail" ]; then
    bad disk "读不出 /var/lib/docker 可用空间"
elif [ "$avail" -lt "$CD_DISK_MIN_GB" ]; then
    bad disk "docker 分区可用 ${avail}G < ${CD_DISK_MIN_GB}G —— 下次发布可能中途失败"
else
    ok disk "docker 分区可用 ${avail}G（门槛 ${CD_DISK_MIN_GB}G）"
fi

# ---------------------------------------------------------------- 6. 回滚能力
head_ 回滚能力
# 只跑一次，把它的输出留着在失败时展示（跑两次会让前置检查打两遍）。
if check_out="$(bash "$CD_LIB_DIR/deploy.sh" rollback "$CD_ENV" --check 2>&1)"; then
    ok rollback "回滚能力具备"
else
    bad rollback "回滚能力不具备 —— 现在出故障滚不回去"
    printf '%s\n' "$check_out" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- 7. 备份
head_ 备份
# 备份目录**刻意不在生产树里**（见 lib.sh 里 CD_BACKUP_DIR 的注释）：它不会被
# rsync --delete 刷掉，所以这里的判断是「上一次发布留下的东西还在不在」。
if [ ! -d "$CD_BACKUP_DIR" ]; then
    bad backup "还没有任何备份（$CD_BACKUP_DIR 不存在）"
else
    newest="$(ls -1 "$CD_BACKUP_DIR" 2>/dev/null | sort | tail -1 || true)"
    if [ -z "$newest" ]; then
        bad backup "$CD_BACKUP_DIR 是空的 —— 一次备份都没成功过"
    else
        age_days=$(( ( $(date +%s) - $(stat -c '%Y' "$CD_BACKUP_DIR/$newest") ) / 86400 ))
        size="$(du -sh "$CD_BACKUP_DIR/$newest" 2>/dev/null | cut -f1 || echo '?')"
        # 「有 manifest.txt」是「这份备份写完了」的廉价判据。它比看上去重要：
        # 备份被 systemd 从中间砍掉（TimeoutStartSec）或被 OOM 杀掉时留下的半截
        # 目录，在 ls 里和一份真备份长得一模一样，而它会**顶掉**真正最新那一份的
        # 位置 —— 于是「最新备份新鲜吗」这个判断从此建立在一个从来没写成功的
        # 目录上。清单是最后一步才写的（见 backup.sh），所以它在了就是写完了。
        if [ ! -f "$CD_BACKUP_DIR/$newest/manifest.txt" ]; then
            bad backup "$newest 里没有 manifest.txt —— 这是一份**没写完**的备份（被中断过）"
        elif [ "$age_days" -gt "$CD_BACKUP_MAX_AGE_DAYS" ]; then
            bad backup "最新一份是 ${age_days} 天前的（$newest，$size），超过 ${CD_BACKUP_MAX_AGE_DAYS} 天"
        else
            ok backup "最新一份 ${age_days} 天前（$newest，$size）"
        fi

        # 备份**文件本身**还在吗。DB_DUMP 记的是路径，路径没了就等于没有备份 ——
        # 而这件事在状态文件里看不出来（它只是几个字）。
        if [ -f "$CD_STATE_FILE" ]; then
            dump="$(cd_state_get "$CD_STATE_FILE" DB_DUMP || true)"
            if [ -z "$dump" ]; then
                bad backup-pinned "状态文件里没有 DB_DUMP —— 这一版发布的备份坐标丢了"
            elif [ ! -d "$dump" ]; then
                bad backup-pinned "状态文件记的备份 $dump 已经不在了"
            else
                ok backup-pinned "状态文件记的备份还在"
            fi
        fi

        # 外推结果。marker 由 deploy/dr/backup.sh 在推完之后写（见那里为什么
        # 是「推完之后」）。第一行是结论词，第二行起是给人看的原因。
        marker="$CD_BACKUP_DIR/$newest/offsite.status"
        if [ ! -f "$marker" ]; then
            bad offsite "最新备份里没有外推记录 —— 它可能只在本机磁盘上"
        else
            case "$(sed -n '1p' "$marker")" in
                ok)  ok  offsite "$(sed -n '2p' "$marker")" ;;
                *)   bad offsite "$(sed -n '1,4p' "$marker" | tr '\n' ' ')" ;;
            esac
        fi
    fi
fi

echo
if [ "$BAD" -eq 0 ]; then
    printf '\033[32m全部通过\033[0m\n'
else
    printf '\033[31m有问题，见上面的 [FAIL]\033[0m\n'
fi
exit "$BAD"
