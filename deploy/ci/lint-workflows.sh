#!/usr/bin/env bash
# workflow 守卫：保证 self-hosted runner 永远不会跑到不可信来源的代码。
#
#   bash deploy/ci/lint-workflows.sh
#
# 为什么需要它：self-hosted runner 装在生产机上，而它在事实上等价于 root
#（在 docker 组里，能把宿主任意路径挂进容器）。仓库是 public，任何人的 fork PR
# 都能触发 workflow。所以「PR 触发的 workflow 里不得出现 self-hosted」不是一条
# 优化建议，它是整个安全模型本身 —— 因此必须由代码强制，不能只写进文档。
#
# 三条规则：
#   1) `on:` 里有 pull_request 的文件，全文不得出现 self-hosted
#   2) pull_request_target 一律禁用（它能拿到 secrets 且默认在 base 分支上下文跑）
#   3) 规则 1 沿 `uses: ./.github/workflows/x.yml` **传递** —— 只查直接文件会漏掉
#      真正的洞：ci.yml 自己不写 self-hosted，但把它放进 _gates.yml 一样致命。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WF_DIR=".github/workflows"

warn() { printf '\033[33m !! %s\033[0m\n' "$*" >&2; }
ok()   { printf '    ok  %s\n' "$*"; }

if [ ! -d "$WF_DIR" ]; then
    echo "没有 $WF_DIR，跳过"
    exit 0
fi

# 先剥掉 YAML 注释再做任何匹配。
#
# 必须这么做，而且不是为了好看：文档性注释里几乎必然会提到 "self-hosted"
#（"本文件绝不能出现 self-hosted" 就是最自然的一句），不剥的话守卫会把自己的
# 说明文字判成违规，然后所有人学会的做法是"把那句话删掉"—— 规则还在，解释没了。
# 剥注释让匹配只看**真的会被 GitHub 解析的内容**。
strip_comments() {
    sed 's/#.*$//' "$1"
}

# 取 `on:` 块（含首行）直到下一个顶格行。纯 awk，不依赖 PyYAML —— 这个 job 要
# 尽可能快且无依赖，它是「抓安全漏洞」的那一道，不该因为装包失败而变红。
events_of() {
    strip_comments "$1" | awk '
        /^on:/ { inblock = 1; print; next }
        inblock && /^[^[:space:]]/ { inblock = 0 }
        inblock { print }
    '
}

# 取本文件直接引用的本地可复用 workflow（`uses: ./.github/workflows/x.yml`）。
local_uses_of() {
    strip_comments "$1" | awk '
        match($0, /uses:[[:space:]]*\.\/\.github\/workflows\/[A-Za-z0-9._-]+/) {
            s = substr($0, RSTART, RLENGTH)
            sub(/.*\.github\/workflows\//, "", s)
            print s
        }
    '
}

# 在剥掉注释后的正文里找 self-hosted，行号与原文一致（sed 是逐行处理的）。
self_hosted_hits() {
    strip_comments "$1" | grep -n 'self-hosted' || true
}

rc=0

# ---------------------------------------------------------------- 规则 2
for f in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    if events_of "$f" | grep -q 'pull_request_target'; then
        warn "$f 使用了 pull_request_target —— 本项目禁用（它拿到 secrets 且默认在 base 分支上下文跑，等于给 fork PR 开了后门）"
        rc=1
    fi
done

# ---------------------------------------------------------------- 规则 1 + 3
# 先求出「PR 可达」的 workflow 集合：有 pull_request 触发点的文件，加上它们
# 通过 uses: 直接或间接引用到的本地 workflow。
declare -a queue=() reachable=()

seen_already() {
    local x
    for x in "${reachable[@]}"; do
        [ "$x" = "$1" ] && return 0
    done
    return 1
}

for f in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    if events_of "$f" | grep -q 'pull_request'; then
        queue+=("$(basename "$f")")
    fi
done

while [ ${#queue[@]} -gt 0 ]; do
    cur="${queue[0]}"
    queue=("${queue[@]:1}")
    # 已访问过就跳过（workflow 之间可能互相引用）
    if seen_already "$cur"; then
        continue
    fi
    reachable+=("$cur")

    [ -f "$WF_DIR/$cur" ] || continue
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        queue+=("$dep")
    done < <(local_uses_of "$WF_DIR/$cur")
done

if [ ${#reachable[@]} -eq 0 ]; then
    ok "没有 pull_request 触发的 workflow"
else
    for name in "${reachable[@]}"; do
        f="$WF_DIR/$name"
        if [ ! -f "$f" ]; then
            warn "PR 可达集合里引用了不存在的 workflow：$name"
            rc=1
            continue
        fi
        hits="$(self_hosted_hits "$f")"
        if [ -n "$hits" ]; then
            warn "$f 在 PR 可达集合里，却出现了 self-hosted："
            printf '     %s\n' "$hits" >&2
            warn "   PR 门禁一律跑 ubuntu-latest；self-hosted 只允许出现在 push/dispatch 触发的文件里。"
            rc=1
        else
            ok "$f（PR 可达）没有 self-hosted"
        fi
    done
fi

if [ "$rc" -eq 0 ]; then
    echo "lint-workflows ok"
    exit 0
fi
echo "lint-workflows FAILED" >&2
exit 1
