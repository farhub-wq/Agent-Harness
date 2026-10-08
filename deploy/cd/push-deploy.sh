#!/usr/bin/env bash
# 直推部署的编排：由裸仓库 /srv/erp-agent.git 的 post-receive hook 调用（hook 模板
# 在 deploy/cloud/post-receive.hook），把刚推到裸仓库的 <sha> 构建成镜像并发布到生产。
#
#   push-deploy.sh <40位sha>
#
# 与 deploy.yml 流水线共用同一发布入口（deploy.sh deploy production），运行时安全链
# 一个不少：备份 → 迁移 → 同步源码树 → 影子启动 → 换版 → 观察窗 → 失败自动回滚。
# 直推绕过的只是 PR 门禁与人工审批（由本地 push-prod 脚本的快速检查替代），不是这些。
#
# 注意：hook 执行的是**生产树**里的本文件（/root/erp-agent/deploy/cd/…）。本次推送
# 对本文件自身的改动要从下一次推送才生效 —— 与 deploy.sh 的语义一致：在跑的发布永远
# 由旧版脚本完成（rsync 写临时文件再 rename，正在跑的 bash 持有旧文件描述符，不受影响）。
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# post-receive 的环境里 GIT_DIR=.（相对路径）指向裸仓库。不 unset 的话，子进程里
# 所有 git -C <目录> 都会被它劫持：-C 只改工作目录，GIT_DIR 环境变量仍然生效，
# 于是「在构建 clone 里 checkout」变成「在裸仓库上 checkout」，报错还很绕。
unset GIT_DIR GIT_QUARANTINE_PATH

# build.sh 必须在 git 工作树里跑（它读 git 历史算变更集），而生产树不是 git 仓库。
# 构建 clone 是裸仓库在本机的一个普通 clone，一次性建好（见 README「直推发布」）。
BUILD_CLONE="${PUSH_BUILD_CLONE:-/srv/erp-agent-build}"

SHA="${1:-}"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "用法：push-deploy.sh <40位sha>"
SHA12="${SHA:0:12}"

# 与发布锁是两把：这里防的是两次 push 撞同一个构建 clone（checkout -f 互相踩）；
# 生产换版的互斥由 deploy.sh 自己的 CD_LOCK_FILE 管。
exec 201>/var/lock/erp-agent-push-deploy.lock
flock -n 201 || die "另一次直推部署正在跑，等它结束再推"

cd_assert_repo_has "$SHA" || die "裸仓库 $CD_IMAGE_REPO 里没有 $SHA —— push 没成功？"

# 深链路冒烟凭据（SMOKE_BASIC_USER/PASSWORD）。文件 root 600，hook 走 ssh root
# 进来所以可读；没有它 deploy.sh 只探免认证端点并告警（前端与 /api 链路未验证）。
if [ -f /etc/erp-agent/smoke.env ]; then
    set -a; . /etc/erp-agent/smoke.env; set +a
fi

log "构建工作树就位：$BUILD_CLONE @ $SHA12"
[ -d "$BUILD_CLONE/.git" ] \
    || die "找不到构建 clone $BUILD_CLONE —— 先建：git clone $CD_IMAGE_REPO $BUILD_CLONE"
git -C "$BUILD_CLONE" fetch --tags origin
git -C "$BUILD_CLONE" checkout -f "$SHA"

# build.sh 要求 <version> 是**本地存在且指向 HEAD** 的 tag（它拿 ${VERSION}^ 找上一个
# v* tag 算变更集）。push-head 是只存在于构建 clone 的移动 tag，不推任何远程；
# 镜像同时被打上 push-head 与 sha-<12> 两个 tag，发布只用不可变的后者。
git -C "$BUILD_CLONE" tag -f push-head "$SHA" >/dev/null
bash "$BUILD_CLONE/deploy/cd/build.sh" push-head

log "发布：deploy.sh deploy production sha-$SHA12"
DEPLOYED_BY="git-push" bash "$CD_LIB_DIR/deploy.sh" deploy production "sha-$SHA12" "$SHA"
