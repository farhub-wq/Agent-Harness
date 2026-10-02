#!/usr/bin/env bash
# CI 集成 job 的共享库 —— 被 smoke-edge.sh / stack-smoke.sh source。
# 只定义函数与常量，**刻意不设 set -e**（与 deploy/cd/lib.sh 同一个约定：
# source 一个库不该悄悄改变调用方的错误处理策略）。
#
# 为什么这些断言是脚本而不是 workflow 里的 run: 块 ——
#   阶段 2 的教训：那两个只有真机才发现的问题（坏版本停机窗口 260s→134s、
#   把 up -d 放后台导致判在旧容器上的竞态）都是靠「能在命令行单独重跑」定位的。
#   塞进 YAML 的断言只能在 CI 上盲目迭代，一次 push 换一个观测点。

CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_REPO_ROOT="$(cd "$CI_LIB_DIR/../.." && pwd)"

# 项目名必须与 docker-compose.yml 的 `name:` 一致 —— 网络名会变成 erp-agent_edge，
# 下面直连 backend 的探针要按这个名字找网络。
CI_PROJECT="${CI_PROJECT:-erp-agent}"

ci_log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ci_info() { printf '    %s\n' "$*"; }
ci_warn() { printf '\033[33m !! %s\033[0m\n' "$*" >&2; }
ci_die()  { printf '\033[31m !! %s\033[0m\n' "$1" >&2; exit "${2:-1}"; }

# 所有 compose 调用都走这里。CI_OVERRIDE 非空时叠一层覆盖文件（auth-path 用
# deploy/ci/compose.ci.yml 替掉 dind / sandbox-image-loader）；stack-smoke 不设它，
# 跑的就是完整拓扑 —— 那正是那个 job 存在的意义。
#
# 这里**故意没有** deploy/cd/lib.sh 里那套禁用 down/prune 的包装：CI 的栈是一次性
# 的，job 结束整个 VM 就没了，prune 不会毁掉任何人的回滚能力。
ci_compose() {
    local -a files=(-f "$CI_REPO_ROOT/docker-compose.yml")
    if [ -n "${CI_OVERRIDE:-}" ]; then
        files+=(-f "$CI_REPO_ROOT/$CI_OVERRIDE")
    fi
    ( cd "$CI_REPO_ROOT" && docker compose -p "$CI_PROJECT" "${files[@]}" "$@" )
}

# 起栈。--no-build：镜像要么由 workflow 用 buildx 预建（带 GHA 层缓存），要么由
# 调用方先 ci_build。这里再 build 一次会丢掉缓存、白等几分钟。
#
# **刻意不用 `up --wait`**：deploy/cd/lib.sh 里记过这个坑 —— 各版本对一次性服务
# （sandbox-image-loader）的 --wait 语义不一致，2.x 早期一个「退出码 0 的一次性
# 容器」会被判成失败。健康判据统一由 ci_wait_healthy 做，只有一处。
#
# 也**刻意不把 up 放后台**：阶段 2 实测过，只等健康不等 up 返回，会判在换版前那批
# 还 healthy 的旧容器上，于是"部署成功"而新容器根本没起来。
ci_up() {
    ci_compose up -d --no-build
}

ci_build() {
    ci_compose build "$@"
}

# 健康轮询。判据与 deploy/cd/lib.sh 的 cd_wait_healthy 一致：
#   - 除了 sandbox-image-loader，其余服务必须 healthy（--all 才能看到退出的容器）
#   - 列表为空视为未就绪（不能把"什么都没起来"当成"没有不健康的"）
ci_wait_healthy() {
    local deadline="${1:-420}"
    local end=$((SECONDS + deadline))
    local line bad

    while [ "$SECONDS" -lt "$end" ]; do
        line="$(ci_compose ps --all --format '{{.Service}} {{.Health}}' 2>/dev/null || true)"
        bad="$(printf '%s\n' "$line" \
            | grep -v '^sandbox-image-loader' \
            | grep -vE 'healthy$' \
            | grep -c . || true)"
        if [ "$bad" -eq 0 ] && [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ]; then
            ci_compose ps --format 'table {{.Service}}\t{{.Status}}'
            return 0
        fi
        sleep 5
    done

    ci_warn "健康检查超时（${deadline}s）"
    ci_compose ps --all --format 'table {{.Service}}\t{{.State}}\t{{.Health}}' >&2 || true
    return 1
}

# 诊断落盘。失败时把栈的状态与全量日志留下来 —— 这是 CI 上唯一能事后复盘的东西。
ci_dump() {
    local out="${1:-/tmp/erp-agent-ci-diagnostics}"
    mkdir -p "$out"
    ci_warn "诊断信息落盘到 $out"
    ci_compose ps --all > "$out/ps.txt" 2>&1 || true
    ci_compose logs --no-color --timestamps > "$out/logs.txt" 2>&1 || true
    ci_compose config > "$out/resolved-compose.yml" 2>&1 || true
    printf '%s\n' "$(ci_compose ps --all --format 'table {{.Service}}\t{{.State}}\t{{.Health}}' 2>&1 || true)" >&2
}

# 单次请求的状态码。网络层失败（连不上、超时）统一变成 000，让调用方与
# "收到了响应但状态码不对"区分开 —— curl 自己会因为 -f 之类的东西退出非 0，
# 在 set -e 的脚本里直接杀掉进程，那不是我们想要的失败形态。
ci_http_code() {
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@" 2>/dev/null || true)"
    printf '%s' "${code:-000}"
}

# awk 就地改/追加一个 KEY=VALUE。比 sed -i 可移植（GNU/BSD 语法不同），
# 与 deploy/set_internal_token.sh 的 write_var 是同一手法。
ci_set_var() {
    local file="$1" key="$2" val="$3"
    awk -v key="$key" -v val="$val" '
        BEGIN { done = 0 }
        $0 ~ "^" key "=" { print key "=" val; done = 1; next }
        { print }
        END { if (!done) print key "=" val }
    ' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}
