#!/usr/bin/env bash
# 只读巡检。给 systemd timer / 运维人用，绝不修改任何状态。
#
#   bash deploy/cd/status.sh [production]
#   echo $?     # 0 = 全绿，1 = 有问题
#
# 它回答四个问题：
#   1) 七个服务都在跑且 healthy 吗
#   2) 跑着的镜像和 state 文件记的是同一版吗（不一致 = 有人绕过脚本手工 up）
#   3) 磁盘还够吗
#   4) 回滚能力还具备吗（prev 快照 + 旧镜像 + 源码树都还在吗）
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd_load_env "${1:-production}"

BAD=0
ok()   { printf '\033[32m[OK]\033[0m   %s\n' "$*"; }
bad()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; BAD=1; }
note() { printf '       %s\n' "$*"; }

# ---------------------------------------------------------------- 1. 服务
echo "== 服务 =="
if ! docker info >/dev/null 2>&1; then
    bad "docker daemon 不可达"
else
    # 一次性服务 sandbox-image-loader 跑完就退出，不算异常。
    ps_out="$(cd_compose ps --all --format '{{.Service}}\t{{.Image}}\t{{.State}}\t{{.Health}}' 2>/dev/null || true)"
    [ -n "$ps_out" ] || bad "拿不到 compose 服务列表（project=$PROJECT）"

    expected="mongo dind mock-erp mcp backend frontend nginx"
    while IFS=$'\t' read -r svc img state health; do
        case "$svc" in sandbox-image-loader|"") continue ;; esac
        expected="$(printf '%s\n' $expected | grep -vx "$svc" | tr '\n' ' ')"
        if [ "$state" = "running" ] && [ "$health" = "healthy" ]; then
            ok "$svc healthy（$img）"
        else
            bad "$svc state=$state health=${health:-none}（$img）"
        fi
    done <<< "$ps_out"

    leftover="$(printf '%s' "$expected" | tr -d ' ')"
    [ -z "$leftover" ] || bad "缺服务：$leftover"
fi

# ---------------------------------------------------------------- 2. 版本一致性
echo
echo "== 版本一致性 =="
if [ ! -f "$CD_STATE_FILE" ]; then
    bad "没有状态文件 $CD_STATE_FILE（这台机器还没被 deploy.sh 接管过）"
else
    note "$(grep -E '^(VERSION|GIT_SHA|DEPLOYED_AT|DEPLOYED_BY)=' "$CD_STATE_FILE" | tr '\n' ' ')"

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
        ok "四个换版服务的运行 digest 与 state 一致"
    else
        bad "运行中的镜像 digest 与 state 不一致 —— 有人绕过脚本手工换过版？"
        diff <(printf '%s\n' "$want") <(printf '%s\n' "$running") | sed 's/^/       /' >&2 || true
    fi

    # 引用完整性：state 记的 digest 必须还是本机那个 tag 现在指着的那个
    #（tag 可以被重新指向，digest 不能）。
    for key in APP_IMAGE:APP_IMAGE_ID FRONTEND_IMAGE:FRONTEND_IMAGE_ID MOCK_ERP_IMAGE:MOCK_ERP_IMAGE_ID; do
        ref="$(cd_state_get "$CD_STATE_FILE" "${key%%:*}" || true)"
        id="$(cd_state_get "$CD_STATE_FILE" "${key##*:}" || true)"
        [ -n "$ref" ] && [ -n "$id" ] || continue
        now="$(cd_image_id "$ref")"
        [ "$now" = "$id" ] || bad "$ref 的 digest 变了（state=$id 现在=${now:-缺失}）"
    done
fi

# ---------------------------------------------------------------- 3. 半途发布
echo
echo "== 半途发布 =="
if [ -f "$CD_PENDING_FILE" ]; then
    bad "存在 $CD_PENDING_FILE —— 有一次发布卡在半途没走完，需要人工确认"
    note "$(grep -E '^(VERSION|GIT_SHA|DEPLOYED_AT)=' "$CD_PENDING_FILE" | tr '\n' ' ')"
else
    ok "没有 pending 残留"
fi

# ---------------------------------------------------------------- 4. 共享密钥
echo
echo "== 共享密钥 =="
a="$(sed -n 's/^INTERNAL_AUTH_TOKEN=//p' "$CD_REPO_ROOT/deploy/.env" 2>/dev/null | head -1 | tr -d '"'"'"'')"
b="$(sed -n 's/^INTERNAL_AUTH_TOKEN=//p' "$CD_REPO_ROOT/deploy/nginx.env" 2>/dev/null | head -1 | tr -d '"'"'"'')"
if [ -z "$a" ] || [ -z "$b" ]; then
    bad "INTERNAL_AUTH_TOKEN 缺失（.env='${a:+有}' nginx.env='${b:+有}'）—— 共享密钥校验是关的"
elif [ "$a" = "$b" ]; then
    ok "两处一致（len=${#a}，前 4 位 ${a:0:4}…）"
else
    bad "两处不一致 —— /health 会 200 但所有 /api 会 401。跑 sh deploy/set_internal_token.sh"
fi

# ---------------------------------------------------------------- 5. 磁盘
echo
echo "== 磁盘 =="
avail="$(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -z "$avail" ]; then
    note "读不出 /var/lib/docker 可用空间"
elif [ "$avail" -lt 8 ]; then
    bad "docker 分区可用 ${avail}G < 8G —— 下次发布可能中途失败"
else
    ok "docker 分区可用 ${avail}G"
fi

# ---------------------------------------------------------------- 6. 回滚能力
echo
echo "== 回滚能力 =="
# 只跑一次，把它的输出留着在失败时展示（跑两次会让前置检查打两遍）。
if check_out="$(bash "$CD_LIB_DIR/deploy.sh" rollback "$CD_ENV" --check 2>&1)"; then
    ok "回滚能力具备"
else
    bad "回滚能力不具备 —— 现在出故障滚不回去"
    printf '%s\n' "$check_out" | sed 's/^/       /'
fi

echo
if [ "$BAD" -eq 0 ]; then
    printf '\033[32m全部通过\033[0m\n'
else
    printf '\033[31m有问题，见上面的 [FAIL]\033[0m\n'
fi
exit "$BAD"
