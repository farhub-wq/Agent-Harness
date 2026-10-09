# 沙箱基础镜像（预装数据分析栈）
#
# 为什么存在：裸 python:3.11-slim 里没有 matplotlib/numpy，chart_generator 与
# 数据分析脚本首次执行要在沙箱里现装 —— 实测冷装 1~2 分钟起步，且依赖 dind
# 到 PyPI 的网络出口（生产机上经常就是瓶颈甚至直接超时）。这个镜像把常用栈
# 直接烘进去，容器起来即可 import。
#
# 构建方式：由 docker-compose.yml 的 sandbox-image-loader 在 dind daemon 里
# 构建，tag 取 deploy/.env 的 SANDBOX_IMAGE（backend 读同一个值，改镜像只改
# 一处）。基础镜像 python:3.11-slim 走 dind 的 daocloud 镜像源拉取。
#
# 本地开发（backend 直连宿主机 daemon、不经 compose）需要手动构建一次：
#   docker build -f deploy/sandbox/Dockerfile -t erp-sandbox:3.11 deploy/sandbox

FROM python:3.11-slim

# 阿里云 PyPI 镜像（与根 Dockerfile 的 PIP_INDEX_URL 同源）：构建期安装走国内源
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/

# 预装到**系统 site-packages**，刻意不装 /workspace/python-packages：
# - 那个路径运行时被匿名 volume 遮蔽（tmpfs noexec 问题的绕法，见
#   sandbox_setup.py 的 SANDBOX_PACKAGE_DIR 注释），预装内容会被 Docker 的
#   volume 首挂拷贝塞进每个新容器的匿名 volume，平白多拷 ~250MB。
# - 系统 site-packages 在只读 rootfs（overlay）上，.so 的可执行映射不受影响
#   —— 基础镜像自己的 stdlib .so 就是这么加载的。
# 运行时 PIP_TARGET/PYTHONPATH 仍指向 volume：用户脚本 pip install 的包在
# sys.path 里排在 site-packages 之前，天然可覆盖预装版本。
RUN pip install --no-cache-dir matplotlib pandas numpy

# 中文字体：没有它中文标题/标签渲染成方框。配合 chart_generator.py 里按
# 「实际可用」选择字体的逻辑，装了就会被选中。
RUN apt-get update \
    && apt-get install -y --no-install-recommends fonts-wqy-microhei \
    && rm -rf /var/lib/apt/lists/*
