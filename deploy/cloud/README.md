# 部署到国内云主机（免费试用机）

面向"没有现成服务器、想用免费额度跑起来"的场景。全程只需要一台能 SSH 的
Ubuntu 虚拟机 —— 这一点没有别的选择，理由见下面第一节。

## 一、为什么必须是云主机

这个栈里的 `dind` 容器要 `privileged: true`（它自己跑一个 dockerd，用来创建
沙箱容器）。所有免费 PaaS —— Render、Koyeb、Railway、Hugging Face Spaces、
Northflank —— 都禁止特权容器，部署上去会在创建 dind 那一步直接失败。所以只能
落到一台真虚拟机上，国内三家的免费试用正好符合"不需要信用卡"这个条件。

（Oracle Cloud 的 Always Free 是技术上最合适的 —— 4 核 24G ARM 永久免费 ——
但注册时普遍要求绑卡验证，与你的约束冲突，所以不在推荐里。）

## 二、选机器

三家都是**实名认证**而非信用卡，具体规格随时会调整，以活动页为准：

| 厂商 | 入口 | 时长（2026-09 前后） | 说明 |
|---|---|---|---|
| 阿里云 | free.aliyun.com | 试用金形式，个人版 300 元 / 约 3 个月 | 规格可选，2核4G 在额度内 |
| 腾讯云 | cloud.tencent.com 免费体验馆 | 轻量 1 个月，活动期可达 3 个月 | 轻量应用服务器上手最省事 |
| 华为云 | huaweicloud.com 免费试用 | 30 天，每日 9:30 限量抢 | 部分套餐要绑卡，看清再领 |

**规格怎么挑（这个比时长重要）：**

- **内存**：`frontend` 的 `next build` 峰值 1.5GB 以上，`2核2G` 必须靠 swap 才
  过得去，`2核4G` 才舒服。bootstrap 检测到内存 < 3.8G 会自动建 4G swap。
- **磁盘**：镜像（mongo 1.1G + 应用 890M + 前端 310M + 基础镜像）加构建缓存
  8–10GB，构建过程还会翻倍。**40GB 起步**，bootstrap 会在 < 25GB 时警告。
- **带宽**：1–3Mbps 的试用带宽，`scp` 传包和构建拉依赖会慢，但包只有 300KB 左右
  （见下），主要开销在拉 npm/pip 依赖上，走的是公网下行，不计入带宽上限。

**试用期的两个坑：**

1. 到期实例会被**自动释放，数据不保留**。有价值的数据提前 `mongodump` 走。
2. 领的时候把"自动续费"的勾去掉，并设个到期提醒，否则试用结束按原价扣。

## 三、部署

### 1. 本机打包

仓库里的内容已经可以直接 `git clone`，但打包更省事：跳过 `.venv`（461MB Windows
二进制）、`frontend/node_modules`（418MB）和 `.git`，产物实测约 300KB。

```bash
cd /path/to/Agent-Harness
bash deploy/cloud/pack.sh /tmp/erp-agent-deploy.tar.gz
```

脚本会排除全部**含密钥的文件** —— `deploy/.env`、`deploy/nginx.env`、
`deploy/nginx/htpasswd` —— 它们在服务器上由 `bootstrap.sh` 重新生成（`nginx.env`
从模板 `deploy/nginx.env.example` 复制）。打包完脚本会自己抽查一遍，发现这几个
路径出现在包里就直接失败退出。

### 2. 传到服务器

```bash
scp /tmp/erp-agent-deploy.tar.gz root@<服务器IP>:/root/
ssh root@<服务器IP>
mkdir -p /root/erp-agent && tar -xzf /root/erp-agent-deploy.tar.gz -C /root/erp-agent
cd /root/erp-agent
```

### 3. 一键初始化

```bash
DEEPSEEK_API_KEY=sk-xxxx bash deploy/cloud/bootstrap.sh <服务器IP或域名>
```

它会依次：装 Docker（走阿里云 apt 源）→ 写 `/etc/docker/daemon.json`
（镜像加速 + 日志轮转 + 把容器网段挪到 `10.201.0.0/16` 避开云 VPC）→ 必要时建
swap → 从 `.env.example` 生成 `deploy/.env`（随机 Mongo 密码、`PUBLIC_BASE_URL`
指向你的 IP）→ 生成 nginx 共享密钥与 Basic Auth 账号 → 构建 → 启动 → 等 healthy。

2 核机器上 `next build` 十几分钟是正常的。结束时它会打印**登录用户名和随机密码
（只打印这一次）**。

### 4. 开安全组

脚本改不了云控制台。去控制台给实例的**入方向**放行 `TCP 80`，来源 `0.0.0.0/0`。
不开的话 `curl localhost` 通、外网打不开，很容易误判成服务没起来。

## 四、验收

在服务器上：

```bash
cd /root/erp-agent
docker compose ps                                    # 七个服务，除 loader 外全 healthy
curl -s -o /dev/null -w '%{http_code}\n' localhost/healthz   # 200
curl -s localhost/health                             # {"status":"ok"}
```

在本机浏览器打开 `http://<服务器IP>`，用上面打印的账号登录，发一句
"查一下供应商列表" 看是否流式返回。再试一次图表类需求（"把库存预警画成柱状图"），
那条会真正走沙箱执行代码，能验证 dind 那一层。

## 五、安全

- nginx 的 Basic Auth 挡在最外层，弱密码等于没有。想换密码：
  `LOGIN_USER=admin LOGIN_PASSWORD=新密码 bash deploy/cloud/bootstrap.sh <IP>`。
- **`INTERNAL_AUTH_TOKEN` 必须配**（bootstrap 已自动配好）。不配的话，沙箱里模型
  生成的代码可以绕过 nginx 直连 backend 伪造 `X-Authenticated-User`，读到任意
  用户的会话 —— 见 `deploy/README.md`「认证是怎么工作的」注意二。
- 目前是 **HTTP 明文**。要用 HTTPS，在 nginx 前面再加一层，或把证书挂进
  `deploy/nginx/` 后改 `nginx.conf` 加 443 server 块；有域名的话这步值得做。
- Basic Auth 是明文传凭据的，没有 HTTPS 就只适合自己临时用，别放真实业务数据。

## 六、日常运维

```bash
docker compose logs -f backend            # 后端日志
docker compose restart backend            # 重启后端（沙箱不会丢，映射持久化在 Mongo）
docker compose down                       # 停栈（数据卷保留）
docker compose up -d                      # 再起

# 备份 Mongo
docker compose exec -T mongo mongodump --uri="$MONGODB_URI" --archive=/tmp/dump.gz --gzip
docker compose cp mongo:/tmp/dump.gz ./dump-$(date +%F).gz
```

**改代码后更新**：本机重新 `pack.sh` → `scp` → 服务器上解压覆盖 → `docker compose up -d --build backend`。

## 七、常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 外网打不开，服务器上 `curl localhost` 正常 | 安全组没放行 80，去控制台加规则 |
| `frontend` 构建时被 Killed | 内存不够。确认 swap 生效：`swapon --show`；仍不行就换 2核4G |
| `sandbox-image-loader` 一直不退出 | dind 拉不到基础镜像。`docker compose exec dind docker info \| grep -A2 Mirrors` 看加速有没有生效 |
| 登录后所有请求 401 | `deploy/.env` 与 `deploy/nginx.env` 的 `INTERNAL_AUTH_TOKEN` 不一致。重跑 `sh deploy/set_internal_token.sh` 再 `docker compose up -d backend nginx` |
| 对话报 LLM 错误 | `deploy/.env` 里 `DEEPSEEK_API_KEY` 没填或无效；改完要 `docker compose up -d backend mcp`（`restart` 不重读 env_file） |
| 改了 `deploy/.env` 不生效 | 同上：env_file 在容器**创建**时注入，必须 `up -d` 重建而不是 `restart` |

## 八、更省事的替代方案

如果你只是想让别人能用一次，不想折腾云主机：找一台**已经在跑 Docker 的 Linux
机器**（自己的、公司的都行），把包传上去跑 `bash deploy/cloud/bootstrap.sh <它的
IP或域名>` 就行 —— 脚本除了装 Docker 那步，其余全平台通用。比申请免费额度快。
