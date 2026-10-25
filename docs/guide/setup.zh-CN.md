# 设置与更新

[English](setup.md) · [README](../../README.zh-CN.md)

## 安装

BeaverMeter 要求 macOS 14+。构建本 checkout 请按[源码安装](development.zh-CN.md#构建与安装)
操作，不需要另行安装或运行 CodexBar。

如果已有 Universal DMG 安装包，它支持 Apple Silicon 与 Intel，安装时不需要 Xcode、
XcodeGen 或 Homebrew：

1. 打开 DMG，拖入 `/Applications` 或 `~/Applications`。
2. 推出磁盘映像，再打开安装好的应用。
3. 从桌面 **Edit Widgets** 添加 BeaverMeter。

两个支持目录都有官方应用时优先使用 `/Applications`。Downloads、挂载的映像和
App Translocation 不作为运行安装位置，也不会静默删除重复副本。

当前应用采用 ad-hoc 签名，未经 Apple 公证。若可信安装包被 macOS 阻止，按
[Apple 指南](https://support.apple.com/en-us/102445)处理；应用不会关闭 Gatekeeper 或
移除隔离属性。写入无权限的安装目录可能需要管理员授权。

首次启动注册小组件并配置用户级后台刷新，保留现有设置、登录和装扮。
生命周期与回滚见[发布政策](../RELEASE_POLICY.md)。

## 更新

官方构建只启动一个 Sparkle updater。启用自动检查时，启动后进行一次后台检查，
之后按默认 **12 小时**计划检查，并尊重用户的自动检查偏好。

有已验证新版本时：

- 菜单栏海狸出现小圆点。
- 弹窗提供 **Update 1.0.1**（版本示例）。
- 点击进入 Sparkle 原生的发布说明、下载和验证界面。
- 选择 **Install and Relaunch** 安装重启；**Check for Updates…** 用于手动检查。

后台检查不自动弹窗或自动安装。正在进行的账户登录必须先结束。安装准备会短暂停止
本应用的采集，重新启动后恢复注册与刷新。取消或失败时可恢复旧应用运行状态；新应用
未能重新打开时，可手动打开 BeaverMeter 恢复后台采集。

源码、本地和预览构建不使用生产 updater。更新请求通过 GitHub HTTPS，不携带服务凭据，
Sparkle 系统画像保持关闭。合成可更新截图不代表某个版本已经发布。

<picture><source media="(prefers-color-scheme: dark)" srcset="../../screenshots/menu-update-dark.png"><img src="../../screenshots/menu-update-light.png" alt="合成的可更新界面" width="360"></picture>

## 服务

打开海狸菜单并展开 **Services**。默认自动检测，明确关闭的服务不被采集。
服务可用性由菜单、小组件选项和采集器共用。选择小组件模块不会替你登录或开启服务。

### Codex 工作空间

展开 **Codex workspaces → Add workspace…**，命名后完成浏览器登录。
需要可用的 Codex CLI，不要求安装 CodexBar。BeaverMeter 把每个托管登录独立保存在
Application Support 的 `codex-workspaces/<UUID>` 下。**Sign in…** 用于重新连接，
失败时可在菜单中重试。

复用已有 profile 时，选择 **Open configuration…**，编辑
`~/Library/Application Support/BeaverMeter/beaver-meter-accounts.json`：

```json
{
  "version": 1,
  "providers": [{
    "id": "codex",
    "codexProfileHomePaths": ["~/.codex-work", "~/.codex-personal"]
  }]
}
```

每个目录都应已有各自的有效登录。当前 `CODEX_HOME` 或默认 `~/.codex` 始终包含在内；
重复及符号链接等价目录只读一次。保存后刷新。应用读取自己的工作空间注册和明确配置
的目录，不自动读取 CodexBar 托管登录。

需要明确指定额度工作空间时，可在 `version/providers` 同级加入：

```json
"codexWorkspaces": [
  {"home": "~/.codex-work", "workspaceAccountID": "<ChatGPT workspace UUID>", "workspaceLabel": "Research"}
]
```

使用 ChatGPT 工作空间 ID，而非 API organization ID（`org-…`）。额度身份需要相应响应
验证。工作空间 token 账本要求更严格：所选工作空间必须匹配原生凭据及 access token
账户；若有 ID token，也必须匹配。覆盖账户请求头不能使账本有效，应使用原生登录到
该工作空间的独立 profile。不会为切换账户而改写外部认证文件。详见[数据](data.zh-CN.md)。

### Claude Code

本地 token 需要 Claude Code transcript；在线额度复用 Claude Code 的登录，两者独立。

- **Sign in to Claude…**：明确发起浏览器授权。
- **Verify login**：使用当前额度服务验证已有登录。
- **Allow Claude access…**：可向 macOS 申请访问已有 Keychain 凭据。
- **Cancel**：停止当前认证操作。

Keychain 访问错误不自动等同于退出登录，计划读取保持非交互。
**Repair Keychain session…** 是另行确认的登录 Keychain 锁定／解锁修复，macOS 会要求
Mac 密码。取消解锁可能令 Keychain 保持锁定。该操作不删除凭据或修改访问列表。

非默认 profile 可在私有 `config.env` 中设置 `CLAUDE_CONFIG_DIR`。
[数据](data.zh-CN.md#claude-code)和[常见问题](troubleshooting.zh-CN.md)说明续期、
安全存储选择及重试期限。

### Cursor

在 Cursor 中登录目标账户后刷新 BeaverMeter。采集器复用本地登录，展示 Dashboard
实际扣费，而非模型标价；团队共享池不作为个人月度额度。

### DeepSeek

选择 **Connect in browser…** 并在官方 Platform 页面完成登录；必要时用 **Check now**。
关闭弹窗不会停止后台连接尝试。

Chromium 系浏览器仅读取官方站点的 `userToken`。Safari 需要该标签的 Automation
权限，以及以下 Safari 设置：

1. **Settings → Advanced → Show features for web developers**。
2. **Settings → Developer → Allow JavaScript from Apple Events**。

token 验证后私密存储用于后台刷新，位置和请求范围见[数据](data.zh-CN.md#deepseek)。

## 小组件选择

每个小组件独立编辑。一个模块是一项服务或一个 Codex 工作空间及其主要额度窗口。
上限为 **Small 2／Medium 4／Large 6／Extra Large 6**。先截取槽位，再过滤空、重复、
无效或被隐藏的选项，后续槽位不补位。默认先取各可用服务的一项，再列其他工作空间。

明确选择工作空间后，其额度、计划和活动留在一起。已删除的选项保持不可用，直到修改。
不自动扩展同服务的其他工作空间，不显示 `+N`。已知计划来自元数据，未知计划不占位。

Small 保留双剩余值和主重置，Medium 加重置详情，Large 加模块内使用量。Extra Large
恰好 4 个可见模块的 2×2 布局只保留额度与当前用量，不显示七日统计／趋势；其他数量
继续显示可用历史。库存、到期、Cursor 已用／上限及 token 分项仍在菜单中。

六模块合成边界示例：

<picture><source media="(prefers-color-scheme: dark)" srcset="../../screenshots/widget-large-six-modules.png"><img src="../../screenshots/widget-large-six-modules-light.png" alt="Large 的六个合成选中模块" width="352"></picture>

<picture><source media="(prefers-color-scheme: dark)" srcset="../../screenshots/widget-extra-large-six-modules.png"><img src="../../screenshots/widget-extra-large-six-modules-light.png" alt="Extra Large 的六个合成选中模块" width="710"></picture>

这些是设计预览，不能证明所有真实主题、焦点状态或选择已通过桌面验收。
详见[预览说明](../WORKSPACE_PREVIEWS.md)。

## 外观

**Appearance → Logo** 可选 Classic Beaver 或固定节日装扮。
**Automatic · Local Calendar** 使用下列日期：

| 装扮 | 自动日期 |
| --- | --- |
| 元旦 | 1 月 1 日 |
| 春节 | 除夕至正月初七 |
| 元宵 | 正月十五 |
| 端午 | 五月初五 |
| 中秋 | 八月十五 |
| 程序员日 | 10 月 24 日 |
| 万圣节 | 10 月 31 日 |
| 圣诞节 | 12 月 24–26 日 |

日期按 Mac 当前时区，农历使用中国农历且跳过闰月；其余日期使用常规海狸。
启动、当地午夜、唤醒、时钟／时区变化时在本地检查，不需日历权限或网络请求。
外观偏好与用量数据独立存储。

原始品牌与节日设计保留在 [Design/Logo](../../Design/Logo/README.md)，
服务素材见 [Design/ProviderSources](../../Design/ProviderSources/README.md)。
