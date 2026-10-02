# deploy/cd —— 发布与回滚

生产栈的发布/回滚由这里的三个脚本负责，**只在部署机上跑**。

| 文件 | 作用 |
|---|---|
| `lib.sh` | 共享库：环境常量、compose 包装、锁、状态文件、健康与冒烟。被下面两个 source |
| `deploy.sh` | `deploy` / `init` / `rollback`（含 `--check`） |
| `status.sh` | 只读巡检，给 systemd timer 和运维人用 |
| `package.filter` | rsync 同步源码树时的排除/保护清单 |

## 用法

```bash
# 发布：同步到 <sha> 的源码树，换到 <tag> 的镜像
bash deploy/cd/deploy.sh deploy production sha-79c3c3a1b2c3 79c3c3a1b2c3...（40 位）

# 首次接管一台已经在跑的机器：树和镜像都在本机，只建立状态文件
bash deploy/cd/deploy.sh init production local 79c3c3a1b2c3...

# 回滚到上一版
bash deploy/cd/deploy.sh rollback production

# 只校验「回滚能力还具备吗」，不执行（0 = 具备，1 = 不具备）
bash deploy/cd/deploy.sh rollback production --check

# 巡检
bash deploy/cd/status.sh
```

`<tag>` 与 `<sha>` 是两件事：tag 选镜像，sha 选源码树。**两个都要填** ——
只换镜像不同步树，会让「运行中的代码」和「状态文件记的版本」脱节。

冒烟的深链路（`/` 与 `/api/history`）需要 Basic Auth 凭据，从环境变量注入：

```bash
SMOKE_BASIC_USER=admin SMOKE_BASIC_PASSWORD=xxx bash deploy/cd/deploy.sh deploy ...
```

不传这两个变量只会探 `/healthz` 与 `/health`，**前端与 /api 链路不被验证**，
脚本会明确告警。

## 退出码

CI 靠退出码区分处置方式。

| 码 | 含义 | 生产状态 |
|---|---|---|
| 0 | 成功 | 新版在跑 |
| 1 | 前置检查失败 | **完全没动过** |
| 2 | 备份失败 | **完全没动过** |
| 3 | 同步失败 | 已还原源码树，业务未受影响 |
| 4 | 影子启动失败 | **完全没动过**，生产未受影响 |
| 5 | 换版后验证失败，已自动回滚 | 旧版在跑，但要看日志找原因 |
| 6 | 观察窗失败，已自动回滚 | 同上 |
| 7 | **回滚也失败** | 服务可能是坏的，需要人立刻介入 |

注意：**回滚成功是 5，不是 0**。回滚不算发布成功。

## 两条不能碰的死线

`lib.sh` 的 `cd_compose()` 在代码层禁掉了三个动词，不是靠注释提醒：

- `docker compose down` —— 重建网络会让 `mcp-sandbox` 的静态 IP 变化，而沙箱容器
  `/etc/hosts` 里写死的地址不会跟着变，沙箱内所有 MCP 工具挂掉。
- `docker compose prune` / `rm` —— 删掉未被运行容器引用的镜像，也就是**全部历史
  版本**，回滚能力瞬间归零，不可逆。

同理，**永远不要在部署机上跑 `docker system prune -a`**。

## 架构约束（决定了这套脚本的形状）

**A. backend 必须单副本。** 沙箱注册表、会话、AgentLoader 全是进程内状态。
每次发布必然停机重建（实测换版 44s、回退 39s，SSE 实断约 20s）。

**坏版本的停机窗口是 ~140s，不是 44s。** 差别在 `docker compose up -d`：它自己会为
`depends_on` 的健康条件阻塞，镜像永远不达标时要等到 backend 的
`start_period(90s) + interval(15s)` 才放弃（实测约 100s，这期间容器是坏的）。所以
`cd_apply_and_verify` 把 compose 的非 0 退出当成第一道判据，**不再**接着空等
`cd_wait_healthy` 的 120s —— 否则窗口会变成 ~260s。

反过来的写法（把 `up -d` 放后台、只等健康）**试过，是错的**：`cd_wait_healthy` 会判在
换版**前**那批还 healthy 的旧容器上直接通过，部署报成功而新镜像根本没起来。`up -d`
必须前台跑完再判健康 —— 它的返回值同时回答了两件事：「容器确实换成新的了」和
「依赖链活了」。

**B. 宿主源码树是部署产物的一部分。** 四个 bind mount 把宿主文件直接喂进容器：

| 宿主路径 | 挂进 | 换文件后何时生效 |
|---|---|---|
| `src/skills` | backend `/app/src/skills` | backend 重建时 |
| `deploy/nginx/nginx.conf` | nginx `/etc/nginx/nginx.conf` | **仅当 nginx 被 recreate** |
| `deploy/nginx/templates/` | nginx `/etc/nginx/templates` | **仅当 nginx 被 recreate** |
| `deploy/dind-daemon.json` | dind `/etc/docker/daemon.json` | 仅当 dind 被 recreate（危险） |

推论一：**回滚必须同时回滚源码树**，否则会出现「镜像旧、配置新」。
推论二：`up -d` **不会**因为 bind mount 的文件**内容**变了而重建容器。改了
`deploy/nginx/**` 就必须 `--force-recreate nginx`，否则新配置静默不生效 ——
`deploy.sh` 用 `NGINX_TREE_SHA256` 的比对自动做这件事（`--no-deps`，防止连带
重建 dind 杀掉正在跑的沙箱容器）。

**C. 换版只覆盖四个服务。** `state/<env>.override.yml` 只改 mock-erp / mcp /
backend / frontend 的 `image`。mongo / dind / nginx / sandbox-image-loader 不动。
**这是刻意不修改仓库里 `docker-compose.yml` 的原因**：生产树是同步出来的，改它
下次同步就没了。

## 同步源码树

`git archive <sha>` → `rsync -a --delete --chown=root:root --filter`。取源是一个
**裸镜像仓库 `/srv/erp-agent.git`**，所以同步和回滚都不依赖 GitHub 可达，也不依赖
工作区是否干净 —— 物理上只可能同步已提交的内容。

三个细节不是洁癖：

- `--delete` 让新 commit 里**被删掉的文件**也从目标机消失（`tar -x` 覆盖做不到）。
- `--chown=root:root` 是必须的：生产树现在的属主是 `tar` 从 Windows 带过来的
  `197609:197121`，不加这个参数 rsync 会忠实地把它一路保留下去。
- 不用 `--inplace`：rsync 默认「写临时文件再 rename」，正在跑的 bash 持有旧
  `deploy.sh` 的文件描述符，改名不影响它；`--inplace` 会就地覆盖正在执行的脚本。

`package.filter` 保护四类东西：四个密钥文件、`deploy/cd/state/`、`node_modules`
之类的构建产物、以及环境模板的例外（`.env.example` 必须进包，否则新机器的
`bootstrap.sh` 生成不出 `deploy/.env`）。

## 路径分级：哪些改动不允许自动应用

| 类别 | 路径 | 处理 |
|---|---|---|
| 自动发布 | `src/**`、`frontend/**`、`deploy/mock-erp/**` | 正常流程 |
| 自动发布 + 强制重建 nginx | `deploy/nginx/**` | 自动 `--force-recreate nginx` |
| **默认拒绝** | `docker-compose.yml`、`deploy/dind-daemon.json` | 检出变化即失败。重建 dind 会停掉在跑的沙箱容器；要自动应用须显式 `CD_ALLOW_INFRA_CHANGE=1` |
| 永不触碰 | `deploy/.env`、`deploy/nginx.env`、`deploy/nginx/htpasswd`、`deploy/cd/state/**` | 同步时排除；密钥轮换永远是人工动作 |

## 状态文件

`state/production.env` 是「这台机器现在跑的是哪一版」的唯一真值源，`state/production.prev.env`
是上一版。`state/history/` 留每次发布/回滚的记录。

关键字段：`VERSION`、`GIT_SHA`（回滚据此取源码树）、三个 `*_IMAGE`（compose 用的
引用）与对应的三个 `*_IMAGE_ID`（**权威 digest**）。tag 可以被重新指向，digest
不能 —— 回滚前会断言两者仍然一致，不一致就拒绝执行。

`state/production.pending.env` 存在 = **有一次发布卡在半途**。这是「发布没走完」
唯一可靠的信号，`status.sh` 会为它告警。

## 尚未实现（按方案的阶段推进）

这套脚本目前覆盖**阶段 2（同步与回滚）**。以下两处是刻意的占位，**跑起来会明确
告警**，不会假装做过了：

- **备份（阶段 5）**：还没有 `mongodump` + restore 自检。发布前不会备份数据库。
- **影子启动（阶段 4）**：新镜像没有在换版前单独起一次性容器验过。
- **观察窗（阶段 4）**：`CD_SOAK_SECONDS` 默认 0（关闭）。

配套的 GitHub Actions 工作流、self-hosted runner、systemd 资源护栏、通知、
可观测同样还没做。
