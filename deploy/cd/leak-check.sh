#!/usr/bin/env bash
# 密钥泄漏门禁（路径级）。CI 的 secret-scan job 跑它，本地改完 .gitignore 或
# deploy/cd/package.filter 后也应该跑一遍。
#
#   bash deploy/cd/leak-check.sh --tree     检查 git 索引、.gitignore、package.filter
#   bash deploy/cd/leak-check.sh --filter   只检查 package.filter 一条（本地快速迭代用）
#
# 它管的是**路径**：哪些文件绝不该进仓库、绝不该被同步到生产树、以及那两条
# 规则清单有没有退化。内容的模式匹配（API key 长什么样）交给 gitleaks —— 那是
# `.gitleaks.toml` + CI 里单独的一步，两者互补，不要在这里重复实现。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

FILTER="$HERE/package.filter"

warn() { printf '\033[33m !! %s\033[0m\n' "$*" >&2; }
ok()   { printf '    ok  %s\n' "$*"; }

# 这些路径必须被 .gitignore 挡住。断言对**不存在**的路径也生效 —— 规则该在就得
# 在，不能等文件真出现了才发现规则被删了。
#
# 目录要写成「里面某个文件」的形式：.gitignore 里 `deploy/cd/state/` 带尾斜杠
# 只匹配目录，git check-ignore 拿裸目录路径去问是匹配不上的（实测）。
SECRET_PATHS='.env
deploy/.env
deploy/nginx.env
deploy/nginx/htpasswd
deploy/dr/backup.env
deploy/cd/state/production.env
deploy/cd/state/production.prev.env
deploy/ci/.ci-credentials.sh'

# package.filter 里必须存在的排除项。排除清单是安全边界，不能靠人记得。
# 少了任何一条 = 那个文件会被 rsync 同步进生产树。
FILTER_MUST_EXCLUDE='/.env
/.env.*
/deploy/.env
/deploy/nginx.env
/deploy/nginx/htpasswd
/deploy/dr/backup.env
/deploy/cd/state/'

# package.filter 里必须存在的**包含例外**。少了 deploy/.env.example，新机器上的
# bootstrap.sh 就生成不出 deploy/.env，而且报错很难指向根因。
FILTER_MUST_INCLUDE='/.env.example
/deploy/.env.example
/deploy/nginx.env.example'

check_gitignore() {
    local rc=0 f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if git check-ignore -q "$f"; then
            ok "$f 已被 .gitignore 忽略"
        else
            warn "$f **没有**被 .gitignore 忽略（真出现时就会被 commit）"
            rc=1
        fi
    done <<< "$SECRET_PATHS"
    return "$rc"
}

check_tracked() {
    local rc=0 tracked
    # tracked 就等于已经进了历史 —— 此时光删文件没用，必须清历史并轮换密钥，
    # 所以这条要报得严重一点。
    # 这里**刻意不逐个列举文件名**，而是用「任意 .env」这条通配：原先那个
    # `(\.env|nginx\.env|…)` 是枚举，每加一个凭据文件（阶段 5 的 backup.env 就是）
    # 都得记着回来补一行，忘了就静默漏过 —— 而这条规则的失败方式恰恰是「什么都不说」。
    # 通配的代价是偶尔要多写一条 .example 例外，方向是安全的。
    tracked="$(git ls-files \
        | grep -E '(^|/)([^/]*\.env|htpasswd|ca\.key|server\.key)$' \
        | grep -v '\.example$' || true)"
    if [ -n "$tracked" ]; then
        warn "这些密钥/凭据文件已被 git 跟踪（已进历史；删文件不够，要清历史并轮换）："
        printf '     %s\n' $tracked >&2
        rc=1
    else
        ok "git 索引里没有密钥文件"
    fi

    if [ -n "$(git ls-files deploy/cd/state 2>/dev/null || true)" ]; then
        warn "deploy/cd/state 下有被跟踪的文件"
        rc=1
    else
        ok "状态目录未入库"
    fi
    return "$rc"
}

check_filter() {
    local rc=0 f first_excl

    [ -f "$FILTER" ] || { warn "找不到 $FILTER"; return 1; }

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if grep -qxF -- "- $f" "$FILTER"; then
            ok "package.filter 排除 $f"
        else
            warn "package.filter 缺「- $f」—— 该文件会被同步进生产树"
            rc=1
        fi
    done <<< "$FILTER_MUST_EXCLUDE"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if grep -qxF -- "+ $f" "$FILTER"; then
            ok "package.filter 放行 $f"
        else
            warn "package.filter 缺「+ $f」—— bootstrap.sh 生成不出对应的真实文件"
            rc=1
        fi
    done <<< "$FILTER_MUST_INCLUDE"

    # rsync 是「第一条匹配的规则生效」，所以 + 例外必须排在所有 - 之前。
    # 这条最容易在后续编辑里被破坏：往文件开头加一条 - 通配，例外就全失效了，
    # 而且不会有任何报错 —— 只会安静地少同步几个文件。
    first_excl="$(grep -n '^- ' "$FILTER" | head -1 | cut -d: -f1 || true)"
    if [ -n "$first_excl" ]; then
        local bad
        bad="$(grep -n '^+ ' "$FILTER" | cut -d: -f1 | awk -v n="$first_excl" '$1 > n' || true)"
        if [ -n "$bad" ]; then
            warn "package.filter 里第 $(printf '%s' "$bad" | tr '\n' ' ') 行的 + 例外排在第一条 - 规则（第 $first_excl 行）之后，永远不会生效"
            rc=1
        else
            ok "package.filter 的 + 例外都排在 - 规则之前"
        fi
    fi

    return "$rc"
}

case "${1:-}" in
    --tree)
        rc=0
        check_gitignore || rc=1
        check_tracked   || rc=1
        check_filter    || rc=1
        if [ "$rc" -eq 0 ]; then
            echo "leak-check ok"
            exit 0
        fi
        echo "leak-check FAILED" >&2
        exit 1
        ;;
    --filter)
        if check_filter; then
            echo "leak-check ok (package.filter)"
            exit 0
        fi
        echo "leak-check FAILED" >&2
        exit 1
        ;;
    *)
        cat >&2 <<'EOF'
用法：
  bash deploy/cd/leak-check.sh --tree     检查 git 索引、.gitignore、package.filter
  bash deploy/cd/leak-check.sh --filter   只检查 package.filter
EOF
        exit 2
        ;;
esac
