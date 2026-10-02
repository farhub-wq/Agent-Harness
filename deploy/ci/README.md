# deploy/ci —— PR 门禁里与集成相关的部分

这个目录装的是「CI 上真起一套栈」的那一半门禁。文件与分工：

| 文件 | 作用 |
|---|---|
| `lint-workflows.sh` | workflow 守卫：PR 可达的 workflow 里不得出现自托管 runner 的标签（含 `uses:` 传递闭包） |
| `compose.ci.yml` | `auth-path` job 的 compose 覆盖：把 `dind` 与 `sandbox-image-loader` 换成 alpine 替身 |
| `lib-ci.sh` | 两个冒烟脚本共用的库：compose 包装、健康轮询、诊断落盘 |
| `prepare-stack.sh` | 生成 `deploy/.env`、`deploy/nginx.env`、`deploy/nginx/htpasswd` 与一次性口令 |
| `smoke-edge.sh` | `auth-path` job 的断言：认证与代理链路（HTTP 层） |
| `stack-smoke.sh` | `stack-smoke` job 的断言：完整拓扑，含真 dind 与沙箱预热池 |

## 为什么断言是脚本，不是 workflow 里的 `run:`

阶段 2 的教训：那两个只有真机才发现的问题（坏版本的停机窗口是 134s 不是 44s、
把 `up -d` 放后台导致健康判定落在换版**前**那批旧容器上）都是靠「脚本能在命令行
单独重跑」定位的。塞在 YAML 里的断言只能在 CI 上盲目迭代，一次 push 换一个观测点。

所以 workflow 里只有 `bash deploy/ci/smoke-edge.sh` 这样一行，栈的起停、健康轮询、
断言矩阵、失败诊断全在脚本里。

## 两个 job 的分工

| | `auth-path` | `stack-smoke` |
|---|---|---|
| 拓扑 | mongo/mock-erp/mcp/backend/frontend/nginx 全真，`dind`+`loader` 是替身 | **一个都不换**，含 privileged 的真 dind |
| 管什么 | 认证边界、nginx→backend 的共享密钥链路、代理链路 | compose 文件本身、起栈顺序、沙箱基础镜像灌入、预热池真的建出容器 |
| 大约耗时 | 缓存命中 2 分钟 / 冷跑 6–8 分钟 | 6–10 分钟（大头是 dind 冷启动 + 往 dind 里拉 `python:3.11-slim`） |
| 为什么这样分 | 认证链路的失败会被 dind 的噪声淹没，两者混在一起分不清是谁坏了 | 它是**唯一**验证 `docker-compose.yml` 的地方，一个服务都不能替换 |

`auth-path` 里的镜像由 workflow 用 buildx 预建（`cache-from: type=gha`，scope 是
`app-auth` / `frontend-auth` / `mock-erp-auth` —— 带后缀是刻意的：与并发的
`frontend` / `build-verify` job 共用 scope 会让两个 job 同时导出同一个 cache key），
再让 compose 用本地镜像起栈；`stack-smoke` 刻意让 compose 自己 build，因为它要
验证的就是 compose 的 build 配置本身。

## 本机怎么重跑

需要 Docker（`stack-smoke` 还需要能跑 privileged 容器）。

```bash
bash deploy/ci/prepare-stack.sh    # 生成 deploy/.env / nginx.env / htpasswd / 口令
docker compose -f docker-compose.yml -f deploy/ci/compose.ci.yml up -d --no-build
bash deploy/ci/smoke-edge.sh       # 它会自己起栈 + 等健康 + 断言
docker compose -f docker-compose.yml -f deploy/ci/compose.ci.yml down -v
```

两个脚本自己都会 `up`，所以第二条命令可以省掉（列出来是为了说明它做了什么）。

**`prepare-stack.sh` 会覆盖 `deploy/.env` 与 `deploy/nginx.env`** —— 而那两份文件
在本机通常装着真实密钥（`DEEPSEEK_API_KEY`、真实的共享密钥）。脚本因此带了一条
防呆：目标文件已存在、且第一行不是它的标记时**直接拒绝**，除非显式 `CI_FORCE=1`
（那样它会先备份成 `*.bak.<时间戳>`）。在 CI 上这两个文件本来就不存在，所以这条
防呆不会挡到 CI。

## 断言矩阵，以及相对方案文档的一处改动

方案里那张矩阵的意图是「认证不能漏 location、共享密钥必须真在强制」。实现时发现
其中一行**照字面写不可能成立**：

> `GET /api/history` 带 Basic Auth、不带 `X-Internal-Auth` → 401

走 nginx 时这条永远是 200，因为 nginx.conf 里的
`proxy_set_header X-Internal-Auth $internal_token;` 是**无条件覆盖**：客户端带不带
这个头都一样，backend 只会看到 nginx 注入的那个正确值。这不是 bug，恰恰是设计
要的性质。

所以把它拆成了两条更有价值的断言，都写在 `smoke-edge.sh` 里：

1. **客户端伪造**：带凭据 + 一个错的 `X-Internal-Auth` → 仍然 200，证明 nginx 是
   覆盖而不是透传（哪天有人改成 `$http_x_internal_auth` 这类"尊重客户端"的写法，
   这条立刻红，而结构断言看不见）。
2. **绕过 nginx**：从一个挂在 `edge` 网络上的一次性容器直接打 `backend:8000`，
   带上伪造的 `X-Authenticated-User`、不带令牌 → **401**；带上正确令牌 → 200。
   这才是「共享密钥真在强制」的证据，也正是这道校验防的那个场景（沙箱里模型生成
   的代码直连 backend 伪造身份）。

最后还有一条负向验证：临时把 `deploy/nginx.env` 的令牌改成另一个值，带**正确**
Basic Auth 的 `/api/history` 必须变成 401。上面那些 200 也可能是"根本没在校验"
带来的，这一条排除那种可能。脚本用 `trap` 保证无论如何都把文件还原。

## 已经在 CI 上踩过并修掉的坑

这两条都是首轮跑 CI 才暴露的，记在这里免得有人"顺手改回去"：

- **`deploy/nginx/htpasswd` 必须是 644，不能跟着别的密钥一起收紧到 600。**
  nginx 的 master 是 root，但**真正打开这个文件的 worker 进程是 `nginx` 用户**，
  600 它读不了。症状极具误导性：`/healthz`（`auth_basic off`）照常 200、无凭据
  访问照常 401，**只有带凭据的请求全部 500**，access log 里唯一的线索是
  `open() "/etc/nginx/htpasswd" failed (13: Permission denied)` —— 看起来像应用炸了。
  这文件存的是 apr1 哈希不是明文口令（明文在 `.ci-credentials.sh`，那个是 600），
  而且生产机上按 `deploy/README.md` 生成的也是 644。见 `prepare-stack.sh` 末尾。
- **`stack-smoke` 必须显式传 `--build-arg` 换成官方源。** 这个 job 刻意让 compose
  自己 build，于是会用到 Dockerfile 里面向国内的默认值（`NPM_REGISTRY=npmmirror`、
  `PIP_INDEX_URL=阿里云`），而 runner 在境外——npmmirror 会返回
  `404 'electron-to-chromium@https://registry.npmmirror.com/...' is not in this registry`。
  404 得很像"包装不存在/依赖写错了"，其实是镜像站对境外 IP 的行为。
  `auth-path` 没这个问题，因为它的镜像由 workflow 用 buildx 预建、本来就带了官方源参数。

## 已知风险 / 待 CI 证实的东西

- **dind 拉沙箱基础镜像走的是 `deploy/dind-daemon.json` 里的 daocloud 镜像站**。
  那个镜像站在国内 ECS 上实测可用，但从 GitHub 的境外 runner 走是否可用**没有
  实测过**。dockerd 在镜像站不可达时应当回退到 Docker Hub，但如果它在
  `stack-smoke` 上超时，症状会是 `sandbox-image-loader` 非 0 退出。
- **Compose 版本对一次性服务的语义**：`lib-ci.sh` 刻意不用 `up --wait`（见那里的
  注释），健康判据统一由 `ci_wait_healthy` 做，就是为了不依赖那个各版本不一的语义。
- **端口 80**：`nginx` 发布的是 `${HTTP_PORT:-80}:80`，`prepare-stack.sh` 把
  `HTTP_PORT=80` 写进口令文件，免得本机项目根的 `.env` 插值出一个别的端口、
  让冒烟脚本打错地址。
