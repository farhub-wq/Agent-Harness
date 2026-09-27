"""
Docker 沙箱后端
继承 deepagents BaseSandbox，通过 Docker SDK 在隔离容器中执行命令和操作文件。
容器名: erp-sandbox（由 SandboxManager 管理）.
"""
import docker
import base64
import io
import shlex
import tarfile
import json
from typing import Optional

from deepagents.backends.sandbox import (
    BaseSandbox, ExecuteResponse,
    FileDownloadResponse, FileUploadResponse,
)
from deepagents.backends import DEFAULT_EXECUTE_TIMEOUT
from .docker_client import get_docker_client
from ..log_utils import sandbox_logger
from ..config import DOCKER_TIMEOUT_SECONDS, SANDBOX_WORK_DIR


class CustomOpenSandbox(BaseSandbox):
    """
    Docker 容器沙箱后端

    通过 Docker SDK exec_run 在已运行的容器中执行命令。
    继承 BaseSandbox 后，ls/read/write/edit/glob/grep 等文件操作
    自动委托给 execute()（即 docker exec）。

    使用方式：
        backend = DockerSandboxBackend(container_name="erp-sandbox")
        result = backend.execute("python -c 'print(1+1)'")
    """

    def __init__(
        self,
        container_name: str = "erp-sandbox",
        work_dir: str = SANDBOX_WORK_DIR,
        timeout: int = DEFAULT_EXECUTE_TIMEOUT,
    ):
        self._container_name = container_name
        self._work_dir = work_dir
        self._default_timeout = timeout
        self._client: Optional[docker.DockerClient] = None
        self._container = None
        self._connect()

    def _connect(self):
        """连接到 Docker 容器"""
        try:
            self._client = get_docker_client()
            self._container = self._client.containers.get(self._container_name)
            if self._container.status != "running":
                raise RuntimeError(
                    f"Container '{self._container_name}' is not running "
                    f"(status: {self._container.status})"
                )
            # 确保工作目录存在
            self._container.exec_run(f"mkdir -p {self._work_dir}")
            sandbox_logger.info(
                f"Docker sandbox connected: {self._container_name} "
                f"({self._container.id[:12]})"
            )
        except docker.errors.NotFound:
            raise RuntimeError(
                f"Docker container '{self._container_name}' not found. "
                f"Please start it with:\n"
                f"  docker run -d --name {self._container_name} "
                f"-w {self._work_dir} python:3.11-slim sleep infinity"
            )
        except Exception as e:
            raise RuntimeError(f"Failed to connect to Docker sandbox: {e}")

    @property
    def id(self) -> str:
        """沙箱唯一标识"""
        if self._container:
            return self._container.id[:12]
        return "disconnected"

    @property
    def container_id(self) -> str:
        """容器完整ID（供 SandboxManager 使用）"""
        if self._container:
            return self._container.id
        return ""

    @property
    def container_name(self) -> str:
        """容器名称"""
        return self._container_name

    # ============================================================
    # 核心执行
    # ============================================================

    def execute(
        self,
        command: str,
        *,
        timeout: int | None = None,
    ) -> ExecuteResponse:
        """
        在 Docker 容器中执行 shell 命令

        Args:
            command: shell 命令字符串
            timeout: 超时秒数（None 使用构造函数的 timeout）
            timeout<=0 表示不限制

        Returns:
            ExecuteResponse(output, exit_code, truncated)
        """
        if self._container is None:
            return ExecuteResponse(
                output="[沙箱未连接] 请先启动 Docker 容器",
                exit_code=-1,
            )

        # Docker SDK 的 exec_start 没有超时参数，所以计时交给容器内的 timeout(1)：
        # 它默认把子进程放进独立进程组并向整组发 SIGTERM，pip 这类子进程会一起收到。
        # 镜像里没有 timeout(1) 时退化为不限制（与加这个参数之前的行为一致）。
        effective_timeout = self._default_timeout if timeout is None else timeout

        # 容器内的 timeout(N) 必须**先于**客户端 socket 超时触发。exec_run 是一次
        # 同步 HTTP 请求，受 docker.from_env(timeout=DOCKER_TIMEOUT_SECONDS) 约束；
        # 若 N 大于它，长命令的失败形态就变成 urllib3 ReadTimeout → 被下面
        # `except Exception` 变成 `[执行错误] ...`，而不是可读的 `[超时]` 提示，
        # 调用方还可能据此重试，于是容器里并发跑起两份安装。
        # sandbox_setup 里有 timeout=900 的调用，正是这个形态。
        ceiling = max(30, DOCKER_TIMEOUT_SECONDS - 30)
        if effective_timeout and effective_timeout > ceiling:
            sandbox_logger.warning(
                f"Clamping execute timeout {int(effective_timeout)}s to {ceiling}s: "
                f"must stay below the docker client timeout "
                f"(DOCKER_TIMEOUT_SECONDS={DOCKER_TIMEOUT_SECONDS}) or the socket "
                f"read times out first and the failure loses its reason"
            )
            effective_timeout = ceiling

        inner = f"cd {self._work_dir} && {command}"
        if effective_timeout and effective_timeout > 0:
            shell_cmd = (
                "if command -v timeout >/dev/null 2>&1; then "
                f"timeout {int(effective_timeout)} bash -c {shlex.quote(inner)}; "
                f"else {inner}; fi"
            )
        else:
            shell_cmd = inner

        try:
            # 在工作目录下执行命令
            exec_result = self._container.exec_run(
                cmd=["bash", "-c", shell_cmd],
                demux=True,  # 分离 stdout/stderr
                workdir=self._work_dir,
            )

            exit_code = exec_result.exit_code
            stdout, stderr = exec_result.output

            # 合并输出
            output_parts = []
            if stdout:
                output_parts.append(
                    stdout.decode("utf-8", errors="replace")
                )
            if stderr:
                stderr_text = stderr.decode("utf-8", errors="replace")
                if stderr_text.strip():
                    output_parts.append(stderr_text)

            output = "\n".join(output_parts) if output_parts else ""

            # timeout(1) 用 124 表示"到点被杀"，换成看得懂的提示，
            # 免得调用方把超时当成命令本身失败。
            #
            # 但 124 不专属于我们套的那层 timeout：命令自带 `timeout`（或脚本
            # 里自己用了）也会以 124 退出。effective_timeout<=0 意味着压根没套
            # 包装（文档里的"不限制"模式），此时不能报成"超过 0s"。
            if exit_code == 124:
                if effective_timeout and effective_timeout > 0:
                    output = (
                        f"[超时] 命令超过 {int(effective_timeout)}s 未结束，已被终止。"
                        f"需要更长时间请显式传 timeout=。\n" + output
                    )
                else:
                    output = (
                        "[超时] 命令以 124 退出（自带 timeout 触发），"
                        "本次未限制时长。\n" + output
                    )
                sandbox_logger.warning(
                    f"Docker exec returned 124 (timeout={effective_timeout}): "
                    f"{command[:120]}"
                )

            # 截断过长输出
            truncated = False
            max_bytes = 100_000
            if len(output) > max_bytes:
                output = output[:max_bytes] + "\n... [output truncated]"
                truncated = True

            return ExecuteResponse(
                output=output,
                exit_code=exit_code,
                truncated=truncated,
            )

        except Exception as e:
            sandbox_logger.error(f"Docker exec failed: {e}")
            return ExecuteResponse(
                output=f"[执行错误] {str(e)}",
                exit_code=-1,
            )

    # ============================================================
    # 文件操作 — 真实实现（通过 docker exec / tar 流）
    # ============================================================

    def read_file(self, path: str) -> str:
        """读取沙箱内文件内容（文本）"""
        resp = self.execute(f"cat '{path}'")
        if resp.exit_code != 0:
            raise FileNotFoundError(f"Cannot read file: {path} — {resp.output}")
        return resp.output

    def _read_bytes_raw(self, path: str) -> bytes:
        """按字节读沙箱内文件，绕开 ``execute()`` 的输出上限。

        `execute()` 会把输出硬截到 100000 字符（见上方 max_bytes），这对"看一眼
        命令输出"是合理的，但对按字节搬文件是致命的：base64 把文件撑大 4/3，所以
        **超过约 73KB 的文件读出来必然是一段被截断的 base64** —— `b64decode`
        默认丢弃非法字母，截断标记里的字母会被并进数据，长度对不齐就抛
        `binascii.Error: Invalid base64-encoded string`，对得齐则静默解出半截
        内容。两种都是错的，而且报错方向完全误导：`download_sandbox_file` 会吞掉
        异常、回退到宿主机路径检查，最后告诉用户"文件不存在于沙箱中"。
        Agent 生成的图表 PNG 和 HTML 报告普遍超过 73KB。

        这里直接调 `exec_run`，不套那层截断。

        **不能改用 archive 接口**（`get_archive`）：daemon 是按宿主机路径解析的，
        而 `/workspace` 是 tmpfs、没有对应的宿主路径，实测对该目录下的文件一律
        404 "Could not find the file"（镜像 rootfs 和 volume 上的路径则正常）。
        Agent 的产物恰恰都写在 /workspace 下。

        仍然走 base64 而不是 cat：避免文本编码/换行在往返中被改写；`-w0` 不折行。
        """
        if self._container is None:
            raise RuntimeError("沙箱未连接")

        result = self._container.exec_run(
            cmd=["bash", "-c", f"base64 -w0 {shlex.quote(path)}"],
            demux=True,
            workdir=self._work_dir,
        )
        stdout, stderr = result.output
        if result.exit_code != 0:
            detail = (stderr or b"").decode("utf-8", errors="replace").strip()
            # 目录要和"不存在"区分开：调用方对两者的处理不同
            if "Is a directory" in detail:
                raise IsADirectoryError(f"Not a regular file: {path}")
            raise FileNotFoundError(f"Cannot read file: {path} — {detail}")
        return stdout or b""

    def read_file_bytes(self, path: str) -> bytes:
        """读取沙箱内文件内容（二进制）"""
        raw = self._read_bytes_raw(path)
        try:
            return base64.b64decode(raw)
        except Exception as e:
            # 走到这里说明不是"读不到"而是数据坏了，不能再报成文件不存在
            raise RuntimeError(f"Corrupt base64 payload for {path}: {e}") from e

    def write_file(self, path: str, content: str | bytes) -> str:
        """写入内容到沙箱内文件（自动创建父目录）"""
        # 确保父目录存在
        dir_path = "/".join(path.rstrip("/").split("/")[:-1]) or "/"
        self.execute(f"mkdir -p '{dir_path}'")

        if isinstance(content, str):
            # 文本写入：base64 编码避免 shell 转义问题
            encoded = base64.b64encode(content.encode("utf-8")).decode("ascii")
            resp = self.execute(f"echo '{encoded}' | base64 -d > '{path}'")
        else:
            # 二进制写入
            encoded = base64.b64encode(content).decode("ascii")
            resp = self.execute(f"echo '{encoded}' | base64 -d > '{path}'")

        if resp.exit_code != 0:
            raise IOError(f"Cannot write file: {path} — {resp.output}")
        return f"OK: {path}"

    def list_dir(self, path: str = ".") -> list[str]:
        """列出沙箱内目录内容"""
        resp = self.execute(f"ls -1 '{path}'")
        if resp.exit_code != 0:
            raise FileNotFoundError(f"Cannot list dir: {path} — {resp.output}")
        items = [line.strip() for line in resp.output.strip().split("\n") if line.strip()]
        return items

    def file_exists(self, path: str) -> bool:
        """检查文件是否存在"""
        resp = self.execute(f"test -e '{path}' && echo YES || echo NO")
        return "YES" in resp.output

    def is_directory(self, path: str) -> bool:
        """检查路径是否为目录"""
        resp = self.execute(f"test -d '{path}' && echo YES || echo NO")
        return "YES" in resp.output

    def edit_file(self, path: str, old_text: str, new_text: str) -> str:
        """编辑文件：替换文本块"""
        content = self.read_file(path)
        if old_text not in content:
            return f"Error: old_text not found in {path}"
        content = content.replace(old_text, new_text, 1)
        return self.write_file(path, content)

    def glob(self, pattern: str, base_path: str = ".") -> list[str]:
        """文件模式匹配（支持递归）"""
        resp = self.execute(f"find '{base_path}' -path '{pattern}' -type f 2>/dev/null | head -200")
        if resp.exit_code != 0:
            return []
        return [line.strip() for line in resp.output.strip().split("\n") if line.strip()]

    def grep(self, pattern: str, path: str = ".", recursive: bool = True) -> list[str]:
        """在文件中搜索文本模式"""
        flag = "-rn" if recursive else "-n"
        resp = self.execute(f"grep {flag} '{pattern}' '{path}' 2>/dev/null | head -100")
        if resp.exit_code != 0:
            return []
        return [line.strip() for line in resp.output.strip().split("\n") if line.strip()]

    def mkdir(self, path: str) -> str:
        """创建目录（含父目录）"""
        resp = self.execute(f"mkdir -p '{path}'")
        if resp.exit_code != 0:
            raise IOError(f"Cannot mkdir: {path} — {resp.output}")
        return f"OK: {path}"

    def rm(self, path: str) -> str:
        """删除文件或目录"""
        resp = self.execute(f"rm -rf '{path}'")
        if resp.exit_code != 0:
            raise IOError(f"Cannot rm: {path} — {resp.output}")
        return f"OK: removed {path}"

    def cp(self, src: str, dst: str) -> str:
        """复制文件或目录"""
        resp = self.execute(f"cp -r '{src}' '{dst}'")
        if resp.exit_code != 0:
            raise IOError(f"Cannot cp: {src} -> {dst} — {resp.output}")
        return f"OK: {src} -> {dst}"

    def mv(self, src: str, dst: str) -> str:
        """移动文件或目录"""
        resp = self.execute(f"mv '{src}' '{dst}'")
        if resp.exit_code != 0:
            raise IOError(f"Cannot mv: {src} -> {dst} — {resp.output}")
        return f"OK: {src} -> {dst}"

    def cat(self, path: str) -> str:
        """读取文件内容（同 read_file）"""
        return self.read_file(path)

    def pwd(self) -> str:
        """获取当前工作目录"""
        resp = self.execute("pwd")
        return resp.output.strip()

    def env(self) -> str:
        """获取沙箱环境变量"""
        resp = self.execute("env")
        return resp.output

    def pip_install(self, package: str) -> str:
        """安装 Python 包"""
        resp = self.execute(f"pip install {package} -q", timeout=120)
        if resp.exit_code != 0:
            return f"pip install failed: {resp.output}"
        return f"OK: installed {package}"

    def python_exec(self, script: str) -> ExecuteResponse:
        """执行 Python 脚本（写入临时文件再运行）"""
        self.write_file("/tmp/_sandbox_script.py", script)
        return self.execute("python /tmp/_sandbox_script.py", timeout=60)

    def go_exec(self, code: str) -> ExecuteResponse:
        """执行 Go 代码"""
        self.write_file("/tmp/_sandbox_main.go", code)
        return self.execute("cd /tmp && go run _sandbox_main.go", timeout=60)

    def node_exec(self, code: str) -> ExecuteResponse:
        """执行 Node.js 代码"""
        self.write_file("/tmp/_sandbox_script.js", code)
        return self.execute("node /tmp/_sandbox_script.js", timeout=60)

    # ============================================================
    # 生命周期
    # ============================================================

    def ping(self) -> bool:
        """健康检查：容器是否仍在运行"""
        try:
            if self._container is None:
                return False
            self._container.reload()
            return self._container.status == "running"
        except Exception:
            return False

    def destroy(self):
        """断开连接（不销毁容器，容器由 SandboxManager 管理）"""
        # 只丢弃容器引用。client 是进程级共享的（见 docker_client），
        # 在这里 close() 会连带关掉其它用户正在使用的连接池。
        self._container = None
        self._client = None
        sandbox_logger.info("Docker sandbox disconnected")

    def destroy_container(self):
        """强制停止并删除容器（由 SandboxManager 调用）"""
        if self._container:
            try:
                self._container.stop(timeout=5)
                # v=True 连带删掉依赖目录的匿名 volume（见 sandbox_setup），
                # 否则每回收一个沙箱就漏一个 100MB+ 的 volume。
                self._container.remove(force=True, v=True)
                sandbox_logger.info(f"Container destroyed: {self._container_name}")
            except Exception as e:
                sandbox_logger.warning(f"Error destroying container: {e}")
            finally:
                self._container = None
        # 同上：共享 client 不由单个沙箱负责关闭。
        self._client = None

    # ============================================================
    # 文件上传/下载（tar 流方式，高效可靠）
    # ============================================================

    def download_files(self, paths: list[str]) -> list[FileDownloadResponse]:
        """从容器中下载文件（不受 execute 输出上限约束）"""
        results = []
        for path in paths:
            try:
                content = self.read_file_bytes(path)
                results.append(FileDownloadResponse(path=path, content=content, error=None))
            except FileNotFoundError:
                results.append(FileDownloadResponse(path=path, content=None, error="file_not_found"))
            except Exception as e:
                results.append(FileDownloadResponse(path=path, content=None, error=str(e)))
        return results

    def download_file_to_host(self, remote_path: str, local_path: str) -> str:
        """从沙箱下载文件到宿主机指定路径"""
        try:
            content = self.read_file_bytes(remote_path)
            from pathlib import Path
            Path(local_path).parent.mkdir(parents=True, exist_ok=True)
            Path(local_path).write_bytes(content)
            return f"OK: {remote_path} -> {local_path}"
        except Exception as e:
            return f"Download failed: {e}"

    def upload_files(self, files: list[tuple[str, bytes]]) -> list[FileUploadResponse]:
        """上传文件到容器（tar 流方式）"""
        results = []
        for path, content in files:
            try:
                dir_name = "/".join(path.rstrip("/").split("/")[:-1]) or "/"
                file_name = path.split("/")[-1]

                tar_stream = io.BytesIO()
                with tarfile.open(fileobj=tar_stream, mode="w") as tar:
                    info = tarfile.TarInfo(name=file_name)
                    info.size = len(content)
                    tar.addfile(info, io.BytesIO(content))
                tar_stream.seek(0)

                self._container.put_archive(dir_name, tar_stream.read())
                results.append(FileUploadResponse(path=path, error=None))
            except Exception as e:
                results.append(FileUploadResponse(path=path, error=str(e)))
        return results

    def upload_directory(self, local_dir: str, remote_dir: str) -> str:
        """上传整个目录到沙箱（tar 打包传输）"""
        from pathlib import Path
        local_path = Path(local_dir)
        if not local_path.exists():
            return f"Error: local directory not found: {local_dir}"

        tar_stream = io.BytesIO()
        with tarfile.open(fileobj=tar_stream, mode="w:gz") as tar:
            tar.add(str(local_path), arcname=".")
        tar_stream.seek(0)

        try:
            self.execute(f"mkdir -p '{remote_dir}'")
            self._container.put_archive(remote_dir, tar_stream.read())
            return f"OK: uploaded {local_dir} -> {remote_dir}"
        except Exception as e:
            return f"Upload directory failed: {e}"


# 向后兼容别名
DockerSandboxBackend = CustomOpenSandbox
