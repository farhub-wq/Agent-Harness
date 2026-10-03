#!/usr/bin/env bash
# 建一个**带资源限额**的 buildx builder，供 build.yml 使用。
#
#   bash deploy/runner/setup-builder.sh
#
# 为什么不能就用默认 builder：
#   默认构建器跑在 dockerd 内置的 BuildKit 里，构建步骤是 docker.service 下的
#   容器 —— 挂不上 runner 的 systemd slice，MemoryMax 管不到它。也就是说
#   「给 runner 加 cgroup 限额」这个办法对 docker build 是**无效的**
#   （方案第三节把它写成"唯一有效的办法"，这个判断不成立）。
#
#   docker-container 驱动的 builder 是一个普通容器，可以带 memory / cpu-quota
#   限额，而构建步骤就在它里面跑。限额因此真的落在构建上。
#
# 代价：镜像要先在 builder 里构建、再 --load 回宿主 daemon（多一次本地拷贝，
# 约 1.2GB，几秒）。相对于「构建能把生产容器挤成 OOM」，这个代价可以接受。
#
# 必须以 ghrunner 的身份创建 builder 定义：buildx 把 builder 记在
# $DOCKER_CONFIG/buildx/instances/ 下，root 建的 ghrunner 看不见。
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="${BUILDER:-erp-agent-builder}"
# 1400M 而不是 runner slice 的 1600M：builder 容器自己还有点开销，留点余量。
BUILDER_MEMORY="${BUILDER_MEMORY:-1400m}"
# cpu-quota 单位是微秒/100000 周期 → 150000 = 1.5 核。
BUILDER_CPU_QUOTA="${BUILDER_CPU_QUOTA:-150000}"
RUNNER_USER="${RUNNER_USER:-ghrunner}"

die() { printf '\033[31m !! %s\033[0m\n' "$1" >&2; exit 1; }
info() { printf '    %s\n' "$*"; }

command -v docker >/dev/null || die "没有 docker"
id "$RUNNER_USER" >/dev/null 2>&1 || die "用户 $RUNNER_USER 不存在，先跑 install-runner.sh"

as_runner() {
    if [ "$(id -un)" = "$RUNNER_USER" ]; then
        "$@"
    else
        runuser -u "$RUNNER_USER" -- env \
            HOME="/home/$RUNNER_USER" \
            "DOCKER_CONFIG=/home/$RUNNER_USER/.docker" \
            "$@"
    fi
}

if as_runner docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
    info "builder '$BUILDER' 已存在"
else
    info "创建 builder '$BUILDER'（driver=docker-container，memory=$BUILDER_MEMORY，cpu-quota=$BUILDER_CPU_QUOTA）"
    # 先 --bootstrap 出来，再断言限额真的落到了容器上。buildx 对不认识的
    # driver-opt 是**静默忽略**的，不断言的话会得到一个"以为限住了"的假象。
    #
    # --config 传的是 buildkitd 的 registry 配置：这台机器直连 Docker Hub 不通，
    # 只有 daocloud 镜像站可达，而 buildkitd 不读宿主 daemon 的 registry-mirrors。
    # 漏了它构建会卡在拉基础镜像上（见 buildkitd.toml）。**改这个配置要
    # `docker buildx rm <builder>` 后重建**：--config 只在 create 时读一次。
    as_runner docker buildx create \
        --name "$BUILDER" \
        --driver docker-container \
        --driver-opt "memory=$BUILDER_MEMORY" \
        --driver-opt "cpu-quota=$BUILDER_CPU_QUOTA" \
        --config "$SRC_DIR/buildkitd.toml" \
        --use
fi

info "启动 builder"
as_runner docker buildx inspect --bootstrap "$BUILDER" >/dev/null

# ---------------------------------------------------------------- 断言限额生效
# builder 容器名形如 buildx_buildkit_<builder>0
CID="$(docker ps -aq --filter "name=buildx_buildkit_${BUILDER}" | head -1 || true)"
[ -n "$CID" ] || die "找不到 builder 容器 buildx_buildkit_${BUILDER}* —— buildx 版本可能不认这些 driver-opt"

read -r GOT_MEM GOT_QUOTA <<<"$(docker inspect "$CID" \
    --format '{{.HostConfig.Memory}} {{.HostConfig.CpuQuota}}')"

EXPECT_MEM_BYTES=$(( ${BUILDER_MEMORY%m} * 1024 * 1024 ))

if [ "${GOT_MEM:-0}" -ne "$EXPECT_MEM_BYTES" ]; then
    die "builder 容器的内存限额没生效：期望 ${EXPECT_MEM_BYTES} 字节，实际 ${GOT_MEM}。
    buildx 对不支持的 driver-opt 是静默忽略的。别接受这个结果 ——「没限住」比
    「没设限额」更危险，因为后者至少是知道的。查 docker buildx version 与
    docker buildx create --help。"
fi
if [ "${GOT_QUOTA:-0}" -ne "$BUILDER_CPU_QUOTA" ]; then
    die "builder 容器的 CPU 限额没生效：期望 $BUILDER_CPU_QUOTA，实际 ${GOT_QUOTA}"
fi

info "限额已生效：memory=$(( GOT_MEM / 1024 / 1024 ))MiB cpu-quota=$GOT_QUOTA"
info "builder 容器：$CID（$(docker inspect "$CID" --format '{{.Name}}')）"
echo
echo "build.yml 里用：docker buildx build --builder $BUILDER ... --load"
