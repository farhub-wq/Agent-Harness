#!/usr/bin/env bash
# 本地直推生产（Git Bash / Linux）：本地快速检查 → push GitHub → push 服务器（触发自动构建+部署）。
#
#   bash scripts/push-prod.sh [--skip-checks]
#
# 一次性配置（详见 README「直推发布（日常迭代）」）：
#   git remote add server ssh://root@<部署机IP>/srv/erp-agent.git
#   ~/.ssh/config 里为该 Host 配 IdentityFile（服务器私钥）
#
# 服务器收到 push 后由 post-receive hook 自动完成：构建镜像 → 备份 → 迁移 →
# 影子启动 → 换版 → 观察窗（失败自动回滚）。输出以 remote: 前缀实时回显，全程约 6-8 分钟。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

SKIP=0
[ "${1:-}" = "--skip-checks" ] && SKIP=1

# 只发布已提交的内容：服务器是从裸仓库 git archive 取树的，工作区改动永远上不去 ——
# 让它们「看起来推上去了」会造成本地与生产不一致的假象。
if [ -n "$(git status --porcelain)" ]; then
    echo " !! 工作区有未提交的改动 —— 直推只发布已提交内容。先 commit 或 stash。" >&2
    exit 1
fi

if [ "$SKIP" != "1" ]; then
    # 与 CI python job 同一份配置（pyproject.toml），略去覆盖率与 6 条 unittest 重复项。
    echo "==> 本地快速检查（--skip-checks 可跳过）"
    ruff check .
    python -m compileall -q src
    pytest -q
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "==> push origin $BRANCH（GitHub 保持真相源）"
git push origin "$BRANCH"

echo "==> push server $BRANCH:main（触发服务器构建+部署，输出实时回显）"
git push server "$BRANCH:main"

# post-receive 的退出码不影响 push 本身：push 成功 ≠ 部署成功。部署失败会以
# remote:  !! 开头的行出现在上面的输出里 —— 失败时生产已自动回滚，修复后再推即可。
echo "==> push 完成。部署结果见上方 remote: 输出；查看生产状态：ssh root@<部署机IP> 'bash /root/erp-agent/deploy/cd/status.sh'"
