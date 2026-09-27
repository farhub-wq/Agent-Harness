FROM python:3.11-slim

# 同根 Dockerfile：tuna 对云主机 IP 会 403，换成阿里云源
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn pydantic

COPY erp_mock_server.py /app/erp_mock_server.py

EXPOSE 8081

CMD ["python", "erp_mock_server.py"]
