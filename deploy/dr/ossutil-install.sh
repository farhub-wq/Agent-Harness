#!/usr/bin/env bash
# 在生产机上装 ossutil。**一次性的人工动作**，像 deploy/runner/install-runner.sh。
#
#   sudo bash deploy/dr/ossutil-install.sh
#
# 为什么不用官方那条一键命令（curl … | bash）：
# 它把「下载什么」和「执行什么」合成一步，于是两者都不可复现 —— 今天装的是
# 1.7.19，明天可能是别的版本，而没有任何东西会告诉你变了。这里写死版本、写死
# sha256，对不上就**不装**。这个脚本是往 root 的 PATH 里放一个二进制，值得多
# 这一道。
#
# 校验和的来源：官方安装页
#   https://help.aliyun.com/zh/oss/developer-reference/install-ossutil
# 上面 Linux x86 64bit 那一行是 dcc512e4…。**这个值我下载了实物核对过**
# （12277610 字节，sha256sum 与页面一致），不是从网页文字里抄来的 —— 抄错一个
# 字符的后果是这台机器永远装不上，而报错看起来像"网络问题"。
set -euo pipefail

OSSUTIL_VERSION="1.7.19"
ARCH="linux-amd64"
ZIP="ossutil-v${OSSUTIL_VERSION}-${ARCH}.zip"
URL="https://gosspublic.alicdn.com/ossutil/${OSSUTIL_VERSION}/${ZIP}"
SHA256="dcc512e4a893e16bbee63bc769339d8e56b21744fd83c8212a9d8baf28767343"
DEST="/usr/local/bin/ossutil"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m !! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m !! %s\033[0m\n' "$1" >&2; exit "${2:-1}"; }

[ "$(id -u)" -eq 0 ] || die "要用 root 跑：它会往 /usr/local/bin 里放一个二进制，而且装完只有 root 用得上"

# 幂等。--version 的输出形如 "ossutil version 1.7.19 (go1.20)"。
if [ -x "$DEST" ]; then
    have="$("$DEST" --version 2>/dev/null | head -1 || true)"
    case "$have" in
        *"$OSSUTIL_VERSION"*)
            info "已经装好了：$have"
            exit 0
            ;;
        *)
            warn "已存在 $DEST 但版本不是 $OSSUTIL_VERSION：$have"
            warn "  非交互环境不能覆盖它，请手工确认后删除再重跑"
            exit 1
            ;;
    esac
fi

for t in curl unzip sha256sum; do
    command -v "$t" >/dev/null 2>&1 || die "缺 $t（apt-get install -y $t）"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "下载 ossutil ${OSSUTIL_VERSION}（${ARCH}）"
info "$URL"
curl -sSL --fail --max-time 300 -o "$TMP/$ZIP" "$URL" \
    || die "下载失败。这台机器到 gosspublic.alicdn.com 通不通？" 2

log "校验 sha256"
got="$(sha256sum "$TMP/$ZIP" | cut -d' ' -f1)"
if [ "$got" != "$SHA256" ]; then
    warn "校验和不符，拒绝安装。"
    warn "  期望 $SHA256"
    warn "  实际 $got"
    warn "  可能是下载被截断、中间有代理改过内容，或这个版本号下的文件变了。"
    die "不要绕过这一步" 3
fi
info "$got ✓"

log "解包并安装到 $DEST"
unzip -q -o "$TMP/$ZIP" -d "$TMP"
BIN="$TMP/ossutil-v${OSSUTIL_VERSION}-${ARCH}/ossutil64"
[ -f "$BIN" ] || die "包里的路径变了（期望 ossutil-v${OSSUTIL_VERSION}-${ARCH}/ossutil64），检查解包结果"
install -o root -g root -m 0755 "$BIN" "$DEST"

log "验证"
"$DEST" --version || die "装上去了但跑不起来"
info "OK：$DEST"
info "下一步：把 OSS 凭据写进 /etc/erp-agent/backup.env（root 0600），格式见 deploy/dr/README.md"
