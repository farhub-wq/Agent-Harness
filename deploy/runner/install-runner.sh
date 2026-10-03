#!/usr/bin/env bash
# 在生产机上装一个 GitHub self-hosted runner，并把发布闸门、systemd 资源护栏、
# 带限额的 buildx builder 一起装好。**幂等**：重复跑不会重复注册。
#
#   RUNNER_TOKEN=<注册令牌> bash deploy/runner/install-runner.sh
#
# 注册令牌从 GitHub 取，一小时有效：
#   curl -X POST -H "Authorization: Bearer <token>" \
#     https://api.github.com/repos/farhub-wq/Agent-Harness/actions/runners/registration-token
# 已经注册过的机器（$RUNNER_HOME/actions-runner/.runner 存在）不带令牌重跑即可，
# 会跳过注册、只更新闸门/限额并重启服务。
#
# 可选环境变量：
#   RUNNER_VERSION   默认 2.337.0（钉版本，不自动跟最新）
#   RUNNER_NAME      默认 erp-agent-prod
#   RUNNER_LABELS    默认 erp-agent-prod
#   RUNNER_SHA256    可选：tarball 的 sha256。不传则首次安装记录、后续比对（TOFU）
#   RUNNER_TARBALL   本地 tarball 路径，给了就跳过下载
#   INSTALL_GH=1     顺带装 gh（默认 0：工作流不用它，生产机上少一个二进制）
#
# RUNNER_TARBALL 为什么存在（2026-10-03 真机实测）：这台机器**拉不动
#   github.com/actions/runner/releases/download/***（000 / 15s 超时），而
#   api.github.com 是 200 / 0.3s、codeload.github.com 是 200 / 1.0s。所以
#   「run 得起来」和「runner 装得上」依赖的是不同的主机：工作流的 checkout 与
#   action 下载走 api/codeload（通），只有 runner 自己的发布产物那条路被挡。
#   处置：在能上网的机器上 curl 下来，scp 上去，用这个变量指过来。
#
# 安全的全部前提只有一条：**这个 runner 永远不执行不可信来源的代码**。
# 它由 deploy/ci/lint-workflows.sh 强制，不是由本脚本强制。
set -euo pipefail

REPO_SLUG="${REPO_SLUG:-farhub-wq/Agent-Harness}"
RUNNER_NAME="${RUNNER_NAME:-erp-agent-prod}"
RUNNER_LABELS="${RUNNER_LABELS:-erp-agent-prod}"
RUNNER_VERSION="${RUNNER_VERSION:-2.337.0}"
RUNNER_USER="${RUNNER_USER:-ghrunner}"
RUNNER_HOME="/home/${RUNNER_USER}"
RUNNER_DIR="${RUNNER_HOME}/actions-runner"
SECRET_DIR=/etc/erp-agent
WRAPPER_DST=/usr/local/sbin/erp-agent-deploy
SUDOERS_DST=/etc/sudoers.d/ghrunner
INSTALL_GH="${INSTALL_GH:-0}"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m !! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m !! %s\033[0m\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "必须以 root 运行"

for t in docker curl tar install visudo systemctl runuser; do
    command -v "$t" >/dev/null 2>&1 || die "缺工具 $t"
done

# ---------------------------------------------------------------- 1. 用户
log "运行用户 $RUNNER_USER"
if id "$RUNNER_USER" >/dev/null 2>&1; then
    info "已存在"
else
    useradd --system --create-home --home-dir "$RUNNER_HOME" \
            --shell /bin/bash --comment "GitHub Actions self-hosted runner" "$RUNNER_USER"
    info "已创建"
fi
# docker 组 = 事实上的 root（能把宿主任意路径挂进容器）。方案承认这一点，
# 换来的是发布不必再经过一层别的编排。前提仍是「这个 runner 不跑 fork 的代码」。
usermod -aG docker "$RUNNER_USER"
info "已在 docker 组：$(id -nG "$RUNNER_USER")"

# ---------------------------------------------------------------- 2. 发布闸门
log "安装发布闸门 $WRAPPER_DST"
# -o root -g root -m 0755：**ghrunner 必须不可写**。它能写这个文件就等于
# 拥有一切（sudoers 那条规则指的是这个路径，内容由谁决定才是关键）。
install -o root -g root -m 0755 "$SRC_DIR/erp-agent-deploy" "$WRAPPER_DST"
info "ok（$(stat -c '%U:%G %a' "$WRAPPER_DST")）"

log "安装 sudoers 规则 $SUDOERS_DST"
install -o root -g root -m 0440 "$SRC_DIR/ghrunner.sudoers" "$SUDOERS_DST"
visudo -cf "$SUDOERS_DST" >/dev/null || { rm -f "$SUDOERS_DST"; die "sudoers 语法检查失败，已回滚该文件"; }
info "ok（visudo -c 通过）"

# ---------------------------------------------------------------- 3. 生产密钥目录
log "生产密钥目录 $SECRET_DIR"
install -o root -g root -m 0700 -d "$SECRET_DIR"

if [ ! -f "$SECRET_DIR/smoke.env" ]; then
    install -o root -g root -m 0600 /dev/null "$SECRET_DIR/smoke.env"
    cat >"$SECRET_DIR/smoke.env" <<'EOF'
# 换版后冒烟的 Basic Auth 凭据（deploy/cd/lib.sh 的 cd_smoke 用）。
# 不填的症状是：发布脚本明确告警「前端与 /api 链路**未验证**」，只探
# /healthz 与 /health。那两个端点探活全绿从来不足以说明代理链路是好的
#（阶段 3-B 的坏 PR #5 就是这么放过去的）。
#
# 用户名/密码必须与 deploy/nginx/htpasswd 里的一条一致。
SMOKE_BASIC_USER=admin
SMOKE_BASIC_PASSWORD=
EOF
    warn "已生成 $SECRET_DIR/smoke.env 模板 —— 请把 SMOKE_BASIC_PASSWORD 填上（与 htpasswd 一致）"
fi

if [ ! -f "$SECRET_DIR/notify.env" ]; then
    install -o root -g root -m 0600 /dev/null "$SECRET_DIR/notify.env"
    cat >"$SECRET_DIR/notify.env" <<'EOF'
# 发布通知通道。由 deploy/cd/notify.sh 读取；不填则通知被跳过（不是失败）。
# ALERT_KIND: feishu | wecom | dingtalk | serverchan | generic-webhook
ALERT_KIND=feishu
ALERT_WEBHOOK=
# 飞书机器人开启「签名校验」时填这里；用关键词/免签则留空。
FEISHU_SECRET=
EOF
    warn "已生成 $SECRET_DIR/notify.env 模板 —— 请填 ALERT_WEBHOOK"
fi
info "ok"

# ---------------------------------------------------------------- 4. runner 本体
log "actions-runner v$RUNNER_VERSION"
mkdir -p "$RUNNER_DIR"
chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR" "$RUNNER_HOME"

TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"
SHA_RECORD="$SECRET_DIR/runner-${RUNNER_VERSION}.sha256"

if [ -x "$RUNNER_DIR/config.sh" ] && [ -f "$RUNNER_DIR/.runner" ]; then
    info "已注册过（$RUNNER_DIR/.runner 存在），跳过下载与注册"
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    if [ -n "${RUNNER_TARBALL:-}" ]; then
        # 见脚本头部：这台机器拉不到 releases/download/*，tarball 由人工 scp 上来。
        # 这里只校验它不是个空文件 —— 内容的可信度由下面的 sha256 那一关负责。
        [ -s "$RUNNER_TARBALL" ] || die "RUNNER_TARBALL=$RUNNER_TARBALL 不存在或为空"
        info "用本地 tarball $RUNNER_TARBALL（跳过下载）"
        cp -- "$RUNNER_TARBALL" "$TMP/$TARBALL"
    else
        info "下载 $URL"
        curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/$TARBALL" "$URL"
    fi

    GOT_SHA="$(sha256sum "$TMP/$TARBALL" | cut -d' ' -f1)"
    if [ -n "${RUNNER_SHA256:-}" ]; then
        [ "$GOT_SHA" = "$RUNNER_SHA256" ] \
            || die "runner tarball sha256 不符：期望 $RUNNER_SHA256，实际 $GOT_SHA"
        info "sha256 校验通过（按 RUNNER_SHA256）"
    elif [ -f "$SHA_RECORD" ]; then
        [ "$GOT_SHA" = "$(cat "$SHA_RECORD")" ] \
            || die "runner tarball sha256 与上次记录的不符：期望 $(cat "$SHA_RECORD")，实际 $GOT_SHA。
    要么是上游重新发布了同版本（危险），要么是下载被篡改。查清之前不要继续。"
        info "sha256 与上次记录一致"
    else
        # GitHub 不给 actions/runner 的 tarball 附 .sha256，只能 TOFU。
        # 至少把值记下来，让**下一次**安装能发现变化。
        printf '%s\n' "$GOT_SHA" > "$SHA_RECORD"
        chmod 0600 "$SHA_RECORD"
        warn "首次安装：已记录 sha256=$GOT_SHA 到 $SHA_RECORD（TOFU，下次安装会比对）"
    fi

    info "解包到 $RUNNER_DIR"
    tar -xzf "$TMP/$TARBALL" -C "$RUNNER_DIR"
    chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

    [ -n "${RUNNER_TOKEN:-}" ] \
        || die "需要 RUNNER_TOKEN（注册令牌，一小时有效）。见脚本头部注释。"

    info "注册到 $REPO_SLUG（name=$RUNNER_NAME labels=$RUNNER_LABELS）"
    runuser -u "$RUNNER_USER" -- env HOME="$RUNNER_HOME" \
        "$RUNNER_DIR/config.sh" \
            --url "https://github.com/$REPO_SLUG" \
            --token "$RUNNER_TOKEN" \
            --name "$RUNNER_NAME" \
            --labels "$RUNNER_LABELS" \
            --work _work \
            --unattended --replace
    # 令牌用完就不再留在磁盘上。
    unset RUNNER_TOKEN
fi

# ---------------------------------------------------------------- 5. systemd 服务
log "systemd 服务"
cd "$RUNNER_DIR"
./svc.sh install "$RUNNER_USER" >/dev/null

UNIT_FILE="$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1 || true)"
[ -n "$UNIT_FILE" ] || die "svc.sh install 之后找不到 actions.runner.*.service"
UNIT="$(basename "$UNIT_FILE")"
info "unit = $UNIT"

# 资源护栏挂在**服务**上（drop-in），不是挂在 docker build 上 —— 后者会被
# BuildKit 忽略。注意这个 slice 管不到构建步骤的容器，那部分由 setup-builder.sh
# 建的带限额 builder 负责，两个都要有。
install -o root -g root -m 0755 -d "/etc/systemd/system/${UNIT}.d"
install -o root -g root -m 0644 "$SRC_DIR/runner-limits.conf" \
    "/etc/systemd/system/${UNIT}.d/limits.conf"
systemctl daemon-reload
info "已装 drop-in：/etc/systemd/system/${UNIT}.d/limits.conf"

systemctl enable "$UNIT" >/dev/null 2>&1 || true
systemctl restart "$UNIT"
sleep 2
systemctl is-active --quiet "$UNIT" || {
    journalctl -u "$UNIT" --no-pager -n 30 >&2 || true
    die "$UNIT 没起来"
}
info "服务在跑：$(systemctl is-active "$UNIT")"

# ---------------------------------------------------------------- 6. 带限额的 builder
log "带资源限额的 buildx builder"
bash "$SRC_DIR/setup-builder.sh"

# ---------------------------------------------------------------- 7. gh（可选）
if [ "$INSTALL_GH" = "1" ]; then
    log "安装 gh"
    GH_VERSION="${GH_VERSION:-2.102.0}"
    TMP2="$(mktemp -d)"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP2/gh.tar.gz" \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP2/checksums.txt" \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt"
    ( cd "$TMP2" && grep "gh_${GH_VERSION}_linux_amd64.tar.gz" checksums.txt | sha256sum -c - ) \
        || die "gh tarball 校验失败"
    tar -xzf "$TMP2/gh.tar.gz" -C "$TMP2"
    install -o root -g root -m 0755 "$TMP2/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh
    rm -rf "$TMP2"
    info "gh $(/usr/local/bin/gh --version | head -1)"
else
    info "跳过 gh（INSTALL_GH=0；工作流不需要它）"
fi

# ---------------------------------------------------------------- 8. 断言
log "验收断言"

PERM="$(stat -c '%U:%G %a' "$WRAPPER_DST")"
[ "$PERM" = "root:root 755" ] || die "$WRAPPER_DST 的属主/权限是 $PERM，期望 root:root 755"
info "闸门 root:root 0755，$RUNNER_USER 不可写"

visudo -cf "$SUDOERS_DST" >/dev/null || die "sudoers 校验失败"
info "sudoers 合法"

# 真的用 ghrunner 走一遍 sudo：sudoers 只写了「允许」，跑得通才算数。
OUT="$(runuser -u "$RUNNER_USER" -- sudo -n "$WRAPPER_DST" help 2>&1)" \
    || die "ghrunner 通过 sudo 调不起闸门：$OUT"
info "ghrunner 可以执行闸门（sudo -n 免密通过）"

# 反向：闸门必须挡住形状不对的参数，否则白名单只是"一个 root shell 的别名"。
if runuser -u "$RUNNER_USER" -- sudo -n "$WRAPPER_DST" deploy production 'x; rm -rf /' aaaa >/dev/null 2>&1; then
    die "闸门接受了非法 tag —— 参数校验没生效"
fi
info "闸门拒绝了非法参数"

[ -f "$RUNNER_DIR/.runner" ] || die "runner 未注册（$RUNNER_DIR/.runner 不存在）"
info "runner 已注册"

echo
echo "下一步（按顺序）："
echo "  1. GitHub → Settings → Actions → Runners，确认 $RUNNER_NAME 是 Idle；"
echo "  2. 填生产密钥（不填也能发，但会少验一层）："
echo "       $SECRET_DIR/smoke.env   SMOKE_BASIC_PASSWORD（要与 deploy/nginx/htpasswd 一致）"
echo "       $SECRET_DIR/notify.env  ALERT_WEBHOOK"
echo "  3. dispatch build.yml —— 这是唯一能证明"长轮询真的连上了"的动作，"
echo "     开 PR 证明不了：PR 门禁跑在 GitHub 自己的机器上，不碰这台 runner。"
