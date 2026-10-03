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
| `backup-dr.sh` | `backup-dr` job 的断言：起一个 mongo、跑真备份、跑恢复自检、**负向用例**、保留策略 |
| `migrate-e2e.sh` | `backup-dr` job 的断言：跑真迁移、验幂等、验内容被改 / 编号撞车会停住 |
| `dr-logic-test.sh` | 备份链路的**纯逻辑**桩测（不需要 Docker）：清单解析、区间边界、剪枝的保护集 |
| `migrate-logic-test.sh` | 迁移器的纯逻辑桩测：编号排序、账本比对、孤儿检测 |
| `patrol-logic-test.sh` | 巡检的纯逻辑桩测：指纹、差异摘要、「发布在跑吗」的年龄判据 |

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

## `backup-dr`：为什么备份链路也在 PR 门禁里

它不构建任何镜像（只起 mongo），是这批 job 里最便宜的一个，但护住的是最贵的东西。
理由是**备份链路失效的形态全是「看起来正常」**：

- 少备份了一个库 —— `checkpointing_db` 不在任何配置里（见
  [deploy/dr/README.md](../dr/README.md)），漏了它备份文件依然是好的、自检也是过的；
- 自检其实什么都没比 —— 比如 `counts.tsv` 丢了导致逐集合比对那个循环一条都不跑；
- 剪枝把要用的那份删了 —— 而它是回滚的真值源。

这三件事都不会报错，只会在真需要它的那一天暴露，而那天没有第二次机会。所以负向
用例比正向用例更重要：**一个只会说「通过」的 fail-closed 自检就是安慰剂**。

## `backup-dr` 首次真跑就抓到了东西（2026-10-03）

这个 job 存在的理由不是「多一道保险」，是**备份链路在本机根本跑不起来**：没有
Docker daemon，`cd_assert_tools` 必然失败。所以它第一次执行的回报就是它自己的
价值证明 —— 8 个 job 里只有它红，红的正是那条：

```
Invalid Options: Cannot specify different database in connection URI and command-line
option — `erp_agent` was specified in the URI and `checkpointing_db` was specified in
the --db option
```

`MONGODB_URI` 里带库名，备份又逐库传 `--db`，mongodump 直接拒绝。它死在**第一个
非 URI 库**上，也就是 `checkpointing_db` —— 那条路径在真机上意味着「第一次发布
没有备份」，而且不发布就不会暴露。修法见 `lib-dr.sh` 的 `DR_MONGO_URI_NODB_SH`
与 `dr-logic-test.sh` 里新增的用例。

**修完又红了一轮，而且是同一处手术的第二刀：**

```
error parsing uri: must have a / before the query ?
```

摘掉库名之后那个 `/` 必须留下（`mongodb://host:27017/?authSource=admin`）。
值得记的是**桩测在这一轮之前是全绿的** —— 断言里的期望值是我照错误的理解手写的。
这是这个 job 最该被记住的性质：桩测验证的是「代码符合我以为的规格」，规格本身
只能由真的 `mongodump` 来判。所以每次改动 `DR_MONGO_URI_NODB_SH`，**必须等到
这个 job 绿了才算完**，本机绿不算。

同一轮里另外两个「只能等 CI 才知道」的悬案也一起有了答案，而且都是好消息：
`stack-smoke` 在境外 runner 上通过 daocloud 镜像站拉 `python:3.11-slim` **能用**；
`auth-path` 也绿。所以那两个 job 从这一轮起不再是「写完没跑过」。

## 三个 `*-logic-test.sh`

它们跑在最前面（几秒钟出结果，且不需要 Docker）。覆盖的是
端到端用例碰不到的解析/比较路径 —— 而且巡检那条**只有在 CI 里能被自动验证**：它的
失效方式是「几天后悄悄不再告警」和「每次发布都发一条假告警」，两者在真机上都要等好
几天才看得出来，而后者会让人把整套通知静音掉。它们抓到过真问题（见
`deploy/ci/patrol-logic-test.sh` 与 `dr-logic-test.sh` 的文件头）。

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

## 这道门禁被验证过（2026-10-02，PR #5）

不是"写完了应该能用"，是拿一个真实的坏版本实测过。样本是把
`deploy/nginx/nginx.conf` 里 `location /api/` 的 `set $backend http://backend:8000;`
改成 `:9999` —— 语法正确、`set` 在、`proxy_pass` 在、所有 `proxy_set_header` 都在原位。

结果：**7 个 job 里只有 `auth-path` 变红，其余 6 个全绿**，包括 `stack-smoke`。
失败点正是预期的三条：

```
FAIL  GET /api/history（带凭据，nginx 注入正确令牌）           → 期望 200，实际 502
FAIL  GET /api/history（带凭据 + 客户端伪造内部令牌，应被覆盖）   → 期望 200，实际 502
FAIL  GET /api/history（带凭据 + 客户端伪造身份头，应被覆盖）     → 期望 200，实际 502
```

诊断信息直接给出了根因（`ci_dump` 的 nginx 尾巴）：

```
connect() failed (111: Connection refused) while connecting to upstream,
  request: "GET /api/history HTTP/1.1", upstream: "http://172.19.0.3:9999/api/history"

```

同一个 job 里那条直连探针仍然报 `no-token=401 with-token=200` —— backend 是好的，
坏的只有代理目标。这条对照很有用：它把故障范围缩到了 nginx 这一跳。

顺带记两条边界：

- `/healthz`、`/health`、`/` 在这个坏版本下**仍然 200**（它们各自有自己的 `set`,
  不受影响）。所以"探活全绿"从来不足以说明代理链路是好的 —— 这正是要按
  location 逐个断言的原因。
- `stack-smoke` 也放过了这个改动：它只探不经过 `/api/` 的 `/healthz`，不覆盖代理
  路径。这是刻意的分工（见上面的分工表），代价是**别把 stack-smoke 绿当成代理没事**。

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
