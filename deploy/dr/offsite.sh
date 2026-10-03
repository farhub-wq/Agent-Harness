#!/usr/bin/env bash
# 把一份备份推到阿里云 OSS。由 deploy/dr/backup.sh 在自检通过之后调用，
# 也可以单独跑（补推、排查）：
#
#   bash deploy/dr/offsite.sh /var/backups/erp-agent/20261003T120000Z-v1.0.0
#
# 为什么需要它：本机备份与生产在**同一块磁盘**上，而生产是一台免费试用的 ECS，
# 到期会被自动释放且数据不保留（deploy/cloud/README.md 自己写的）。也就是说
# 本机备份连「机器还在」都保证不了。
#
# ---------------------------------------------------------------- 凭据
# 从 /etc/erp-agent/backup.env 读（root 0600），与 smoke.env / notify.env 同一个
# 模式：由 root 读、只在本进程里存在。**不经过命令行**——命令行参数会出现在
# 整台机器的 ps 里。所以这里是写一份临时的 ossutil 配置文件（600，用完删），
# 而不是 `ossutil -i AK -k SK`。
#
# ---------------------------------------------------------------- 「没配」与「配了但坏了」
# 这是两件事，处置也不同：
#   文件不存在  → 这是**还没做**那一步设置，响亮地打一行带路径的警告然后放行。
#                 报成失败的话，在用户拿到 AccessKey 之前每一次发布都会被卡住，
#                 而原因是他已知的一件事。
#   配了但失败  → 默认**阻断发布**。外推失败的形态恰好是最安静的（网络抖、
#                 AK 过期、权限被改），如果只是警告，「同盘不是备份」这条就
#                 悄悄失效了，而谁也不会去看那条警告。
#                 BACKUP_OFFSITE_REQUIRED=0 可以显式降级为仅告警。
set -euo pipefail

DR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../cd/lib.sh
source "$DR_DIR/../cd/lib.sh"

OFFSITE_ENV_FILE="${OFFSITE_ENV_FILE:-/etc/erp-agent/backup.env}"
OSSUTIL="${OSSUTIL:-/usr/local/bin/ossutil}"

# 临时文件（含凭据）的清理。**刻意用全局变量 + EXIT trap，而不是函数 local +
# RETURN trap**：`trap 'rm -f "$cfg"' RETURN` 里那个 $cfg 是函数的 local，RETURN
# trap 在 bash 各版本间能不能看见它并无保证，而 set -u 下一个未定义的 $cfg 会让
# trap 本身报错 —— 结果是**带着 AccessKey 的文件留在磁盘上**，恰好是本节开头
# 要避免的事。EXIT 是唯一不会看错作用域的时机。
#
# 覆盖调用方的 EXIT trap 在这里是安全的：offsite.sh 要么被 `bash …/offsite.sh`
# 当成独立进程跑（backup.sh 与 deploy.sh 都这么调），要么只被 source 来取函数
# （文件末尾有 BASH_SOURCE 守卫，source 不会执行 dr_offsite_main）。两条路径下
# 这个进程里都没有别人的 EXIT trap。
DR_OFFSITE_CFG=""
DR_OFFSITE_OUT=""
dr_offsite_cleanup() {
    rm -f "${DR_OFFSITE_CFG:-}" "${DR_OFFSITE_OUT:-}"
    DR_OFFSITE_CFG=""
    DR_OFFSITE_OUT=""
}

# 失败即退出的口子收在一处：required 的判定只写一遍。
dr_offsite_fail() {
    local msg="$1"
    warn "$msg"
    if [ "${BACKUP_OFFSITE_REQUIRED:-1}" = "0" ]; then
        warn "  BACKUP_OFFSITE_REQUIRED=0 —— 只告警，继续发布。"
        warn "  这份备份**只在本机**，磁盘坏掉或被释放时它一起消失。"
        return 0
    fi
    return 1
}

# ossutil 的报错码 → 该去查什么。把 AccessDenied 和 InvalidAccessKeyId 混成
# 一句「外推失败」，等于让人从零开始猜；而这两种原因的处置完全不同。
dr_offsite_hint() {
    local out="$1"
    if grep -q 'InvalidAccessKeyId' "$out"; then
        warn "  AccessKeyId 不存在 —— 多半是填错了，或那个 RAM 子账号已被删。"
    elif grep -q 'SignatureDoesNotMatch' "$out"; then
        warn "  AccessKeySecret 不对（Id 对了但密钥不对）。"
    elif grep -q 'AccessDenied' "$out"; then
        warn "  权限不够。给这个 RAM 子账号的授权必须是**这一个前缀**下的"
        warn "  PutObject / GetObject / ListObjects，只给 bucket 级的只读是不够的。"
    elif grep -q 'NoSuchBucket' "$out"; then
        warn "  bucket 名不对，或 endpoint 的地域与 bucket 所在地域不一致。"
    elif grep -qE 'ConnectTimeout|dial tcp|no such host|connection refused' "$out"; then
        warn "  endpoint 不可达。内网地址（*-internal.aliyuncs.com）**只能从同地域的"
        warn "  阿里云机器上访问** —— 从你的电脑上试是试不通的，那是正常的。"
    fi
    warn "  ossutil 原始输出："
    sed 's/^/      /' "$out" >&2 || true
}

dr_offsite_main() {
    local dir="$1"
    [ -d "$dir" ] || { warn "不是目录：$dir"; return 1; }

    if [ ! -f "$OFFSITE_ENV_FILE" ]; then
        warn "异地备份**未配置**：$OFFSITE_ENV_FILE 不存在。"
        warn "  这份备份只在本机磁盘上；这台机器被释放时它会一起消失，而它是"
        warn "  一台免费试用实例（deploy/cloud/README.md）。"
        warn "  配置步骤见 deploy/dr/README.md（需要你提供 OSS 的 AccessKey）。"
        return 0
    fi

    if [ "$(stat -c '%a' "$OFFSITE_ENV_FILE" 2>/dev/null || echo '')" != "600" ]; then
        warn "$OFFSITE_ENV_FILE 的权限不是 600 —— 里面有 AccessKey。"
        warn "  修：chmod 600 $OFFSITE_ENV_FILE"
    fi

    # 与 smoke.env / notify.env 同一个约定：这是我们自己写的 KEY=VALUE，不含命令替换。
    set -a
    # shellcheck disable=SC1090
    . "$OFFSITE_ENV_FILE"
    set +a

    local missing=""
    for v in OSS_BUCKET OSS_ENDPOINT OSS_AK OSS_SK; do
        [ -n "${!v:-}" ] || missing="$missing $v"
    done
    [ -z "$missing" ] || dr_offsite_fail "$OFFSITE_ENV_FILE 缺:$missing" || return 1

    [ -x "$OSSUTIL" ] || dr_offsite_fail "找不到可执行的 ossutil（$OSSUTIL）。先跑 deploy/dr/ossutil-install.sh" || return 1

    # 前缀两侧的斜杠统一去掉，避免出现 // 或丢失分隔。
    local prefix="${OSS_PREFIX:-erp-agent}"
    prefix="${prefix#/}"; prefix="${prefix%/}"
    local base; base="$(basename "$dir")"
    local remote="oss://${OSS_BUCKET}/${prefix}/${base}"

    # ossutil 的配置文件（600，本进程独享，退出即删）。写在这里而不是
    # ~/.ossutilconfig：后者会让这台机器上**任何**用户跑的 ossutil 都用这份凭据。
    DR_OFFSITE_CFG="$(mktemp)"
    DR_OFFSITE_OUT="$(mktemp)"
    trap dr_offsite_cleanup EXIT
    chmod 600 "$DR_OFFSITE_CFG"
    {
        printf '[Credentials]\n'
        printf 'language=CH\n'
        printf 'endpoint=%s\n' "$OSS_ENDPOINT"
        printf 'accessKeyID=%s\n' "$OSS_AK"
        printf 'accessKeySecret=%s\n' "$OSS_SK"
    } > "$DR_OFFSITE_CFG"

    local cfg="$DR_OFFSITE_CFG"
    local out="$DR_OFFSITE_OUT"
    local rc=0

    log "外推到 $remote"
    # 逐个文件传而不是 cp -r：`cp -r <dir> oss://…/` 到底把目录本身还是目录内容
    # 放上去，两种语义我都不想靠记忆赌 —— 备份目录里只有几个文件，显式列出每个
    # 目标对象既没有歧义，也让失败能精确到是哪一个文件。
    local f n=0
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        info "→ $(basename "$f")"
        if ! "$OSSUTIL" cp -f "$f" "$remote/$(basename "$f")" -c "$cfg" \
                --loglevel=error > "$out" 2>&1; then
            dr_offsite_hint "$out"
            rc=1
            break
        fi
    done

    # 空目录「推成功了」是最没意义的一种成功：远端一个对象都没有，而调用方会
    # 把它当成「异地有一份」。备份目录至少该有 manifest.txt。
    if [ "$n" -eq 0 ]; then
        warn "  $dir 里没有任何文件 —— 不推空目录"
        rc=1
    fi

    # 传完再列一次远端。ossutil cp 成功不等于「东西在正确的前缀下」—— 前缀写错
    # 时它一样会成功，而等到需要恢复的那天才会发现推到了别处。
    if [ "$rc" -eq 0 ]; then
        if ! "$OSSUTIL" ls "$remote/" -c "$cfg" --loglevel=error > "$out" 2>&1; then
            dr_offsite_hint "$out"
            rc=1
        else
            local got
            got="$(grep -c "oss://" "$out" || true)"
            if [ "${got:-0}" -lt "$n" ]; then
                dr_offsite_hint "$out"
                warn "  远端 $remote/ 下只有 ${got:-0} 个对象，本地有 $n 个文件"
                rc=1
            else
                info "远端确认：$remote/（$got 个对象）"
            fi
        fi
    fi

    # 不依赖 EXIT trap 兜底：这一步之后函数还有 return，把凭据文件的存活时间压到
    # 最短。EXIT trap 是给「中途 die / 被 Ctrl-C」那些路径用的。
    dr_offsite_cleanup
    trap - EXIT
    if [ "$rc" -ne 0 ]; then
        dr_offsite_fail "异地备份失败（$remote）" || return 1
    fi
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    [ "$#" -ge 1 ] || { sed -n '2,7p' "$0" >&2; exit 2; }
    [ -n "${CD_ENV:-}" ] || cd_load_env "${CD_ENV_NAME:-production}"
    dr_offsite_main "$1"
fi
