#!/usr/bin/env bash
# 在生产机上装机内巡检的 systemd 定时器。**幂等**：重复跑只是重新安装并重启
# 那三个 timer，不会重复建任何东西。
#
#   bash deploy/monitor/install-monitor.sh
#
# 装的是三对 service/timer：
#   erp-agent-patrol     每 10 分钟一次巡检，**状态变迁时才发通知**
#   erp-agent-heartbeat  每天一条心跳（含往箱外的死信 ping）
#   erp-agent-backup     每天一次数据库备份（dump + 恢复自检 + 推 OSS）
#
# ---------------------------------------------------------------- 为什么要有定时备份
# 备份原本只在发布时做，于是「最新备份有多旧」等于「上次发布是多久以前」。一台
# 部署完就再没动过的机器，它的备份会一直停在部署那一天 —— 而这台机器是整个
# 方案里唯一一份不可重建的数据的所在地（deploy/cloud/README.md：免费试用实例，
# 到期自动释放且数据不保留）。「备份新鲜度」这条巡检只有在备份与发布解耦之后
# 才是一句有意义的话，所以这对 timer 是巡检那个检查成立的前提，不是附加功能。
#
# ---------------------------------------------------------------- 它不做的事
# 装不了**箱外**的告警：阿里云云监控的站点监控、healthchecks.io 的账号，都要在
# 控制台上注册，脚本碰不到。这里能做的只是把「往哪儿 ping」这个出口留出来
#（notify.env 里的 HEARTBEAT_URL），注册那两下要你自己点。没有箱外那一环，
# 「巡检 timer 被停掉」和「整台机器没了」这两种情况谁都不会收到通知。
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SRC_DIR/../.." && pwd)"
SECRET_DIR=/etc/erp-agent
STATE_DIR=/var/lib/erp-agent

# 单元文件里写死的路径。**必须与 deploy/runner/erp-agent-deploy 的 PROD_ROOT 一致**
#（那个脚本也把它写死成 /root/erp-agent）—— 两台机器上各写一份路径是这个仓库里
# 最容易漂的一处，所以这里把不一致变成一条拒绝安装的断言，而不是让它变成一个
# 「装了但永远不跑」的 timer。那种 timer 的表现是**再也没有任何告警**，而那看
# 起来和「一切正常」一模一样。
UNIT_REPO=/root/erp-agent

UNITS=(
    erp-agent-patrol.service    erp-agent-patrol.timer
    erp-agent-heartbeat.service erp-agent-heartbeat.timer
    erp-agent-backup.service    erp-agent-backup.timer
)
TIMERS=(erp-agent-patrol.timer erp-agent-heartbeat.timer erp-agent-backup.timer)

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m !! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m !! %s\033[0m\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "必须以 root 运行"

for t in systemctl install stat flock curl docker; do
    command -v "$t" >/dev/null 2>&1 || die "缺工具 $t"
done

# ---------------------------------------------------------------- 0. 路径一致性
log "路径一致性"
[ "$REPO_ROOT" = "$UNIT_REPO" ] || die "这份源码树在 $REPO_ROOT，而单元文件里的
     ExecStart 写死的是 $UNIT_REPO/deploy/monitor/patrol.sh。
     两者不一致时装出来的 timer 永远不会成功执行，而失败方式是**静默的**：
     systemd 会记一条失败，但你收到的是「从此没有任何告警」。
     要么把树放到 $UNIT_REPO，要么改 deploy/monitor/*.service 里的路径后重跑。"
info "$REPO_ROOT 与单元文件一致"

# ---------------------------------------------------------------- 1. 状态目录
log "巡检状态目录 $STATE_DIR"
# patrol.last 里只有检查 id 和 OK/FAIL，不是机密，不需要 0700。
# 但它**不能**放在仓库树里：tree 每次发布都被 rsync --delete 刷一遍，状态会跟着
# 没，而状态没了的表现是「下一次巡检认为状态变了」——一条假的恢复告警。
install -o root -g root -m 0755 -d "$STATE_DIR"
info "ok（$(stat -c '%U:%G %a' "$STATE_DIR")）"

# ---------------------------------------------------------------- 2. 单元文件
log "安装 systemd 单元"
for u in "${UNITS[@]}"; do
    [ -f "$SRC_DIR/$u" ] || die "缺 $SRC_DIR/$u"
    install -o root -g root -m 0644 "$SRC_DIR/$u" "/etc/systemd/system/$u"
    info "$u"
done

# 老文档（deploy/runner/README.md 的旧版本）教人手工装过一个
# erp-agent-rbcheck.timer，它做的也是「每 10 分钟跑一次 rollback --check」。
# 两套同时存在的话，回滚能力检查会以两种不同的结论各自告警。
# 这里**只提醒不代劳**：删别人的定时器是破坏性动作，而这个脚本的定位是安装器。
if systemctl list-unit-files 'erp-agent-rbcheck.*' --no-legend 2>/dev/null | grep -q .; then
    warn "检测到旧的 erp-agent-rbcheck.timer —— 它与本脚本装的巡检重复。"
    warn "  它已被 erp-agent-patrol 取代（巡检里包含了回滚能力这一项）。"
    warn "  确认后手工收掉：systemctl disable --now erp-agent-rbcheck.timer"
fi

systemctl daemon-reload
info "daemon-reload 完成"

# ---------------------------------------------------------------- 3. 启用并启动
log "启用定时器"
for t in "${TIMERS[@]}"; do
    systemctl enable "$t" >/dev/null 2>&1 || true
    # restart 而不是 start：重复跑这个脚本时要把改动过的单元重新读进来。
    systemctl restart "$t" || {
        journalctl -u "$t" --no-pager -n 20 >&2 || true
        die "$t 起不来"
    }
    systemctl is-active --quiet "$t" || die "$t 起来了但不是 active"
    printf '    %-28s %s  下次 %s\n' "$t" \
        "$(systemctl is-enabled "$t" 2>/dev/null)" \
        "$(systemctl list-timers "$t" --no-legend 2>/dev/null | awk '{print $1, $2, $3}' | head -1)"
done

# ---------------------------------------------------------------- 4. 告警出口
log "告警出口"
if [ ! -f "$SECRET_DIR/notify.env" ]; then
    warn "没有 $SECRET_DIR/notify.env —— 站内通知会被跳过（不是失败，是**静默**）。"
    warn "  先跑 deploy/runner/install-runner.sh 生成模板，再填 ALERT_WEBHOOK。"
else
    info "$SECRET_DIR/notify.env 在（$(stat -c '%U:%G %a' "$SECRET_DIR/notify.env")）"
    # 只**追加**模板行，不改写整个文件：那个文件里可能已经有 webhook 了，
    # 而「安装脚本把你的配置覆盖掉」是最不能接受的一种 bug。
    if ! grep -q '^HEARTBEAT_URL=' "$SECRET_DIR/notify.env"; then
        cat >>"$SECRET_DIR/notify.env" <<'EOF'

# 死信地址（healthchecks.io 一类的 ping URL）。填了之后 erp-agent-heartbeat
# 每天往它 ping 一次；**该来的 ping 没来，那个服务替你报警**。
# 这是「巡检 timer 被停掉」和「整台机器没了」唯一能被发现的途径 —— 站内通知
# 在这两种情况下恰恰发不出去，而发不出去看起来和「一切正常」没有区别。
# 留空 = 心跳只发站内通知，不出去。
HEARTBEAT_URL=
EOF
        warn "已在 $SECRET_DIR/notify.env 里追加 HEARTBEAT_URL 模板 —— 留空时心跳不出去"
    fi
fi

# ---------------------------------------------------------------- 5. 断言
log "验收断言"

for t in "${TIMERS[@]}"; do
    systemctl is-enabled --quiet "$t" || die "$t 没有 enable（重启后不会自动起）"
    systemctl is-active --quiet "$t"  || die "$t 不是 active"
done
info "三个 timer 都已 enable 且 active"

PERM="$(stat -c '%U:%G %a' /etc/systemd/system/erp-agent-patrol.service)"
[ "$PERM" = "root:root 644" ] || die "unit 的属主/权限是 $PERM，期望 root:root 644"
info "单元文件 root:root 0644"

# 真的跑一遍巡检（--dry-run：不发通知、不写状态文件）。这里**不判它成功还是
# 失败** —— 一台刚装好、栈还没起来的机器，巡检报「七个服务一个都不在」是**正确
# 的**。把它当失败只会让安装脚本在正确的情形下拒绝完成。
# 但输出必须打出来：它是「这个巡检现在看到了什么」的第一手证据，也是唯一能证明
# status.sh 那条链真的跑通了的东西（timer 跑通了不说明它 —— oneshot 成功退出
# 可能只是因为它是空的）。
log "试跑一次巡检（--dry-run，不发通知）"
rc=0
bash "$SRC_DIR/patrol.sh" --dry-run || rc=$?
case "$rc" in
    0) info "巡检链路跑通，结论全绿" ;;
    3) info "巡检链路跑通，本轮跳过（有发布在进行，或有另一轮巡检在跑）" ;;
    *) warn "巡检链路跑通，但结论是「有问题」（退出码 $rc）—— 栈还没起来时这是正常的。" ;;
esac

echo
echo "下一步："
echo "  1. 填告警出口（不填则所有通知被静默跳过）："
echo "       $SECRET_DIR/notify.env  ALERT_WEBHOOK + HEARTBEAT_URL"
echo "  2. 手册：bash deploy/cd/status.sh production   —— 任何时候想知道现在什么样"
echo "      看这一次巡检的结论：cat $STATE_DIR/patrol.last"
echo "      临时静音：systemctl stop erp-agent-patrol.timer（别忘了回来 start）"
echo "  3. **箱外**那两件事脚本做不了，要你在控制台上点："
echo "       阿里云云监控 → 站点监控 → 探 https://<你的域名>/healthz（每 1 分钟，"
echo "         5 分钟无响应告警）—— 它覆盖的是「整台机器没了」，站内通知做不到；"
echo "       healthchecks.io 建一个 check，把它的 ping URL 填进 HEARTBEAT_URL。"
echo "     没有这两条，方案 7.2 的验收标准（5 分钟内告警到群 / 停掉 timer 次日"
echo "     收到死信告警）**没有达到**。机内部分已具备，箱外待注册。"
echo
echo "  注意：本机是免费试用实例，到期自动释放且数据不保留。备份目录"
echo "  /var/backups/erp-agent 与这台机器同生共死 —— 只有推出去的那份不是。"
