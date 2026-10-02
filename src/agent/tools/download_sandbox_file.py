"""
沙箱文件下载工具（Harness — 真实 Docker 文件提取）
从沙箱容器中下载文件到宿主机 src/download/ 目录，供用户通过 HTTP 访问。

工作原理：
1. 通过请求级沙箱绑定（sandbox_holder）取当前会话的稳定 Proxy
2. 通过沙箱 API 读取容器内文件（内部 base64 传输，原生支持二进制）
3. 解码并写入宿主机 download 目录
4. 返回 HTTP 下载链接

支持的文件类型：
- 图表 PNG/JPG（generate_chart 生成）
- 分析报告 MD/HTML
- 数据文件 CSV/JSON
- 任意沙箱内生成的文件
"""
import shutil
from pathlib import Path

from langchain_core.tools import tool

from ..backends.sandbox_holder import get_sandbox
from ..config import ALLOW_LOCAL_SHELL_FALLBACK, PUBLIC_BASE_URL
from ..log_utils import agent_logger

DOWNLOAD_DIR = Path(__file__).parent.parent.parent / "download"

# 这个链接会经 tool result 显示给用户并在浏览器里打开，必须是外部可达的地址，
# 不能用容器网络的 http://backend:8000。
DOWNLOAD_URL_TEMPLATE = f"{PUBLIC_BASE_URL.rstrip('/')}/api/download/{{}}"


def _get_sandbox():
    """取当前请求绑定的沙箱。

    不能自己连 Docker SDK 按容器名前缀扫描：``erp-sandbox-`` 前缀由预热池容器
    和所有用户的容器共享，"取第一个运行中的"与调用方所属会话无关，会读到别人
    的文件。图表、文档、Skill 三个工具都走 ``get_sandbox()``，此处保持一致。
    """
    try:
        return get_sandbox()
    except Exception as e:
        agent_logger.warning(f"Cannot get request sandbox: {e}")
        return None


def _is_alive(sandbox) -> bool:
    """沙箱是否仍能执行命令。

    用于区分"文件不存在"（沙箱活着，路径确实没有）与"沙箱已失效"（应回退本地）。
    """
    try:
        return bool(sandbox.ping())
    except Exception:
        return False


@tool
def download_sandbox_file(remote_path: str, filename: str = "") -> str:
    """从沙箱容器中下载文件到宿主机，生成 HTTP 下载链接。

    工作原理：
    - 取当前请求绑定的沙箱
    - 读取容器内文件（支持文本和二进制）
    - 保存到宿主机 download 目录
    - 返回 HTTP 下载链接

    Args:
        remote_path: 沙箱内的文件路径（如 /workspace/report.md, /tmp/chart.png）
        filename: 下载后的文件名（默认使用原文件名）

    Returns:
        下载链接和本地路径，或错误信息
    """
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

    if not filename:
        filename = Path(remote_path).name

    target = DOWNLOAD_DIR / filename
    download_url = DOWNLOAD_URL_TEMPLATE.format(filename)

    # === 方式1：从沙箱下载 ===
    sandbox = _get_sandbox()
    sandbox_alive = sandbox is not None and _is_alive(sandbox)
    if sandbox_alive:
        try:
            if sandbox.file_exists(remote_path):
                content = sandbox.read_file_bytes(remote_path)
                if not content:
                    return f"文件内容为空: {remote_path}"

                target.write_bytes(content)

                agent_logger.info(
                    f"File downloaded from sandbox: {remote_path} -> {target} ({len(content)} bytes)"
                )
                return (
                    f"✅ 文件已从沙箱下载!\n"
                    f"沙箱路径: {remote_path}\n"
                    f"文件大小: {len(content) / 1024:.1f} KB\n"
                    f"下载链接: {download_url}\n"
                    f"本地路径: {target}"
                )

            # 沙箱确认存活，此时"取不到"就是真的不存在，不再滑到本地回退
            return f"文件不存在于沙箱中: {remote_path}"

        except Exception as e:
            agent_logger.error(f"Sandbox download error: {e}")
            # 读取失败（容器中途失效等），回退到本地文件检查

    # === 方式2：回退到本地文件（开发模式 / 沙箱不可用）===
    # remote_path 是模型给的，这个分支等于「按模型指定的路径读 backend 所在主机
    # 的文件，再复制进公开可下载的 download 目录」—— 一个由模型驱动的任意文件
    # 读取原语。放在本机开发上是有意为之；容器部署里 ALLOW_LOCAL_SHELL_FALLBACK
    # 的语义正是"绝不在 backend 文件系统上碰模型输入"，所以这里必须一起关掉，
    # 否则该开关只挡了执行、没挡读写（注入的网页内容足以诱导 Agent 来读 .env
    # 或 skills 挂载）。
    if not ALLOW_LOCAL_SHELL_FALLBACK:
        return (
            f"文件下载失败:\n"
            f"- 沙箱路径: {remote_path}\n"
            f"- 沙箱状态: {'运行中' if sandbox_alive else '不可用'}\n"
            f"- 本地回退已禁用（ALLOW_LOCAL_SHELL_FALLBACK=false），"
            f"不会在 backend 文件系统上按模型给的路径取文件。\n"
            f"请在沙箱内重新生成该文件后重试。"
        )

    source = Path(remote_path)
    if source.exists():
        if source.is_dir():
            return f"路径是目录而非文件: {remote_path}"

        shutil.copy2(source, target)

        agent_logger.info(f"File downloaded (local fallback): {source} -> {target}")
        return (
            f"✅ 文件已下载!\n"
            f"路径: {remote_path}\n"
            f"文件大小: {source.stat().st_size / 1024:.1f} KB\n"
            f"下载链接: {download_url}\n"
            f"本地路径: {target}\n"
            f"(注: 沙箱不可用，使用本地文件)"
        )

    return (
        f"文件下载失败:\n"
        f"- 沙箱路径: {remote_path}\n"
        f"- 沙箱状态: {'运行中' if sandbox_alive else '不可用'}\n"
        f"- 本地文件: {'不存在' if not source.exists() else '存在'}\n"
        f"请确认文件已在沙箱中生成。"
    )


@tool
def list_sandbox_files(path: str = "/workspace") -> str:
    """列出沙箱内指定目录的文件。

    Args:
        path: 沙箱内的目录路径（默认 /workspace）

    Returns:
        文件列表
    """
    sandbox = _get_sandbox()
    if sandbox is None or not _is_alive(sandbox):
        return "沙箱不可用"

    try:
        result = sandbox.execute(f"ls -lah '{path}'")
        output = result.output or ""
        return f"沙箱目录 {path}:\n{output}" if output else f"目录为空: {path}"
    except Exception as e:
        return f"列出目录失败: {e}"
