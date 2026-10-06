"""跨文件不变量：同一件事抄在几个地方，改一处忘了另一处。

这些断言**不启动 Docker、不连网络、不导入 src 里任何模块**（纯 stdlib 读文件 +
正则）。它们存在的理由是：`deploy/cd/README.md` 里那句"改静态 IP 要同步改两处"
以前只是文档，而文档不会拦住任何人 —— 现在由测试拦住。

具体钉住的五件事：

1. `SANDBOX_MCP_HOST_IP` 在三个文件里必须完全一致，且落在 `mcp-sandbox` 的
   子网内。改坏任意一处 → mcp 换了地址而沙箱容器的 /etc/hosts 还写着旧的 →
   沙箱内所有 MCP 工具挂掉，症状是超时（很难往配置上想）。
2. `deploy/nginx/nginx.conf` 的认证结构。共享密钥头漏一个 location 就是
   "沙箱代码可以绕过 nginx 直连 backend 伪造身份"；`auth_basic off` 多一处就是
   某个 location 静默不认证。
3. 两个 env 模板都得有 `INTERNAL_AUTH_TOKEN` 这个键。
4. 前端源码里不得有硬编码的后端绝对地址（镜像必须与环境无关）。
5. `tls.conf.template` 被 nginx.conf 在 http{} 顶层 include：开关必须用 map
   定义、不能用 set（set 在该上下文 nginx -t 直接 emerg，真机发布回滚过）。

第 2 条的运行时对照在 `deploy/ci/smoke-edge.sh`（集成 job）。这里只做**结构**
断言 —— 它能抓住"删了一行 header"，抓不住"proxy_pass 指到了错的端口"，后者
只有真起一套栈才发现。两者都要。
"""
import ipaddress
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

ENV_EXAMPLE = REPO / "deploy" / ".env.example"
NGINX_ENV_EXAMPLE = REPO / "deploy" / "nginx.env.example"
COMPOSE = REPO / "docker-compose.yml"
LIB_SH = REPO / "deploy" / "cd" / "lib.sh"
NGINX_CONF = REPO / "deploy" / "nginx" / "nginx.conf"
NGINX_TEMPLATE = REPO / "deploy" / "nginx" / "templates" / "internal_token.conf.template"
TLS_TEMPLATE = REPO / "deploy" / "nginx" / "templates" / "tls.conf.template"
FRONTEND_SRC = REPO / "frontend" / "src"


def _read(path: Path) -> str:
    assert path.is_file(), f"文件不存在：{path}"
    return path.read_text(encoding="utf-8")


def _yaml_block(text: str, header: str, indent: int) -> str:
    """取 ``indent`` 级缩进的 ``header:`` 那一块（到下个同级或更浅的键为止）。

    刻意不引 PyYAML：这个模块的定位是「零依赖、任何环境都能跑」，用正则读
    这几个固定形状的块足够了。注释行和空行保留在块内（它们不影响下面的匹配）。
    """
    prefix = " " * indent + header + ":"
    lines = text.splitlines()
    out: list[str] = []
    inside = False
    for line in lines:
        if not inside:
            if line.startswith(prefix):
                inside = True
                out.append(line)
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            out.append(line)
            continue
        if len(line) - len(line.lstrip(" ")) <= indent:
            break
        out.append(line)
    assert out, f"docker-compose.yml 里找不到 {header!r} 块（缩进 {indent}）"
    return "\n".join(out)


def _first_group(pattern: str, text: str, what: str) -> str:
    # 全部 pattern 都用 ^ 表示行首，所以这里统一开 MULTILINE。
    m = re.search(pattern, text, re.MULTILINE)
    assert m, f"没匹配到{what}（pattern={pattern!r}）"
    return m.group(1)


class TestSandboxMcpIpConsistency(unittest.TestCase):
    """mcp 的静态 IP 三处一致，且落在子网内。"""

    def test_ip_is_identical_across_three_places(self):
        env_ip = _first_group(r"^SANDBOX_MCP_HOST_IP=(\S+)\s*$", _read(ENV_EXAMPLE),
                              "deploy/.env.example 的 SANDBOX_MCP_HOST_IP")

        mcp_block = _yaml_block(_read(COMPOSE), "mcp", 2)
        compose_ip = _first_group(r"ipv4_address:\s*(\S+)", mcp_block,
                                  "docker-compose.yml 里 mcp 的 ipv4_address")

        lib_ip = _first_group(r'MCP_SANDBOX_IP="\$\{MCP_SANDBOX_IP:-([^}"]+)\}"',
                              _read(LIB_SH),
                              "deploy/cd/lib.sh 里 MCP_SANDBOX_IP 的默认值")

        self.assertEqual(
            env_ip, compose_ip,
            f"deploy/.env.example 的 SANDBOX_MCP_HOST_IP={env_ip} 与 "
            f"docker-compose.yml 里 mcp 的 ipv4_address={compose_ip} 不一致 —— "
            f"沙箱容器 /etc/hosts 会写成一个连不通的地址",
        )
        self.assertEqual(
            env_ip, lib_ip,
            f"deploy/.env.example 的 SANDBOX_MCP_HOST_IP={env_ip} 与 "
            f"deploy/cd/lib.sh 的 MCP_SANDBOX_IP 默认值={lib_ip} 不一致",
        )

    def test_ip_is_inside_the_mcp_sandbox_subnet(self):
        env_ip = _first_group(r"^SANDBOX_MCP_HOST_IP=(\S+)\s*$", _read(ENV_EXAMPLE),
                              "deploy/.env.example 的 SANDBOX_MCP_HOST_IP")

        net_block = _yaml_block(_read(COMPOSE), "mcp-sandbox", 2)
        subnet = _first_group(r"subnet:\s*(\S+)", net_block,
                              "docker-compose.yml 里 mcp-sandbox 的 subnet")

        self.assertIn(
            ipaddress.ip_address(env_ip),
            ipaddress.ip_network(subnet, strict=False),
            f"SANDBOX_MCP_HOST_IP={env_ip} 不在 mcp-sandbox 的子网 {subnet} 内 —— "
            f"compose 起不来，或者 mcp 拿不到这个地址",
        )

    def test_ipv4_address_appears_exactly_once(self):
        """整份 compose 只该有一处静态 IP。多一处通常是复制粘贴出来的。"""
        hits = re.findall(r"^\s*ipv4_address:", _read(COMPOSE), re.MULTILINE)
        self.assertEqual(
            len(hits), 1,
            f"docker-compose.yml 里有 {len(hits)} 处 ipv4_address，期望恰好 1 处"
            f"（mcp 的）。新增静态 IP 时要同步扩展本测试。",
        )


class TestNginxAuthStructure(unittest.TestCase):
    """nginx.conf 的认证结构：认证不能漏 location，开关不能多。"""

    @classmethod
    def setUpClass(cls):
        cls.conf = _read(NGINX_CONF)

    def _location_block(self, selector: str) -> str:
        # `^\s*` 锚定行首：注释行以 # 开头，所以不会被匹配到。
        # 这个锚定不是洁癖 —— nginx.conf 的注释里真的会出现 "location" 这个词，
        # 不加锚定的 index()/search() 会命中注释，然后断言就变成了在测注释。
        m = re.search(r"^[ \t]*location\s+" + re.escape(selector) + r"\s*\{",
                      self.conf, re.MULTILINE)
        self.assertIsNotNone(m, f"nginx.conf 里找不到 location {selector}")
        start = m.end() - 1
        depth = 0
        for i in range(start, len(self.conf)):
            if self.conf[i] == "{":
                depth += 1
            elif self.conf[i] == "}":
                depth -= 1
                if depth == 0:
                    return self.conf[start:i + 1]
        self.fail(f"location {selector} 的花括号不平衡")

    def test_api_locations_forward_both_auth_headers(self):
        """共享密钥头与身份头，两个 /api location 都得有。

        漏掉 X-Internal-Auth → backend 拒绝所有 /api 请求（401），
        漏掉 X-Authenticated-User → backend 认为请求没经过 nginx（401）。
        两者都会"整个 API 挂掉"，但只有后者是安全相关的：
        它反过来（backend 不校验时）就是沙箱代码可以伪造身份。
        """
        for selector in ("/api/chat/", "/api/"):
            with self.subTest(location=selector):
                block = self._location_block(selector)
                self.assertIn("proxy_set_header X-Internal-Auth", block,
                              f"location {selector} 没有转发 X-Internal-Auth")
                self.assertIn("proxy_set_header X-Authenticated-User", block,
                              f"location {selector} 没有转发 X-Authenticated-User")

    def _all_location_blocks(self):
        """返回 [(selector, block_text), ...]，覆盖每个 server 块里的全部
        location（:80 与 :443 各有一组探针，所以不能只取第一个匹配）。"""
        out = []
        for m in re.finditer(r"^[ \t]*location\s+(.+?)\s*\{", self.conf, re.MULTILINE):
            selector = m.group(1).strip()
            start = m.end() - 1
            depth = 0
            for i in range(start, len(self.conf)):
                if self.conf[i] == "{":
                    depth += 1
                elif self.conf[i] == "}":
                    depth -= 1
                    if depth == 0:
                        out.append((selector, self.conf[start:i + 1]))
                        break
        return out

    def test_auth_basic_off_only_on_health_endpoints(self):
        """`auth_basic off` 只能出现在探活 location 上，且每个探针都必须免认证。

        不数全局固定数量：:80 与 :443(TLS) 各有一组 /healthz、/health，server
        块数量会随拓扑增长。直接枚举每个 location 块做两条双向断言更稳：
          - 任何免认证的 location，选择器必须是 = /healthz 或 = /health
            （抓住「某个业务 location 被静默放行」这个真实漏洞）；
          - 这两个探针 location 必须 auth_basic off（探针带不了凭据）。
        """
        blocks = self._all_location_blocks()
        self.assertTrue(blocks, "nginx.conf 里一个 location 块都没解析出来？")

        health = {"= /healthz", "= /health"}
        off_selectors = []
        for selector, block in blocks:
            if re.search(r"^\s*auth_basic\s+off\s*;", block, re.MULTILINE):
                off_selectors.append(selector)

        unauth = [s for s in off_selectors if s not in health]
        self.assertEqual(
            unauth, [],
            f"这些非探活 location 配了 auth_basic off，属于未认证放行：{unauth}",
        )

        present = {s for s, _ in blocks}
        missing = sorted(h for h in health if h in present
                         and not any(s == h for s in off_selectors))
        self.assertEqual(
            missing, [],
            f"探针 location {missing} 应当 auth_basic off（探针带不了凭据）",
        )
        # 至少 :80 一组，防止前面的断言在「整份配置没有任何 off」时被空集绕过。
        self.assertGreaterEqual(
            len(off_selectors), 2,
            f"auth_basic off 只有 {len(off_selectors)} 处，至少应有 :80 的一组探针",
        )

    def test_internal_token_include_is_in_server_context(self):
        """include 必须在 server 上下文里，两个 /api location 才继承得到它。"""
        self.assertIn("include /etc/nginx/conf.d/internal_token.conf;", self.conf)
        include_at = self.conf.index("include /etc/nginx/conf.d/internal_token.conf;")

        # 锚定行首找第一条真正的 location 指令（注释里的 "location" 不算）。
        m = re.search(r"^[ \t]*location\s", self.conf, re.MULTILINE)
        self.assertIsNotNone(m, "nginx.conf 里一个 location 都没有？")
        self.assertLess(
            include_at, m.start(),
            "internal_token.conf 的 include 出现在第一个 location 之后 —— "
            "如果它被挪进了某个 location，其它 location 就取不到 $internal_token",
        )

    def test_token_template_exists_and_reads_the_env_var(self):
        """include 的那个文件是渲染出来的，模板必须存在并引用环境变量。"""
        template = _read(NGINX_TEMPLATE)
        self.assertIn("${INTERNAL_AUTH_TOKEN}", template)
        self.assertIn("set $internal_token", template)


class TestNginxTlsSwitchTemplate(unittest.TestCase):
    """tls.conf 在 nginx.conf 的 http{} **顶层**被 include，那里只能用 map。

    真机发布时踩过：模板原本写 ``set $tls_enabled "...";``，而 set 属于
    rewrite 模块、只允许出现在 server/location/if，写在 http 层 nginx -t 直接
    ``"set" directive is not allowed here``，容器 restart 死循环、换版必回滚。
    CI 全新起栈没拦住（也没真跑 nginx -t），所以这里用静态断言钉死上下文。
    """

    @classmethod
    def setUpClass(cls):
        cls.template = _read(TLS_TEMPLATE)
        cls.conf = _read(NGINX_CONF)

    def _active_lines(self):
        # 注释行里会反复讨论 set/map，绝不能拿注释内容做断言 —— 只看有效行。
        return [
            ln for ln in self.template.splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")
        ]

    def test_tls_conf_is_included_in_http_context(self):
        self.assertIn("include /etc/nginx/conf.d/tls.conf;", self.conf)
        include_at = self.conf.index("include /etc/nginx/conf.d/tls.conf;")
        m = re.search(r"^[ \t]*server\s*\{", self.conf, re.MULTILINE)
        self.assertIsNotNone(m, "nginx.conf 里没有 server 块？")
        self.assertLess(
            include_at, m.start(),
            "tls.conf 的 include 出现在第一个 server 块之后 —— 那就不在 http 顶层，"
            "本测试对 set/map 的上下文假设失效了，需要重审",
        )

    def test_switch_is_defined_with_map_not_set(self):
        active = "\n".join(self._active_lines())
        self.assertRegex(
            active, r"map\s+\$\w+\s+\$tls_enabled\s*\{",
            "TLS 开关必须在 http 层用 map 定义 $tls_enabled（set 在该上下文非法）",
        )
        self.assertNotRegex(
            active, r"(?m)^\s*set\s+",
            "tls.conf 在 http{} 顶层被 include，不能出现 set 指令 —— "
            "nginx -t 会 emerg '\"set\" directive is not allowed here'（真机复现）",
        )
        self.assertIn(
            "${TLS_ENABLED}", active,
            "模板必须引用容器环境变量 ${TLS_ENABLED}（由 20-envsubst 渲染）",
        )


class TestEnvTemplates(unittest.TestCase):
    """两个 env 模板必须都提供 INTERNAL_AUTH_TOKEN 这个键。"""

    def test_both_templates_declare_internal_auth_token(self):
        """deploy/.env 与 deploy/nginx.env 是两个独立文件，靠人去保持一致。

        两个模板都列出这个键，是"两边都该配"这个前提在文档层的体现。
        只校验键存在、不校验值 —— 值由 deploy/set_internal_token.sh 写，
        且永远不入库。
        """
        for path in (ENV_EXAMPLE, NGINX_ENV_EXAMPLE):
            with self.subTest(file=path.name):
                text = _read(path)
                self.assertRegex(
                    text, r"(?m)^INTERNAL_AUTH_TOKEN=",
                    f"{path.name} 里没有 INTERNAL_AUTH_TOKEN= —— "
                    f"少了它，那边就只能靠猜或者干脆不配，而两边不一致的表现是"
                    f"/api/* 全 401、/healthz 却照常 200（见 nginx.env.example 的说明）",
                )


class TestFrontendIsEnvironmentIndependent(unittest.TestCase):
    """前端源码里不得出现硬编码的后端绝对地址。

    这是「同一个前端镜像在任何环境都能用」的第一道防线（第二道在 CI 的
    frontend job：扫**构建产物**）。两道都要：源码层能让人在 PR 里就看见
    失败原因，bundle 层才能抓住 NEXT_PUBLIC_* 构建期内联这类只在构建时
    发生的泄漏。

    正确做法是 frontend/src/lib/api.ts 的 `BASE_URL ?? "/api"` —— 相对路径，
    由 nginx 承担代理。
    """

    # 后端与 mcp 的容器内端口。它们绝不该出现在前端代码里。
    _BACKEND_URL = re.compile(r"https?://[A-Za-z0-9._-]+:(8000|9000|8081)\b")

    def test_no_hardcoded_backend_urls_in_source(self):
        offenders: list[str] = []
        for path in sorted(FRONTEND_SRC.rglob("*")):
            if not path.is_file() or path.suffix not in {".ts", ".tsx", ".js", ".jsx"}:
                continue
            for lineno, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(), start=1
            ):
                if self._BACKEND_URL.search(line):
                    rel = path.relative_to(REPO).as_posix()
                    offenders.append(f"{rel}:{lineno}: {line.strip()}")

        self.assertEqual(
            offenders, [],
            "前端源码里出现了硬编码的后端绝对地址：\n  "
            + "\n  ".join(offenders)
            + "\n\n这会让镜像依赖构建时的环境，破坏「同一个镜像在任何环境都能用」。"
            "\n正确做法是相对路径 '/api' + nginx 代理（见 frontend/src/lib/api.ts）。",
        )


if __name__ == "__main__":
    unittest.main()
