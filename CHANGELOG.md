# Changelog

## [1.1.1](https://github.com/farhub-wq/Agent-Harness/compare/v1.1.0...v1.1.1) (2026-10-09)


### 修复

* 修复 request_order_info 中断不到达前端，表单流程首次打通 ([0d113da](https://github.com/farhub-wq/Agent-Harness/commit/0d113daf381c4ae6fbd8cf36251727b008cc16ca))

## [1.1.0](https://github.com/farhub-wq/Agent-Harness/compare/v1.0.5...v1.1.0) (2026-10-09)


### 新功能

* 沙箱镜像预装数据分析栈与中文字体，消除图表生成冷装等待 ([d0dd74c](https://github.com/farhub-wq/Agent-Harness/commit/d0dd74c97d9274b597bc31547a512e369d635b3f))

## [1.0.5](https://github.com/farhub-wq/Agent-Harness/compare/v1.0.4...v1.0.5) (2026-10-08)


### 文档

* 更新 README 记录 2026-10-08 更新，补直推发布脚本并脱敏 ([fc3ffbe](https://github.com/farhub-wq/Agent-Harness/commit/fc3ffbe9aaa7ce64913a155be7f81dd8f3c8c43d))
* 直推脚本相关 README 引用改为不入库说明，gitignore 挡住本地脚本 ([7e85d01](https://github.com/farhub-wq/Agent-Harness/commit/7e85d01c001eb4aaf649ef650888f60316295482))

## [1.0.4](https://github.com/farhub-wq/Agent-Harness/compare/v1.0.3...v1.0.4) (2026-10-08)


### 修复

* 触发发布（LLM切换至ChatAnywhere + 沙箱上传修复） ([f6e5d72](https://github.com/farhub-wq/Agent-Harness/commit/f6e5d725af3c0c72544cc29d6223909def929eb9))

## [1.0.3](https://github.com/farhub-wq/Agent-Harness/compare/v1.0.2...v1.0.3) (2026-10-06)


### 文档

* 更新 README，记录 2026-10-06 真机修复与 v1.0.2 发布 ([903282b](https://github.com/farhub-wq/Agent-Harness/commit/903282b1f4eea3816c3dc8aece5084314517a67e))

## [1.0.2](https://github.com/farhub-wq/Agent-Harness/compare/v1.0.1...v1.0.2) (2026-10-06)


### 修复

* **cd,ci:** 修两处让整条发布链路从未跑通的缺陷 ([396526e](https://github.com/farhub-wq/Agent-Harness/commit/396526ea0abc8c783129221d91e88f89d56cd9d3))
* **cd:** Prometheus 只在 internal data 网，宿主探测必然 000 致误报/判据失效 ([882a706](https://github.com/farhub-wq/Agent-Harness/commit/882a706ac355d50b8d7913451913e909bb4e23d0))
* **cd:** 影子启动失败（rc=4）残留 pending，被巡检误报为「发布卡在半途」 ([9eb425b](https://github.com/farhub-wq/Agent-Harness/commit/9eb425b7c5cfb84807d0dc1a428d6244534b24e0))
* **cd:** 未配 registry 时 cd_registry_prefix 返回 1，deploy 死在镜像引用阶段 ([f88d8bf](https://github.com/farhub-wq/Agent-Harness/commit/f88d8bf9c11261dde8448410bbf2729834784763))
* **cd:** 老实例升级到含 :443 的 nginx 时缺占位证书，nginx 启动即崩必回滚 ([62c0b4c](https://github.com/farhub-wq/Agent-Harness/commit/62c0b4cafd844c06b9b185469ad53135ed4bf2b5))
* **ci:** 集成栈 prepare-stack 补 nginx TLS 占位证书，解两个集成 gate 长期红 ([629d818](https://github.com/farhub-wq/Agent-Harness/commit/629d818ce4f4fe8d593851fd3bd5fbdbe799aecc))
* **deploy,backend:** 修三处让真机首次发布与 CI 集成栈失败的问题 ([9ff6b1a](https://github.com/farhub-wq/Agent-Harness/commit/9ff6b1ab7e382d563ae9ac7d206b8521815b442a))
* **nginx:** TLS 开关在 http 顶层用 set 非法，nginx -t emerg 必崩 ([d3128e0](https://github.com/farhub-wq/Agent-Harness/commit/d3128e0b2b39167a48dc634c7768c4bf5356dede))
* **nginx:** 修复 Basic Auth 带凭据请求 500（htpasswd 权限 + TLS 开关 envsubst cycle） ([2097cff](https://github.com/farhub-wq/Agent-Harness/commit/2097cff9117db2217cb16e80ba4f0a127b19144c))

## [1.0.1](https://github.com/farhub-wq/Agent-Harness/compare/v1.0.0...v1.0.1) (2026-10-05)


### CI

* **release:** tag 去掉 erp-agent 前缀（include-component-in-tag: false） ([11fd795](https://github.com/farhub-wq/Agent-Harness/commit/11fd7952af102ad63d3edbff1d06b5e5fe261913))

## 1.0.0 (2026-10-03)


### 新功能

* **cd:** 新增生产栈的发布与回滚工具 ([0ec9e6f](https://github.com/farhub-wq/Agent-Harness/commit/0ec9e6f3109f16f7680c5c6007b237828f7512e0))
* **cd:** 阶段四 影子启动、观察窗与通知 ([96aabac](https://github.com/farhub-wq/Agent-Harness/commit/96aabac2793ccc75debaf48ac9b73efc79c7d509))
* **cd:** 阶段四 提权闸门、runner 安装与资源护栏 ([a74f1f9](https://github.com/farhub-wq/Agent-Harness/commit/a74f1f9171817eb75a993a572579bbeee044a29a))
* **ci:** 阶段三 B：集成栈门禁（auth-path + stack-smoke） ([11d74d3](https://github.com/farhub-wq/Agent-Harness/commit/11d74d3e9df630ad7e8873d93b5d162bfaccae41))
* **ci:** 阶段三静态门禁：workflow 拆分、密钥扫描与前端 lint/测试 ([aed8bd0](https://github.com/farhub-wq/Agent-Harness/commit/aed8bd00768ed1f6c2bad1bb33743e481ca42426))
* **ci:** 阶段四 构建与发布流水线（build / deploy / release-please） ([038f1d0](https://github.com/farhub-wq/Agent-Harness/commit/038f1d051da044002b0894953f39dd606980d326))
* **ci:** 阶段四/五 —— 构建发布流水线、数据库关卡与机内巡检 ([06d7fb3](https://github.com/farhub-wq/Agent-Harness/commit/06d7fb3d500d9fbc923b8613080fd495e1dab052))
* containerize stack, harden sandbox, add auth and cloud deploy ([79c3c3a](https://github.com/farhub-wq/Agent-Harness/commit/79c3c3a1f42730109c187e10661ea3d9e583f478))
* **dr:** OSS 外推与 ossutil 安装 ([c0477c4](https://github.com/farhub-wq/Agent-Harness/commit/c0477c4a6b83d0b7d1acd9b655497d434066d1ad))
* **dr:** 恢复演练脚本与 drill_report 通知 ([d75175d](https://github.com/farhub-wq/Agent-Harness/commit/d75175d5455c0e3e9cd75b0bde8ef7ec38b1b873))
* **dr:** 数据库备份与 restore 自检 ([52e207a](https://github.com/farhub-wq/Agent-Harness/commit/52e207a20ab74eda3b1d9336be5ce934c6820b5f))
* **dr:** 迁移显式关卡与退出码 8 ([179ff94](https://github.com/farhub-wq/Agent-Harness/commit/179ff94ba0697d56b557537a91a6776baf931bf6))
* hybrid review routing with execution escalation and write replay guard ([7008536](https://github.com/farhub-wq/Agent-Harness/commit/70085363b81596860e2288ad60b1922f2bc7ad01))
* **monitor:** 机内巡检 timer 与心跳 ([590cc82](https://github.com/farhub-wq/Agent-Harness/commit/590cc827617379fda8c95e09b257deb1e99e3d3c))


### 修复

* **cd:** compose 报告依赖失败后不再空等健康超时 ([50060c6](https://github.com/farhub-wq/Agent-Harness/commit/50060c6f63a8047e6db3c28d1084776c78964f58))
* **cd:** 巡检比对镜像 digest 而不是引用名 ([65c2efc](https://github.com/farhub-wq/Agent-Harness/commit/65c2efc39876eff99c6f46f5a4ea1eeba556a9c9))
* **ci:** langgraph_store 的种子要长得像真文档 ([03a65f2](https://github.com/farhub-wq/Agent-Harness/commit/03a65f269b691bf55bce22c414d2b4e8e75a3554))
* **ci:** 修掉首轮 CI 暴露的两个集成 job 失败 ([2a4e144](https://github.com/farhub-wq/Agent-Harness/commit/2a4e1445179c1a628b2cef0c8dc9184f3888c60d))
* **ci:** 前端镜像构建补 setup-buildx，修 gha 缓存导出失败 ([49c4b26](https://github.com/farhub-wq/Agent-Harness/commit/49c4b26566afa9a27216fee937f10a1b242500e8))
* **dr:** 摘库名时留下那个 /，否则 URI 语法不过 ([8f52b30](https://github.com/farhub-wq/Agent-Harness/commit/8f52b30af3698ba87d0aa2ef9db7250b83716355))
* **dr:** 摘掉 URI 里的库名，mongodump 才能与 --db 并存 ([eb2a4bd](https://github.com/farhub-wq/Agent-Harness/commit/eb2a4bdc3e6bc22f94cfdb9968b64dc7676a09cf))
* **dr:** 记账也要过 dr_wrap_js，否则永远被判成失败 ([2930d3b](https://github.com/farhub-wq/Agent-Harness/commit/2930d3bd680825a48bc329795e91adcab478b263))
* **frontend:** SSE 解析器跨块保留事件名与数据，兼容 CRLF 空行 ([373777e](https://github.com/farhub-wq/Agent-Harness/commit/373777e0f6852de7035c320f214b2e6be6187a20))
* **frontend:** 重建前端镜像不再依赖 public/ 目录存在 ([84b0ad8](https://github.com/farhub-wq/Agent-Harness/commit/84b0ad8a3a609f87fc399363643308ff44780fb3))
* integrate live memory and isolate conversation archives ([16c1381](https://github.com/farhub-wq/Agent-Harness/commit/16c1381d29c0b80383ca09311f3ef9e44a9071af))
* **test:** 修 history 归属测试的桩，_owner 改为调用期求值 ([5f626ba](https://github.com/farhub-wq/Agent-Harness/commit/5f626ba2ac03a55fa6f33490a86bee327ace1a0c))
* tolerate browser extension attributes on root html ([500f8a4](https://github.com/farhub-wq/Agent-Harness/commit/500f8a4dc0fd64a8f16135a0e61df535f879638e))


### 文档

* **ci:** 记录阶段 3-B 的验收结果（坏 PR [#5](https://github.com/farhub-wq/Agent-Harness/issues/5) 只让 auth-path 变红） ([0b2050c](https://github.com/farhub-wq/Agent-Harness/commit/0b2050c8f899c6a4a3dd89cbfc092e645a7d9ee8))
* describe three-tier memory integration and verified limits ([325f79e](https://github.com/farhub-wq/Agent-Harness/commit/325f79e7e1bc1be535ca31dfe9396df623717dc0))
* **dr:** 阶段 5 文档收口 ([8d5866a](https://github.com/farhub-wq/Agent-Harness/commit/8d5866a78503470e4584a29a9141da5c0ddf7cb7))
* **readme:** 补上 CI 门禁一节，并修正「GitHub Actions 尚未实现」 ([f4a33a9](https://github.com/farhub-wq/Agent-Harness/commit/f4a33a980fcf436fe60b1c28606ddf5e4e5daba9))
* **readme:** 补充发布与回滚工具与前端镜像构建修复 ([f320478](https://github.com/farhub-wq/Agent-Harness/commit/f3204784ab2d3fec75d7f2c5a3783ff72700d7e5))
* require local frontend dependencies for Turbopack ([c317699](https://github.com/farhub-wq/Agent-Harness/commit/c317699ebbc440e06c90dbff6d3431be19a6a6ec))
* summarize hybrid review and frontend compatibility updates ([538cc41](https://github.com/farhub-wq/Agent-Harness/commit/538cc41e0ee805f75f99a8e334ab51ae8a05b6fb))
