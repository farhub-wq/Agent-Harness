# deploy/dr —— 备份、异地、迁移、恢复演练

Mongo 里的数据和用户生成的报告文件是这套系统里**唯一没有第二份**的东西：镜像能
重建，源码在 git 里，`dind-data` 丢了会自动重建 —— 只有这两样丢了就是丢了。

| 文件 | 作用 |
|---|---|
| `backup.sh` | 备份主流程：枚举库 → dump → 恢复自检 → 剪枝 → 外推 |
| `restore-drill.sh` | 恢复演练：完整恢复一份已有备份 + 解出卷 + 产出报告 + 通知 |
| `migrate.sh` | 迁移执行器：从新 commit 取 `migrations/` → 按序执行 → 记 `schema_version` |
| `lib-dr.sh` | 共用原语：mongo 直连、库/集合名形状校验、备份产物记账 |
| `offsite.sh` | 把一份备份推到阿里云 OSS |
| `ossutil-install.sh` | 装 ossutil（真机上跑一次，写死版本与 sha256） |

发布链路上的接线在 [deploy/cd/README.md](../cd/README.md)：`cd_backup()` →
`backup.sh`，迁移 → `migrate.sh`（退出码 8）。本文档讲这些工具本身怎么用。

## 备份的是什么

**两个 MongoDB 库，而不是一个。** 这是本目录里最要紧的一件事：

| 库 | 谁在用 | 里面是什么 |
|---|---|---|
| `erp_agent` | 应用自己配的（`MONGODB_DB_NAME`） | 会话、展示消息、长期记忆、审计轨迹 |
| `checkpointing_db` | **`langgraph-checkpoint-mongodb` 的库默认值** | `checkpoints` + `checkpoint_writes`，也就是全部会话状态与 HITL 待审批状态 |

`checkpointing_db` 这个名字**不出现在任何配置或应用代码里** ——
`src/api_view/agent_loader.py` 构造 `MongoDBSaver(mongo_client)` 时没传 `db_name`，
于是它落到了库默认值上。后果很直接：一个「按 `MONGODB_URI` 里的库名 dump」的备份
会把会话历史整段丢掉，而且**不报任何错** —— 文件是好的、自检也是过的，只是少了一个库。

所以备份**运行时枚举**数据库（`listDatabases`，排除 `admin`/`local`/`config`），
不读配置。集合同理，也是运行时枚举 —— 清单里写的是枚举出来的东西，不是一份手写的名单。

**外加一个卷。** `erp-agent_download-data` 里是用户生成的报告文件。Mongo 里**没有**
它们的索引，文件名只作为文本存在于消息里 —— 卷丢了，会话记录还在，但里面每个下载
链接都变成死链，而且**没有任何办法重建**（文件是模型在沙箱里生成的）。所以备份目录
里还有一份 `download-data.tar.gz`。

`dind-data` 卷**不需要**备份：丢了之后 `_restore_from_mongodb` 会走容器不存在分支、
清理缓存并重建。

## 日常命令

```bash
bash deploy/dr/backup.sh                    # 备份 → 自检 → 剪枝 → 外推
bash deploy/dr/backup.sh --verify <目录>     # 只对一份已有备份跑恢复自检
bash deploy/dr/backup.sh --prune            # 只跑保留策略
bash deploy/dr/backup.sh --list             # 列出现有备份
bash deploy/dr/backup.sh --no-offsite       # 本次不外推

bash deploy/dr/restore-drill.sh             # 演练最新一份
bash deploy/dr/restore-drill.sh <目录>       # 演练指定的一份
bash deploy/dr/restore-drill.sh --list

bash deploy/dr/offsite.sh <目录>             # 补推一份备份到 OSS

bash deploy/dr/migrate.sh --dir migrations/ --status   # 看迁移账本，不碰数据库
bash deploy/dr/migrate.sh --sha <commit>               # 执行（发布路径用的就是这条）
```

环境变量（都有默认值，一般不用管）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `CD_BACKUP_DIR` | `/var/backups/erp-agent` | 备份根目录 |
| `CD_BACKUP_KEEP` | `7` | 保留份数 |
| `CD_BACKUP_VERSION` / `CD_BACKUP_GIT_SHA` | `unknown` / `-` | 记进目录名与清单 |
| `CD_BACKUP_SKIP_VOLUME` | `0` | 置 1 跳过 `download-data` 卷 |
| `CD_BACKUP_NO_OFFSITE` | `0` | 置 1 跳过外推（CI 用） |
| `CD_BACKUP_SKIP_IF_BUSY` | `0` | 置 1 时「有发布在跑就跳过本轮」（定时备份用） |
| `BACKUP_RESULT_FILE` | 空 | 非空时把 `DB_DUMP=` / `DB_DUMP_SHA256=` 写进去给调用方读 |

前三个 `CD_BACKUP_*` 的默认值同时在 `deploy/cd/lib.sh` 里定义了一份 —— 单独跑
`backup.sh` 时用的是这里的。

## 一份备份长什么样

```
/var/backups/erp-agent/20261003T120000Z-v1.0.0/
  erp_agent.archive.gz          逐库一个 archive，--gzip
  checkpointing_db.archive.gz
  download-data.tar.gz          用户生成的报告文件
  manifest.txt                  逐文件 sha256 + 逐集合文档数区间 + 库清单
  offsite.status                它有没有推出这台机器（两行：结论词 + 原因）
  drill-report.txt              只在演练过之后才有
```

`manifest.txt` 是一行一个事实的 `KIND 字段…` 格式，既能人读、又能 `while read` 解析，
也便于事后手工核对「到底备份了哪几个库」：

```
META version v1.0.0
META created_at 2026-10-03T12:00:00+08:00
DB erp_agent erp_agent.archive.gz <sha256> <字节数>
COLL erp_agent conversations 12 12          ← dump 前后两次读数合成的区间
VOLUME erp-agent_download-data download-data.tar.gz <sha256> <字节数> <条目数>
```

**刻意不用单个全库 archive**：`mongodump --uri` 里带库名时它到底按不按它限定范围，
我没有把握，而「没把握」在这里等于「可能少备份一个库」。逐库显式 `--db` 把这个
不确定性从设计里删掉。

代价是**库名要同时从 URI 里摘掉**：mongodump 不允许 URI 里的库名与 `--db` 并存，
而 `MONGODB_URI` 恰好带着 `.../erp_agent?authSource=admin`，于是它每次都死在
**第一个非 URI 库**上：

```
Invalid Options: Cannot specify different database in connection URI and command-line
option — `erp_agent` was specified in the URI and `checkpointing_db` was specified in
the --db option
```

这不是推演出来的，是 2026-10-03 CI 的 `backup-dr` job 首次真跑时抓到的（本机没有
Docker daemon，看不见它）。摘除逻辑是 `deploy/dr/lib-dr.sh` 的 `DR_MONGO_URI_NODB_SH`
—— 它在**容器里**执行，因为 `$MONGODB_URI` 带口令，在宿主机上展开等于把口令写进
`docker exec` 的 argv。恢复演练报告里的「真正恢复时怎么做」用的是同一条规则。

**摘完那个 `/` 不能一起摘掉。** 修完第一处之后 CI 又红了一次，报的是：

```
error parsing uri: must have a / before the query ?
```

MongoDB 的连接串语法要求查询串前面有 `/`，所以正确的形态是
`mongodb://host:27017/?authSource=admin`，不是 `mongodb://host:27017?authSource=admin`。
值得记一笔的是**桩测当时是全绿的** —— 断言里那个「期望值」是照错误的理解手写的。
桩测能验证「代码符合我以为的规格」，验证不了规格本身；所以备份链路的真判据只能是
`deploy/ci/backup-dr.sh` 那一跑。

**`COLL` 是一段区间而不是一个数。** 生产栈在备份期间仍在服务，dump 窗口里一定有人
在写：dump 完成后再读计数可能得到 N+1 而 dump 里只有 N。等值比较会把一个完全健康的
备份判成坏的，而这是发布路径上的硬门槛 —— 结果是每次有人正在聊天时发布都会中止。
区间是这件事唯一诚实的表达：少于下限是丢数据，多于上限说明恢复进了不属于这份 dump
的东西，两者都报错，落在区间内就算对。

## 自检（每次备份后）vs 演练（人工/定时）

这两件事看起来重叠，约束完全不同：

| | `backup.sh` 的自检 | `restore-drill.sh` |
|---|---|---|
| 何时跑 | **每次备份后**，发布路径上的硬门槛 | 人工 / 将来可能定时 |
| 成本约束 | 必须便宜、只读 | 可以慢，要测真实耗时 |
| 验什么 | 库集合与清单完全一致、逐集合文档数落在区间内、每个 archive 的 sha256、卷可读且条目数相符 | 上面全部，**外加**把卷真的解出来 |
| 产出一份报告吗 | 不产出 | 产出 `drill-report.txt`（含分阶段耗时） |

自检的做法是把 dump **真的恢复进一个一次性 mongo 容器**（`--network none`、
`--memory 512m`、`--wiredTigerCacheSizeGB 0.25`、90s 超时），再逐集合比对 ——
不是数集合个数。因为空库和「恢复成功但内容为空」长得一模一样（3 个急切建的集合、
0 条文档），**集合数量证明不了任何事**。

比的是「恢复库 vs 清单」，**不是**「恢复库 vs 活着的源库」：源库一直在被写，拿它
当基准只会得到随机的失败。清单记的是 dump 那一刻的真值。

**没通过自检的备份不算备份**，发布中止（退出码 2）。目录会留在原地供排查，下次
剪枝收走它。

**演练脚本刻意不碰生产的 `download-data` 卷** —— 它解到临时目录再比对，真正的恢复
命令写在报告末尾由人在处置灾难时执行。解回生产卷就是拿唯一那份用户报告去覆盖它
自己，一次演练毁掉数据，正是这套东西存在的理由的反面。

演练**没有配 timer**：它要解一份完整的卷、起一个临时 mongo，在 2 核 3.6G 的机器上
耗时不明。第一次在真机上跑完，看报告里的 `SECONDS_DB` / `SECONDS_VOLUME`，再决定
它是每天一次还是人工季度动作。在那之前加 timer 是在猜一个会影响生产的频率。

## 异地：推到阿里云 OSS

**本机备份与生产在同一块磁盘上**，而这台生产机是**免费试用实例、到期会被自动释放
且数据不保留**（[cloud/README.md](../cloud/README.md) 自己写的）。也就是说本机备份
连「机器还在」都保证不了 —— 外推不是锦上添花，是这条链路唯一的意义所在。

### 一、装 ossutil（真机上跑一次）

```bash
sudo bash deploy/dr/ossutil-install.sh
```

写死版本（1.7.19）与 sha256，对不上就不装。不用官方那条 `curl … | bash`：它把
「下载什么」和「执行什么」合成一步，于是两者都不可复现。这个脚本往 root 的 PATH 里
放一个二进制，值得多这一道。

### 二、写凭据文件

`/etc/erp-agent/backup.env`，**root 0600**：

```bash
sudo install -m 600 /dev/null /etc/erp-agent/backup.env
sudo tee /etc/erp-agent/backup.env >/dev/null <<'EOF'
# 阿里云 RAM 子账号，权限限到**单个 bucket 的一个前缀**：
#   oss:PutObject / oss:GetObject / oss:ListObjects，资源 arn:acs:oss:*:*:<bucket>/erp-agent/*
OSS_BUCKET=your-bucket
# 用**同地域内网地址**（-internal 结尾），否则外推的流量要花钱。
# 地域在 OSS 控制台 Bucket 概览页能看到，仓库里没有任何地域信息。
OSS_ENDPOINT=oss-cn-hangzhou-internal.aliyuncs.com
OSS_PREFIX=erp-agent
OSS_AK=LTAI...
OSS_SK=...
# 可选：置 0 把「外推失败」从阻断发布降级为仅告警
# BACKUP_OFFSITE_REQUIRED=0
EOF
```

凭据**不经过命令行**（命令行参数会出现在整台机器的 `ps` 里）：`offsite.sh` 写一份
临时的 ossutil 配置文件（600，用完即删），而不是 `ossutil -i AK -k SK`。

对象路径是 `oss://<bucket>/<prefix>/<备份目录名>/`，即一层备份目录一个前缀，逐文件
上传（`cp -r` 到底把目录本身还是目录内容放上去，两种语义都不靠记忆赌）。

### 三、失败为什么默认阻断发布

「没配」和「配了但坏了」是两件事：

- **文件不存在** → 这是**还没做**那一步设置。响亮地打一行带路径的警告然后放行 ——
  报成失败的话，在你拿到 AccessKey 之前每一次发布都会被卡住，而原因是你已知的一件事。
  此时 `offsite.status` 记 `skipped`。
- **配了但失败** → **默认阻断发布**（退出码 2）。外推失败的形态恰好是最安静的
  （网络抖动、AK 过期、权限被改），如果只是警告，「同盘不是备份」这条就悄悄失效了，
  而谁也不会去看那条警告。`BACKUP_OFFSITE_REQUIRED=0` 可以显式降级为仅告警。

上传后会再 `ls` 一次远端并比对对象数 —— 前缀写错时 `cp` 一样会成功，而等到需要恢复
的那天才发现推到了别处。

### 四、`offsite.status` 是给几周后的自己看的

三种结局都往备份目录里写这个文件（结论词 + 原因）：

```
ok
已推送到 oss://your-bucket/erp-agent/20261003T120000Z-v1.0.0（5 个对象）
```

因为**退出码表达不了它们**：未配置（`skipped`）、被降级的失败（`failed`）、真成功
（`ok`），三者都返回 0。而 `deploy/cd/status.sh` 要在几周后回答「这份备份推出去了
没有」，它只能读这个文件 —— 这也是巡检里 `offsite` 那一项判据的来源。

## 保留策略

最近 `CD_BACKUP_KEEP`（默认 7）份，**加上** `state/production.env` 与
`state/production.prev.env` 里 `DB_DUMP` 引用的那两份 —— 后者永不剪，它们是回滚的
真值源，删了就等于把「能不能滚回去」交给运气。

剪枝在**新建之前**跑，所以它不会把刚做好的那份算进保留数。

## 恢复：真的出事时怎么做

演练报告的末尾会把下面的命令按你的实际路径原样打出来，这里给的是形状：

```bash
# 1) 数据库：把每份 archive 灌回一个空的 mongo
docker compose -f /root/erp-agent/docker-compose.yml up -d mongo
for f in /var/backups/erp-agent/<那份>/*.archive.gz; do
  docker compose -f /root/erp-agent/docker-compose.yml exec -T mongo \
    mongorestore --archive --gzip --drop < "$f"
done

# 2) 卷：**先确认生产卷里确实没有要保下来的东西**，再解包
docker run --rm -v erp-agent_download-data:/d -v /var/backups/erp-agent/<那份>:/b:ro mongo:6.0 \
  tar -xzf /b/download-data.tar.gz -C /d

# 3) 起来了先跑巡检，再看那份 drill-report.txt
bash deploy/cd/status.sh
```

`--drop` 会先删同名集合再灌，所以对**空的** mongo 用是安全的；不要对正在服务的库
随手跑。

## 迁移

规则在 [migrations/README.md](../../migrations/README.md)，这里只说执行器。

**只前进，没有 down 迁移。** 回滚靠备份，不靠 undo 脚本 —— undo 脚本只有被验证过
才可信，而验证它的唯一办法是真的滚一遍，那等于把发布流程的复杂度翻一倍，去换一个
备份已经提供了的东西。

**位置在「备份之后、同步源码树之前」**，所以迁移失败时生产的源码树与镜像一个字节
都没动过，与备份失败同级（退出码 8）。代价是迁移文件必须从**新 commit** 里取
（`git archive <sha> migrations | tar -x` 到临时目录）—— 那时生产树里还是旧版，
读本地树会跑到旧文件上，而且跑得「成功」，因为旧文件本来就是合法的。

**账本放在应用库**（`MONGODB_DB_NAME`）的 `schema_version` 集合里，理由同样是备份：
账本跟着业务数据一起被 dump、一起被回滚。放到别的库的话，从一份旧备份恢复之后，
账本会记着「迁移都已应用」而实际数据是旧结构 —— 那是最糟的一种不一致。

这个库名**从容器自己的环境读**，与备份那边「库清单必须运行时枚举、不信配置」看起来
相反，但两处面对的是不同问题：备份要发现的是**配置里根本没有的那个库**，这里要的
正是应用配置里那一个。

已应用的迁移按 sha256 记账，**内容一变就停住且一个迁移都不执行** —— 否则数据库现在
的形状和账本说的对不上，之后所有判断都建在错的前提上。

## 机内巡检与心跳

巡检不是「会检查」，而是**只在状态变迁时说话**。timer 每 10 分钟响一次 = 一天 144
次，每次都发通知的话真正要看的那条会被泡在噪音里，几天之后所有人都会把这套通知
静音掉 —— 一套被静音的通知比没有通知更糟，因为**你以为它在看着**。

代码在 [deploy/monitor/](../monitor/)，安装：

```bash
sudo bash deploy/monitor/install-monitor.sh
```

它会装三个 timer（六个 unit 文件）：

| timer | 频率 | 干什么 |
|---|---|---|
| `erp-agent-patrol` | 每 10 分钟 | 跑 `status.sh`，把结果压成 (id, OK/FAIL) 对与上一次比，**变了才发** |
| `erp-agent-backup` | 每天 03:17 | 跑 `backup.sh`。有发布在跑就跳过本轮 |
| `erp-agent-heartbeat` | 每天 05:07 | **无条件**发一条汇总 + 往箱外死信地址 ping 一下 |

状态文件在 `/var/lib/erp-agent/patrol.last`，**刻意不在仓库树里** —— 树是
`rsync --delete` 刷出来的，放进去每次发布就丢一次。

备份 timer 排在心跳之前，所以心跳读到的备份年龄是当天的。它是方案原文之外的一项
补充：没有它，「备份新鲜度」检查实际在测「上次发布是几天前」，与备份链路坏没坏无关。

### 死信地址怎么配

心跳往 [healthchecks.io](https://healthchecks.io/) 一类服务 ping 一下。站内那条通知
证明不了「机器还活着」（机器没了就什么都没有），而死信地址是**别人**在盯着 ——
该来的 ping 没来，它就替我们报警。这也是「巡检 timer 被人偷偷停掉」唯一能被发现的
方式。

1. 注册一个 check，周期设 1 天、宽限期 12 小时（心跳是 05:07 跑的）；
2. 把它的 ping URL 填进 `/etc/erp-agent/notify.env`：

```bash
# /etc/erp-agent/notify.env（root 0600）
# 站内通知通道，五选一：feishu / wecom / dingtalk / serverchan / generic-webhook
ALERT_KIND=feishu
ALERT_WEBHOOK=https://open.feishu.cn/open-apis/bot/v2/hook/xxxx
# 箱外死信（不配的话心跳只发站内那条，且会明确告诉你丢的是什么）
HEARTBEAT_URL=https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

巡检/心跳与发布**共用这一个文件**，是刻意的：如果巡检自己另有一套通道，那套通道
没人会去验证它通不通。

### 这次**做不到**的两件事

阶段 5 的验收标准里有两条要 off-box 组件，都需要在控制台上点，脚本做不了：

1. **「临时端口上把 `/healthz` 改坏 → 云监控 5 分钟内告警到群」** —— 需要阿里云
   云监控的站点监控（监控点选多个地域，才能区分「机器挂了」和「只有我这儿网络不通」）。
   机内巡检看不到这个：它和被测服务在同一台机器上。
2. **「停掉巡检 timer，第二天收到死信告警」** —— 需要上面那个 healthchecks.io 的
   check 已经建好。

所以验收时正确的说法是：**机内巡检可验，箱外告警待注册后验**。

### 巡检的失效模式（写在明面上）

- **闪断看不见。** 它在两次巡检之间坏了又好，10 分钟窗口里发生又结束的一切都不在
  记录里。它对「持续性的坏状态」有效，对「闪断」无效。别把这里的绿灯读成「这十分钟
  里一切都好」。
- **`status.sh` 的输出格式是接口。** 巡检只认 `[OK] <id>: <细节>` / `[FAIL] <id>: <细节>`，
  指纹**只由 id 和状态词组成**，不含细节（镜像名、digest、版本号、可用空间每次都变，
  拿全文做指纹等于每次发布都发一条假告警）。所以：**改 `status.sh` 里现有的 id 会让
  巡检认为状态变了、发一条假告警**；加新的 id 是安全的。
- 这些不变式由 `deploy/ci/patrol-logic-test.sh` 在 PR 门禁里守着（19 条断言）。

## 排错

| 症状 | 原因 / 处置 |
|---|---|
| 发布报「备份失败」，退出码 2 | 看 `state/production.pending.env` 与备份目录里的残留目录。多半是磁盘空间（`df -h /var`）或 mongo 不可达。备份目录残留是**故意的**，供排查 |
| 自检报「恢复出来的库与清单不一致」 | 要么 dump 真的漏了库，要么清单被手工改过。逐行对 `manifest.txt` 的 `DB` 行与 `mongosh` 的 `listDatabases` |
| 自检报「$db.$coll 清单记 N..M 条，恢复出来 K」 | K 小于下限 = 真丢了数据；K 大于上限 = 恢复进了别的数据。区间本身不合理时看 `counts.tsv` 有没有被中途打断 |
| 备份目录里没有 `download-data.tar.gz` | 卷不存在（本机还没生成过任何下载文件）会跳过并打一行说明。**不是错误** |
| 发布报「异地备份」失败 | 先手工确认：`/etc/erp-agent/backup.env` 在、权限 600、四个变量都非空、`/usr/local/bin/ossutil` 可执行。AK 过期与内网 endpoint 写错是两种最常见的。应急可以 `BACKUP_OFFSITE_REQUIRED=0` 降级发布，但**别忘了事后补推**（`offsite.sh <目录>`） |
| `offsite.status` 是 `skipped 未配置 …` | 凭据文件还没有。见上面的「二、写凭据文件」 |
| 巡检从不发通知 | 先 `bash deploy/monitor/patrol.sh --force --dry-run` 看判定。若它一直在跳过，看 `state/production.pending.env` 是不是卡住了（超过 20 分钟就不再算「发布进行中」，会照常判定） |
| 巡检每次发布都发一条假告警 | 有人改了 `status.sh` 里现有检查项的 id。见上面「巡检的失效模式」 |
| `migrate.sh` 报「$id 已应用过但内容变了」 | 迁移文件在应用之后被改过。**不要**改已应用的迁移，改回原样，新开一个编号向前修 |
| 恢复演练很慢 / 把生产挤到卡 | 演练与发布都会起一个临时 mongo，机器只有 2 核 3.6G。它在 `cd_deploy_in_flight` 时会自己推后；手工跑时避开发布窗口 |

## 只能在真机上验的清单

下面是写这些脚本时**没有把握、只在文档里记着**的东西。第一次上真机时逐条确认：

- OSS 内网 endpoint 的可达性与 ossutil 的真实报错形态；
- 一次性 mongo 容器在 3.6G 机器上、生产栈在跑时的内存余量（自检限了 512m）；
- 恢复演练的真实耗时，据此决定它要不要挂 timer。

**已经验掉的**（原本也在这张单子上，2026-10-03 由 CI 的 `backup-dr` job 给出答案）：

- `listDatabases` 在带 `authSource=admin` 的连接下**不需要**额外权限 —— 枚举出了
  两个库，`erp_agent` 与 `checkpointing_db`，与设计假设一致；
- `mongodump --uri` 与 `--db` 同用**会直接报错退出**（不是静默限定范围）。见上面
  「一份备份长什么样」——这条是本仓库唯一一个「只在 CI 里才可能被发现」的 bug，
  因为本机没有 Docker daemon，而它在真机上表现为**第一次发布就没有备份**。
