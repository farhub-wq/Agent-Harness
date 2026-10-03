# deploy/runner —— self-hosted runner 与提权闸门

这一目录把**生产机本身**注册成一个 GitHub Actions runner，让「构建」和「发布」
两步都在同一台机器上完成 —— 没有镜像仓库，也就没有"推上去、拉下来"这条链路上
的一切失败模式（凭据、网络、tag 与 digest 不一致）。

| 文件 | 作用 |
|---|---|
| `install-runner.sh` | 幂等安装器：用户、闸门、sudoers、密钥目录、runner 本体、systemd 限额、builder |
| `erp-agent-deploy` | **提权闸门**。装到 `/usr/local/sbin/`，root:root 0755，是 runner 唯一的提权入口 |
| `ghrunner.sudoers` | 一行白名单。装到 `/etc/sudoers.d/ghrunner` |
| `runner-limits.conf` | runner 服务的 systemd 资源护栏（drop-in） |
| `setup-builder.sh` | 建带内存/CPU 限额的 buildx builder，并**断言**限额真的生效了 |
| `buildkitd.toml` | 那个 builder 的 registry 镜像配置（这台机器直连 Docker Hub 不通） |

## 安装

```bash
# 1) 把这一目录拷到生产机（在能连上生产机的终端里跑）
scp -r deploy/runner root@<prod>:/root/erp-agent/deploy/

# 2) 取注册令牌（一小时有效，**不要**存文件里）
curl -X POST -H "Authorization: Bearer $TOKEN" \
  https://api.github.com/repos/farhub-wq/Agent-Harness/actions/runners/registration-token

# 3) 在生产机上装（root）
RUNNER_TOKEN=<令牌> bash /root/erp-agent/deploy/runner/install-runner.sh
```

重复跑是安全的：已注册的机器不带 `RUNNER_TOKEN` 再跑一次，只会更新闸门、
sudoers、限额和 builder，然后重启服务。

> 第 1 步为什么是 `scp` 而不是让 CI 自己装自己：这是**先有鸡还是先有蛋**——
> 在 runner 装好之前，没有任何 CI 能跑到这台机器上。所以第一次必须人工把
> 文件推上去。之后 `deploy/runner/**` 会随正常的源码树同步一起更新（它不在
> `package.filter` 的排除项里），但**闸门本身不会自动重装**：跑安装器是人工动作。
> 这是刻意的 —— 一个能在生产机上自己改自己的提权闸门，就不是闸门了。

## 安全模型

### 前提：这个 runner 在 docker 组里

`ghrunner` 在 `docker` 组，而 docker 组**事实上等于 root**（`docker run -v /:/host`
就够了）。方案接受这一点，换来的是发布不必再套一层别的编排。

所以整个安全模型只有**一条**真正的前提：

> **这个 runner 永远不执行不可信来源的代码。**

仓库是 public，任何人都能提 PR。这条前提不是靠自觉，是靠
`deploy/ci/lint-workflows.sh` 强制的：`on:` 里有 `pull_request` 的 workflow，
**全文**不得出现自托管标签（沿 `uses:` 传递检查）。它由 PR 门禁自己运行，
所以"改坏它"这个动作本身首先过不了门禁。

### 提权闸门为什么存在（方案第二节在这里不完整）

方案写的是「runner 不用 sudo 提权，sudoers 只放单条 `systemctl restart`」。
实地看下来这个描述不成立：`deploy/cd/deploy.sh` 物理上必须是 root ——
它要 `rsync --chown=root:root` 写进 `/root/erp-agent`（`/root` 是 0700）、
读 `deploy/.env`（0600）、写 `deploy/cd/state/`（root 属主，那是回滚的真值源）。

所以「非 root 的 runner」与「发布要动生产树」之间必须有**一个**受控提权点。
`erp-agent-deploy` 就是那一个点，它靠三件事让 sudoers 那一行不变成通用的 root shell：

1. **参数白名单。** tag 只接受 `^sha-[0-9a-f]{12}$`，sha 只接受 40 位小写 hex，
   env 只接受 `production`。形状不对当场 `exit 64`，不 exec 任何东西。
   （收紧到这种程度之后，参数里不可能藏进 `:`、`/`、`..` 这类会被 compose
   或 docker 再解释一次的字符。）
2. **生产树路径写死。** 不接受环境变量覆盖 —— sudo 默认 `env_reset`，
   本来也传不进来。
3. **生产密钥由 root 读。** 冒烟口令和通知 webhook 在 `/etc/erp-agent/*.env`
   （root:root 0600），由闸门以 root 身份 source，**不经过 runner 的进程环境**。
   runner 从头到尾没有机会看到它们。

`sudoers` 那一行是：

```
ghrunner ALL=(root) NOPASSWD: /usr/local/sbin/erp-agent-deploy
```

`install-runner.sh` 的最后一步会断言三件事，缺一件就安装失败：
闸门是 `root:root 755`（ghrunner 改不了它 —— 能改它就等于能写任意 root 命令）、
`sudo -n` 真的跑得通、闸门**拒绝**了 `deploy production 'x; rm -rf /' aaaa`。

### 资源护栏为什么有两处

方案说「systemd slice 限制 runner 资源是唯一有效的办法」。这**只对了一半**：

- runner 自己的进程（checkout、跑 shell 脚本）确实受 `runner-limits.conf` 的
  `MemoryMax=1600M` / `CPUQuota=150%` 约束 —— 这部分方案说得对；
- 但 **BuildKit 的构建步骤不受它约束**。默认构建器跑在 dockerd 内部，构建容器
  归 `docker.service` 管，是 runner 那个 slice 的**兄弟**而不是子节点。也就是说
  一次 `docker build` 能把生产容器挤成 OOM，而 runner 的限额一声不吭。

所以限额落成两处：服务本身（drop-in），和 `setup-builder.sh` 建的一个
`docker-container` 驱动的 builder（`--driver-opt memory=1400m --driver-opt cpu-quota=150000`）。
构建步骤在那个容器里跑，限额因此真的落在构建上。

`setup-builder.sh` 建完之后会 `docker inspect` 断言 `HostConfig.Memory` 和
`CpuQuota` 与期望一致才罢休 —— 因为 **buildx 对不认识的 driver-opt 是静默忽略的**，
不断言就会得到一个"以为限住了"的假象，而"以为限住了"比"知道没限"更危险。

`buildkitd.toml` 是同一次实地排查的产物：这台机器直连 `registry-1.docker.io`
是 000 / 5.2s（不通），只有 `docker.m.daocloud.io` 可达。宿主 `daemon.json` 里的
`registry-mirrors` 只对宿主 daemon 生效 —— `docker-container` 驱动的 buildkitd
是**独立进程**，得单独给它这份配置，否则构建会卡死在一行看起来像网络抖动的
pull 错误上。

## 日常运维

```bash
# 服务状态与日志
systemctl status actions.runner.*.service
journalctl -u 'actions.runner.*.service' -n 100 --no-pager

# 闸门的审计日志（每次调用一行：action/env/tag/sha/soak/by）
journalctl -t erp-agent-deploy --no-pager | tail -20

# 现在跑的是哪一版 / 发布是不是卡在半途
sudo /usr/local/sbin/erp-agent-deploy status production

# 回滚能力还在吗（0 = 在，1 = 丢了）
sudo /usr/local/sbin/erp-agent-deploy rollback production --check
```

**回滚能力巡检**值得挂个 timer。丢回滚能力的典型路径是构建保留策略或人工
`docker image prune` 把上一版的镜像删了 —— 而这件事只在你想回滚的那一刻才暴露。
`rollback --check` 就是为此存在的：它验 prev 快照完整、prev 的镜像还在且 digest
没变、prev 的 commit 还能从裸仓库取到，**不修改任何东西**。

一个 10 分钟的 timer 示例（`--check` 路径刻意装在通知 trap 之前，所以不会刷屏）：

```ini
# /etc/systemd/system/erp-agent-rbcheck.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/erp-agent-deploy rollback production --check
```
```ini
# /etc/systemd/system/erp-agent-rbcheck.timer
[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
```

## 排错

| 症状 | 原因 / 处置 |
|---|---|
| Actions 页面看不到这台 runner | runner 服务没起来，或注册用的仓库不对。`systemctl status` + `journalctl` |
| job 卡在 "Waiting for a runner" | 标签不匹配。workflow 要的是 `[self-hosted, erp-agent-prod]`，安装时的 `RUNNER_LABELS` 也得是 `erp-agent-prod`（自托管 runner 自动带 `self-hosted` 标签，不用手写） |
| `sudo -n ... not allowed` | `/etc/sudoers.d/ghrunner` 没装或语法被 `visudo` 拒了。重跑 `install-runner.sh` |
| 构建卡在拉基础镜像 | `buildkitd.toml` 的镜像源没生效。改完要 `docker buildx rm <builder>` 后重跑 `setup-builder.sh` —— `--config` **只在 create 时读一次** |
| `builder 容器的内存限额没生效` | buildx 版本不认那个 driver-opt。别绕过这条断言，先查 `docker buildx version` |
| 发布报「影子启动未通过」 | 新镜像有问题，**生产没被动过**。看影子容器日志尾部（`cd_shadow` 会打出来）。上游 LLM 临时不可达时用 `shadow_llm=false` 降级 |
| 通知没到 | 通知失败**不会**让发布失败，所以它可能悄悄没发。检查 `/etc/erp-agent/notify.env`，手工验证：`deploy/cd/notify.sh --dry-run --event deploy_succeeded` |
| 磁盘满 | 镜像保留策略在 `build.sh` 里（每镜像最近 5 个 `sha-*`，且从不 `prune -a`）。构建缓存在每次构建后回收。**不要**手工 `docker image prune -a`，那会一并删掉回滚用的上一版 |
