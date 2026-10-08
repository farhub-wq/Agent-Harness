# Backend API 与 MCP Server 共用同一镜像，靠 compose 的 command 区分入口。
#
# 关键约束：WORKDIR 必须是 /app。代码里 PROJECT_ROOT 由 __file__ 逐级 parent
# 解析（main_agent.py / sandbox_setup.py / web_fetch.py 等），必须正好落在
# /app，src/skills、requirements.txt、src/agent/backends/seccomp.json 才找得到。
FROM python:3.11-slim

# 默认用阿里云的 pypi 镜像：tuna 会对云主机 IP 返回 403（pip 把它读成
# "from versions: none"，像是包不存在，很难猜），而 pypi.org 在国内直连基本超时。
# 换环境用 --build-arg PIP_INDEX_URL=... 覆盖即可。
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# 依赖单独一层，改代码不必重装依赖
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# 只拷 src/，不要 COPY .：
#   1) main_agent._upload_project_to_sandbox 用 PROJECT_ROOT.rglob("*") 把整棵树
#      打包上传进沙箱的 tmpfs /tmp，镜像里多一个字节都会被传一次；
#   2) .env（含 CHATANYWHERE_API_KEY）绝不能进镜像。
COPY src/ /app/src/

# src/download 由 docker-compose 挂载覆盖；这里先建出来，保证直接 docker run
# 时 web_main 的 mkdir 不会因为父目录缺失而失败。
RUN mkdir -p /app/src/download

EXPOSE 8000

# workers 必须为 1：SandboxManager / sandbox_holder / AgentLoader 都是进程内
# 单例状态，多 worker 会各自认领同一个暖容器并互相覆盖 MongoDB 里的映射。
CMD ["uvicorn", "src.api_view.web_main:app", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "1", "--proxy-headers", "--forwarded-allow-ips", "*"]
