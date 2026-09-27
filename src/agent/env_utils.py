"""
环境变量加载工具
从项目根目录 .env 文件加载环境变量到 os.environ
"""
import os
import sys
from pathlib import Path
from dotenv import load_dotenv


def load_env():
    """加载项目根目录的 .env 文件"""
    # 项目根目录：src/agent/../../.env
    project_root = Path(__file__).parent.parent.parent
    env_file = project_root / ".env"
    if env_file.exists():
        # override=False：真实环境变量优先于 .env 文件。容器部署时配置由
        # compose/K8s 注入，若这里 override=True，镜像或挂载里一旦混入 .env
        # 就会静默盖掉外部配置（本地开发只有 .env、无同名变量，行为不变）。
        load_dotenv(env_file, override=False)
    else:
        # 容器部署下 .env 本来就不进镜像（compose/K8s 用 env_file 注入），
        # 这行不是异常。但必须写 stderr：import 期往 stdout 打东西会污染
        # 任何以 stdout 为协议的输出（例如 `python -c "print(配置值)"`）。
        print(f"⚠️ .env file not found at {env_file}", file=sys.stderr)


def get_env(key: str, default: str = None) -> str:
    """获取环境变量"""
    return os.getenv(key, default)


def get_env_int(key: str, default: int = 0) -> int:
    """获取整数环境变量"""
    return int(os.getenv(key, str(default)))


# 模块加载时自动加载 .env
load_env()
#加载进去之后可以直接通过 os.getenv(key, default) 获取 key是键  default是默认值
