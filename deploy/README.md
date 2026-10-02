# 部署说明

> 在一台**全新的云主机**上从零部署（装 Docker、配镜像加速、建 swap、生成
> `deploy/.env` 与登录账号、构建、起服务、等 healthy）用
> [cloud/README.md](cloud/README.md) 的一键脚本，不用照着手工敲。
> 本文档讲的是栈本身怎么工作、怎么运维、出问题怎么查。

## 架构

```
浏览器 :80 ──Basic Auth──▶ nginx
   │
 nginx ──/api/chat/──→ backend:8000   (proxy_buffering off，长超时)
   │    ──/api/──────→ backend:8000
   └────/───────────→ frontend:3000
                          │
 backend ──→ mongo:27017 / mcp:9000 / mock-erp:8081
    │                       ▲
    └──DOCKER_HOST──→ dind:2375 ──→ erp-sandbox-* 容器
                                    └── mcp-sandbox 网络 ──→ mcp:9000
```

沙箱走 `docker:dind` sidecar，而不是挂宿主机的 `/var/run/docker.sock`。好处是沙箱容器被圈在 dind 自己的镜像/容器存储里，删掉 `dind-data` 卷就等于清空所有沙箱，也不在宿主机上留下任何容器。

**但这不等于安全隔离**：backend 能驱动 daemon API，而 dind 是 `privileged`，逃逸到宿主机 root 的路径依然存在（与挂 socket 同级）。只应部署在受控网络里。

## 快速开始

```bash
cp deploy/.env.example deploy/.env
# 编辑 deploy/.env：至少填 DEEPSEEK_API_KEY 和 PUBLIC_BASE_URL

# 生成 nginx ↔ backend 的共享密钥（不生成也能起来，但那道校验是关的，见下）
cp deploy/nginx.env.example deploy/nginx.env
sh deploy/set_internal_token.sh

# 创建登录账号（不建的话 nginx 起不来，见下）
docker run --rm httpd:2.4-alpine htpasswd -nbB 张三 '你的密码' > deploy/nginx/htpasswd

docker compose up -d --build
docker compose ps          # 等所有服务变成 healthy
```

浏览器打开 `http://<服务器地址>/`，会弹出登录框。

`PUBLIC_BASE_URL` 必须是浏览器能打开的地址（如 `http://192.168.1.50`），它决定 Agent 生成的下载链接指向哪里。填 `localhost` 的话用户点链接会指向自己的机器。

### 创建登录账号

整个服务（包括前端页面）都在 nginx 的 HTTP Basic Auth 后面。`deploy/nginx/htpasswd` 是标准 htpasswd 文件，用任意一种方式生成：

```bash
# 方式一：借用 httpd 镜像，-B 用 bcrypt
docker run --rm httpd:2.4-alpine htpasswd -nbB 张三 '密码' >> deploy/nginx/htpasswd

# 方式二：本机有 apache2-utils / httpd-tools
htpasswd -cB deploy/nginx/htpasswd 张三

# 方式三：只有 openssl（MD5-crypt）
printf '张三:%s\n' "$(openssl passwd -apr1 '密码')" > deploy/nginx/htpasswd

chmod 644 deploy/nginx/htpasswd
docker compose restart nginx     # 改完账号只需重启 nginx
```

加第二个用户时注意：**方式一/方式三用 `>>` 追加，不要用 `>`**，否则会覆盖掉已有账号（方式二的 `-c` 只在第一次创建时用）。

`deploy/nginx/htpasswd` 已在 `.gitignore` 里，不要提交（`deploy/nginx.env` 同理，
它装的是下面那个共享密钥；仓库里只留 `deploy/nginx.env.example` 模板）。

### 认证是怎么工作的

```
浏览器 ──Basic Auth──▶ nginx ──X-Authenticated-User: $remote_user──▶ backend
```

backend 在 `AUTH_MODE=proxy` 下：

- 请求头缺失 → **401**。所以 nginx 里漏配某个 location 不会静默放行，只会报错。
- 用 nginx 给的用户名派生 `user_id`，并**丢弃**请求体/查询串里的 `user_id`。

第二条是这次改造的重点。改造前 `user_id` 由前端硬编码成 `user-001`，所有浏览器共享同一份历史、同一个沙箱；`/api/chat/{id}/history`、`/api/history/{id}/messages`、`DELETE /api/history/{id}` 更是连归属校验都没有，知道 thread_id 就能读写删除别人的会话。现在这些接口一律校验归属，跨用户访问返回 403。

用户名到 `user_id` 的映射是 `<清洗后的用户名>_<sha256 前 8 位>`，例如 `张三` 全是非 ASCII 字符，会变成 `user_<hash>`。日志里会打印这个映射，排查"某个沙箱是谁的"时看 `docker compose logs backend | grep Ignoring`。

**注意一**：`AUTH_MODE=proxy` 的前提是 backend 不对宿主机发布端口。compose 里 backend 确实没有 `ports`；一旦你给它加上 `ports`，任何人都能伪造这个头。

**注意二**：不发布端口还不够。backend 与 `dind` 同在一张 Docker 网络上（要用 `DOCKER_HOST=tcp://dind:2375`），而沙箱容器跑在 `dind` 自己的 daemon 里，出口流量经 `dind` MASQUERADE 后就落在同一张网上 —— **沙箱里模型生成的代码可以绕过 nginx 直连 `backend:8000`，自己填一个别人的用户名，读到别人的会话历史**。

堵法是共享密钥：nginx 把 `INTERNAL_AUTH_TOKEN` 渲染成 `X-Internal-Auth` 注入每个 `/api` 请求，backend 校验它。这个值只存在于 nginx 与 backend 的进程环境里，沙箱代码拿不到。

```sh
cp deploy/nginx.env.example deploy/nginx.env   # 首次；该文件不入库
sh deploy/set_internal_token.sh          # 生成密钥，一次写入 deploy/.env 与 deploy/nginx.env
docker compose up -d backend nginx       # env_file 在容器创建时注入，restart 不重读
```

留空 = 不校验（本机开发默认），此时 backend 启动日志里会有一条 `without INTERNAL_AUTH_TOKEN` 的 WARNING。**对公网部署务必设置。**

验证：`PYTHONIOENCODING=utf-8 .venv/Scripts/python.exe ../erp-verify/v16_internal_token.py`（仓库外的验证脚本，两阶段跑：先复现漏洞，再证明开启后被 401）。

## 前置条件

- Docker Engine 24+ / Compose v2
- 宿主机文件系统 `ext4` 或 `xfs`（`xfs` 需要 `ftype=1`：`xfs_info / | grep ftype`）
- 出网：`api.deepseek.com`（LLM）+ 镜像仓库（dind 要拉 `python:3.11-slim`）
- 至少 4GB 可用内存（每个沙箱容器 `mem_limit=512m` + 预热池）

## 日常运维

> 正式发布/回滚走 `deploy/cd/`（`deploy.sh` / `status.sh`），见
> **[deploy/cd/README.md](cd/README.md)**。下面的手工命令适合本机调试，
> **不要**用来给生产换版 —— 手工 `up` 会让状态文件与实际运行的镜像脱节，
> `status.sh` 会报不一致。

```bash
docker compose logs -f backend          # 应用日志
docker compose restart backend          # 改完 src/skills 后必须重启（见下）
docker compose exec dind docker ps      # 看沙箱容器

# 查看生成的下载文件
docker run --rm -v erp-agent_download-data:/d alpine ls -l /d

# 备份（只有 Mongo 需要备份）
docker compose exec mongo mongodump --archive --gzip > backup-$(date +%F).gz
```

`dind-data` 不需要备份：丢了之后 `_restore_from_mongodb` 会走容器不存在分支、清理缓存并重建。

### 改了 `src/skills/` 之后

`src/skills` 是 bind mount，**镜像里那份被完全遮蔽**。改了仓库里的 skill 之后：

```bash
docker compose restart backend     # 让 SkillsSyncMiddleware 重新扫描
```

只 `docker compose up -d --build` 不生效——重建镜像不会改变挂载内容。

### 改了后端代码之后

```bash
docker compose up -d --build backend mcp
```

backend 和 mcp 共用同一个镜像（`erp-agent-app:local`），要一起重建。

## 已知限制

### 只能单副本

`SandboxManager._entries` / `sandbox_holder._sandboxes_by_user` / `AgentLoader._sessions` 全是**进程内状态**，MongoDB 只持久化了 `user → container_name` 映射。

`--scale backend=2` 或 uvicorn `--workers 2` 会**立刻坏**（不是性能退化）：两个副本各自从预热池认领同一个容器、互相覆盖 `sandbox_cache`、给同一 `user_id` 建不同 Agent。dind 同样是 SPOF。

### 认证的边界

认证解决了"谁能进"和"谁的会话是谁的"，但有两处没覆盖：

- **下载目录是全局共享的**。`/api/download/{filename}` 要求登录，但任何已登录用户拿到文件名就能下载别人的报告。文件名是 `<名称>_<时间戳>.md` 这类可猜格式。要严格隔离得让生成工具按 `user_id` 分目录。
- **审批中断是每人一份，但审批本身没有权限分级**。写操作（下单/改单）的待审批项按用户隔离，但任何登录用户都能批准自己发起的单。

**2026-09-26 更新**：沙箱代码够到 `backend:8000` 这条通路**本身没有被关闭**（dind 与 backend 必须同网，否则 backend 连不上 dockerd），但它的后果已经被降级：配了 `INTERNAL_AUTH_TOKEN` 后，伪造的 `X-Authenticated-User` 会因为没有 `X-Internal-Auth` 而被 401。**未配该密钥的部署，沙箱代码可以冒充任意用户读取其会话 —— 见上面「认证是怎么工作的」里的注意二。**

### 沙箱内访问 MCP

已接通，但默认只有配了 `SANDBOX_MCP_URL` + `SANDBOX_MCP_HOST_IP` 才生效（`deploy/.env.example` 里已给出可用值）。

链路：

```
沙箱容器 ──/etc/hosts: mcp=172.31.0.10──▶ dind 网关 ──转发+MASQUERADE──▶ mcp:9000
```

为什么绕这么一圈：沙箱容器跑在 dind 自己的 bridge 网络里，既解析不了 compose 服务名（dind 的内嵌 DNS 不认识 `mcp`），也和 mcp 不在同一个二层网络。所以由 backend 把 mcp 在 `mcp-sandbox` 网络上的**静态 IP** 写进沙箱容器的 `/etc/hosts`。用静态 IP 而非每次解析，是为了让 mcp 重建换 IP 后沙箱里的地址依然有效。

`mcp-sandbox` 网络刻意只放 `mcp` 和 `dind`，**不能让 dind 挂到 `data` 上** —— 那样沙箱里模型生成的代码就能顺着 dind 的路由够到 `mongo:27017`（`internal: true` 只挡出网，不挡同宿主机上网络之间的转发）。

Agent 侧怎么知道能用：`src/agent/memory/AGENTS.md` 里让它先跑 `os.getenv("MCP_SERVER_URL")` 自己判断，为空就不要尝试。所以没配这条通路时，Agent 不会去撞墙。

**改静态 IP 要同步改两处**：`docker-compose.yml` 里 mcp 的 `ipv4_address` 和 `deploy/.env` 的 `SANDBOX_MCP_HOST_IP`。

**沙箱镜像里没预装 MCP 客户端**，脚本需要自己 `pip install mcp`（装进 `/workspace/python-packages`）。这会让每次沙箱冷启动多一次几十秒的安装。要消掉就自己烘一个装了 `mcp` 的沙箱镜像，把 `SANDBOX_IMAGE` 指过去。

### 其它

- `/workspace` 挂载带 `noexec`：Agent 生成的 `./script.sh` 和编译产物无法直接执行（`python x.py` 可以，因为被 exec 的是 `/usr/local/bin/python`）。这是既有行为。
- mock ERP 的数据是**内存态**，重启即重置，种子数据固定（`random.Random(42)`）。
- 容器以 root 运行。改成非 root 需要额外处理 `./src/skills` 与 `download-data` 的属主。

## 故障排查

**backend 起不来，日志里有 `falling back to LocalShell` 或 `ALLOW_LOCAL_SHELL_FALLBACK`**

这是设计行为。容器里设了 `ALLOW_LOCAL_SHELL_FALLBACK=false`，沙箱不可用时**直接失败**而不是退回本机执行——否则会在 backend 进程环境（含 `DEEPSEEK_API_KEY`）里跑模型生成的代码。检查 `docker compose logs dind` 和 `docker compose exec dind docker info`。

**图表功能时好时坏**

沙箱内 `chart_generator` 会运行时 `pip install matplotlib numpy`，写进 `/workspace`（tmpfs）。确认 dind 能出网，或预先烘一个装了这些包的沙箱镜像并把 `SANDBOX_IMAGE` 指过去。

**重启后 dind 里堆了一批 `erp-sandbox-warm-*`**

`prune_orphans()` 已在 backend 启动时清扫。如果仍在堆积，说明 dind API 在 backend 启动时不可用（日志里会有 `Orphan prune skipped`），重启 backend 即可。

**nginx 起不来，日志里 `open() "/etc/nginx/htpasswd" failed` 或 `is a directory`**

`deploy/nginx/htpasswd` 不存在或是个目录。Docker 在 bind mount 的源路径不存在时会**自动建一个同名目录**，所以第一次 `up` 很可能把仓库里那个路径变成一个空目录。清掉再按「创建登录账号」生成：

```bash
rm -rf deploy/nginx/htpasswd
printf 'admin:%s\n' "$(openssl passwd -apr1 '你的密码')" > deploy/nginx/htpasswd
docker compose up -d nginx
```

**所有接口都返回 401，但明明登录了**

backend 收到的 `X-Authenticated-User` 是空的。检查 `deploy/nginx/nginx.conf` 里三个 location 是否都还在设这个头，以及请求是不是绕过了 nginx 直连 backend（直连必 401，见「认证是怎么工作的」）。

**日志里出现 `Ignoring client-supplied user_id`**

有客户端在试图指定别人的身份。正常情况下不该出现 —— 前端传的 `user-001` 会被覆盖，所以只在 AUTH_MODE 切换过程中或有人手工构造请求时看到。

**nginx 502**

`docker compose ps` 看 backend/frontend 是否 healthy。启动顺序是 mongo → mock-erp → mcp → dind → sandbox-image-loader → backend → frontend → nginx，backend 的 `start_period` 是 90s（要建预热池）。

**沙箱里 `curl http://mcp:9000` 失败**

按顺序查：`deploy/.env` 的 `SANDBOX_MCP_URL`/`SANDBOX_MCP_HOST_IP` 是否都非空；`docker compose exec dind docker exec erp-sandbox-xxx cat /etc/hosts` 看有没有 `mcp` 那行；`docker compose exec dind ping -c1 172.31.0.10` 看 dind 自身能否够到 mcp。注意**已有的沙箱不会自动获得新配置**，改完要 `docker compose restart backend` 让它重建容器（或等 30 分钟空闲回收）。

**改了 `deploy/.env` 里的 MongoDB 账号密码但不生效**

`MONGO_INITDB_ROOT_*` 只在数据卷**首次初始化**时生效。要重建：`docker compose down -v`（会删掉所有数据）。
