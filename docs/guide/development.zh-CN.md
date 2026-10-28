# 开发

[English](development.md) · [README](../../README.zh-CN.md)

## 构建元数据

当前基线为 **1.0.1，build 38**，App 与 Widget 元数据必须一致。
源码提交或本地安装包不会发布正式标签、DMG 或 appcast。

应用采用 SwiftUI，小组件采用 WidgetKit，采集器让各服务读取独立。Shared 模型供三者
共用，不需要 CodexBar 常驻；依赖固定在 `project.yml`。

## 构建与安装

要求 macOS 14+、完整 Xcode、Homebrew 与 XcodeGen。源码安装是开发路径，官方预编译
DMG 不要求这些工具。

```sh
git clone https://github.com/fusheng-ji/BeaverMeter.git
cd BeaverMeter
brew install xcodegen
./scripts/install.sh
```

脚本先构建再停止旧安装，询问 team ID／bundle 前缀、本地与可选远程来源，安装到
`~/Applications/BeaverMeter.app` 并配置后台刷新。替换验证使用受影响应用／代理／数据
的回滚副本。改变安装前先保留已有配置与自定义工作。

源码 updater 关闭。官方应用与自定义开发身份是不同安装；改变身份可能需要移除再添加
小组件，不能把自定义身份当作官方发布。

### 可选配置

首次默认关闭 SSH；启用需填写 SSH 别名、远程 Codex home 和 Python 的绝对路径。
升级保留已配置启用／关闭状态及间隔。私有 `config.env` 包含这些相关键：

```text
CODEX_REMOTE_SSH_HOST
CODEX_REMOTE_ROOT
CODEX_REMOTE_PYTHON
CLAUDE_CONFIG_DIR
CLAUDE_SECURESTORAGE_CONFIG_DIR
CLAUDE_CLI_PATH
CLAUDE_CLI_REFRESH
CLAUDE_KEYCHAIN_ACCESS
```

完整后台间隔默认五分钟，本地 Codex／Claude 活动走独立 45 秒路径。
不要为加速测试缩短安全超时、合并账户范围或开启真实请求。

## 测试

完整本地检查：

```sh
./scripts/test.sh
```

单独 Swift 测试：

```sh
xcodegen generate
xcodebuild -project BeaverMeter.xcodeproj \
  -scheme BeaverMeter -derivedDataPath /tmp/beavermeter-derived test
```

无网络 fixtures／迁移测试也可单独运行：

```sh
./Tests/collector_test.sh \
  /tmp/beavermeter-derived/Build/Products/Debug/BeaverMeterCollector
./Tests/migration_test.sh
```

独立 API 与真实 POSIX 锁测试见
[workspace_token_api_test.py](../../Tests/workspace_token_api_test.py)、
[runtime_lock_test.py](../../Tests/runtime_lock_test.py)。先读参数，使用 fixture 目录与测试
输出，不指向生产文件。

Fixture 控制包括：

```text
CODEX_TOKEN_FIXTURE             CODEX_USAGE_FIXTURE
CODEX_HISTORY_FIXTURE           CODEX_RESET_CARDS_FIXTURE
CODEX_WORKSPACE_TOKENS_FIXTURE   CODEX_REMOTE_RESPONSE_FIXTURE
CLAUDE_TOKEN_FIXTURE            CLAUDE_USAGE_FIXTURE
CLAUDE_HISTORY_FIXTURE          CLAUDE_RESET_CARDS_FIXTURE
CURSOR_EVENTS_FIXTURE           CURSOR_SUMMARY_FIXTURE
DEEPSEEK_USAGE_FIXTURE          DEEPSEEK_SUMMARY_FIXTURE
CURSOR_STATE_DB                 CODEX_TOKEN_CACHE_ROOT
CLAUDE_TOKEN_CACHE_ROOT         CLAUDE_CONFIG_DIR
```

覆盖 schema 兼容、来源／账户隔离、零／未知、部分扫描与修正、跨主机去重、认证过期、
Keychain 取消、有界缓存、异步读顺序、模块上限和安装回滚。合成输入不能证明真实日志
存在请求账户计费证据，回归测试应保留范围和日期语义。

## 合成预览

构建渲染器并使用独立输出目录：

```sh
xcodegen generate
xcodebuild -project BeaverMeter.xcodeproj \
  -scheme BeaverMeterPreviewRenderer \
  -derivedDataPath /tmp/beavermeter-preview-derived build
preview_renderer=/tmp/beavermeter-preview-derived/Build/Products/Debug/BeaverMeterPreviewRenderer
"$preview_renderer" --check-assets
BEAVERMETER_PREVIEW_RASTER_ONLY=1 "$preview_renderer" \
  --canonical .build/canonical-review --time-zone UTC --logo standard \
  --appearance both --update-version 1.0.1 --check-assets
"$preview_renderer" --interactive-demo \
  --time-zone UTC --logo standard --appearance light
```

Canonical 命令保留默认冻结参考时刻，复现时不要加 `--date`；显式
`--date YYYY-MM-DD` 会取所选时区当日午夜。Appearance 支持 `light`／`dark`／`both`。
`--update-version 1.0.1` 生成额外的合成可更新界面，不查更新源，也不宣布某版本已发布。
截图与 demo 使用合成数据，不读取安装中的设置、快照或会话；交互 demo 修改仅在内存。替换仓库图片前检查
四尺寸身份、`tokens today`、Fetched 时钟与历史可见性。Extra Large 恰好 4 个可见模块
的 2×2 布局不显示七日统计／趋势，额度与当前用量保留；其他数量继续显示可用历史。
不用真实账户代替 fixtures。

矩阵是开发输出，不是 README 的截图合同：

```sh
"$preview_renderer" --service-matrix .build/service-matrix --appearance both
"$preview_renderer" --workspace-matrix .build/workspace-matrix --appearance both
```

当前合同见[预览说明](../WORKSPACE_PREVIEWS.md)，独立宿主／fixtures 见
[QA/WidgetHost](../../QA/WidgetHost/README.md)。选择上限始终是 2／4／6／6，服务可用
不代表所有选项同时可见。生成矩阵放 `.build`，不放正式展示截图集。
离线渲染不能代替真实桌面的主题／焦点／边界验收。

`--interactive /path/to/snapshot.json` 是高级指定快照模式，关闭自动轮询，但有 helper
时，明确的 Refresh／登录操作可在指定环境采集或认证。只能使用获授权测试环境，
与纯合成 demo 不同。

## 设计素材

原始品牌与服务素材保留在 `Design/`。
[品牌说明](../../Design/Logo/README.md)、
[已批准作品](../../Design/Logo/a1-layout-refinement-2026-10-09/README.md)与
[服务素材来源](../../Design/ProviderSources/README.md)记录出处。
有意修改原始作品后可重新导出派生品牌／图标资源：

```sh
swift -module-cache-path /tmp/beavermeter-brand-cache scripts/make_brand_assets.swift
swift -module-cache-path /tmp/beavermeter-brand-cache scripts/make_app_icon.swift
```

之后重新构建渲染器。不要用截图替换原始设计，也不在清理生成矩阵时删除设计母版。

## 本地打包与正式发布

未发布的本地包：

```sh
zsh scripts/build_release.sh --local /tmp/beavermeter-local-release
```

生产更新保持关闭，不创建标签、Release 或生产 appcast。Node/npm 和原生打包依赖仅是
开发要求。正式发布另受[发布政策](../RELEASE_POLICY.md)约束，需独立执行发布步骤。

可用不读取正式签名 Keychain 的独立 updater 测试验证编号变化：

```sh
source_app=/path/to/BeaverMeter.app
zsh Tests/sparkle_install_test.sh "$source_app" \
  .build/sparkle-tooling/distribution --ephemeral-signing --renumbering
```

它生成临时 CryptoKit 签名密钥和独立应用副本，经真实 loopback Sparkle 流程验证
**5.5.0/build 36 → 1.0.0/build 37**。这些编号是测试元数据，不指向公开 Release。
这不等于生产端到端验收：真实凭据、LaunchAgent、
桌面小组件、管理员授权、带隔离下载及独立构建的公开版本仍需各自证据。

## 性能与验证

[性能文档](../PERFORMANCE.md)记录受控合成负载，[运行文档](../RUNTIME_PERFORMANCE.md)
记录真实进程、采集器争用和局限。减少重复解码不等于帧率或泄漏结论，也不宣称
493 ms 清醒区间已经解决。

[验证记录](../RELEASE_VALIDATION.md)按构建／合同保留结果，不把旧图或旧测试数量
当作当前验收。可选诊断仅记固定事件和时长，不记录账户数据，并保持正常刷新频率与
认证行为。

## 目录

| 路径 | 用途 |
| --- | --- |
| `App/` | 菜单应用、store、生命周期与 updater |
| `Widget/` | WidgetKit provider、intent 与自适应模块 |
| `Shared/` | 快照、模型、展示及共享素材 |
| `Collector/` | 独立服务读取及范围隔离缓存 |
| `PreviewRenderer/`、`QA/WidgetHost/` | 合成预览与独立 QA |
| `Design/`、`screenshots/` | 原始设计与正式合成展示图 |
| `docs/guide/` | 当前双语指南 |
| `scripts/`、`Tests/` | 构建、安装、发布工具和测试 |
