<p align="center">
  <img src="Design/Logo/beaver-standard.png" alt="BeaverMeter 海狸" width="128">
</p>

<h1 align="center">BeaverMeter</h1>

<p align="center"><b>用了多少，还剩多少。</b><br>
在 Mac 菜单栏和桌面小组件中查看 Codex、Claude Code、Cursor 与 DeepSeek 用量。</p>

<p align="center">
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14%2B-31332F?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="macOS 14+"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-1.0.0-8B684F?style=flat-square" alt="版本 1.0.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-5B7E68?style=flat-square" alt="MIT License"></a>
</p>

<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

<p align="center">
  <a href="#安装与更新">安装</a> ·
  <a href="#菜单栏">菜单</a> ·
  <a href="#桌面小组件">小组件</a> ·
  <a href="#数据与隐私">数据与隐私</a> ·
  <a href="#帮助与开发">帮助</a>
</p>

<p align="center">
  <img src="screenshots/brand-overview.png" alt="使用合成数据展示的 BeaverMeter 菜单与桌面模块" width="1000">
</p>

## 安装与更新

BeaverMeter 要求 **macOS 14 或更新版本**。从源码构建安装请按
[源码安装指南](docs/guide/development.zh-CN.md#构建与安装)操作，无需另行安装或运行 CodexBar。

如果已有 Universal DMG 安装包，它支持 Apple Silicon 与 Intel，安装时无需 Xcode 或 Homebrew：

1. 打开 DMG，将 **BeaverMeter** 拖入 **Applications**。
2. 推出磁盘映像，再打开安装好的应用。
3. 从桌面的 **Edit Widgets（编辑小组件）** 添加 **BeaverMeter**。

首次启动会注册小组件并设置后台刷新，保留已有配置、登录和装扮。
也支持 `~/Applications`；两个支持目录均有官方副本时，优先使用 `/Applications`。

### 更新

官方构建在启动后检查一次，此后默认每 **12 小时**检查，并尊重自动检查偏好。
发现新版本时，菜单栏海狸出现小圆点，弹窗显示 **Update 1.0.1** 按钮（版本示例）。

点击后进入 Sparkle 原生的发布说明、下载、验证以及 **Install and Relaunch** 流程。
**Check for Updates…** 用于手动检查。后台检查不会自动弹出更新窗口或自动安装。
安装更新前需先完成正在进行的账户登录。

当前安装包采用 ad-hoc 签名，
**未经 Apple 公证**；若首次打开被 macOS 阻止，请按 [Apple 说明](https://support.apple.com/en-us/102445)处理。

更新可用性、连接服务和恢复步骤见[设置与更新](docs/guide/setup.zh-CN.md)。

## 菜单栏

点击海狸打开弹窗；从 Finder 启动或重新打开应用也会显示它。Escape 或点击外部关闭，
点击桌面小组件则打开同一个菜单。菜单栏只保留紧凑海狸图标，悬停提示和 VoiceOver
保留用量详情。界面使用英文标签，并跟随系统明暗外观。

| 服务 | 菜单中的信息 |
| --- | --- |
| Codex | 已记录 token、额度窗口、重置卡与独立工作空间 |
| Claude Code | 已记录 token、API 标价估算费用、额度窗口与 Limit resets |
| Cursor | 实际调用扣费、今日扣费、近期调用与月度额度 |
| DeepSeek | 钱包余额、当月费用、token 与请求数 |

<p align="center">
  <img src="screenshots/menu-monitoring-collapsed-light.png" alt="使用合成读数的浅色菜单" width="320">
  <img src="screenshots/menu-monitoring-collapsed-dark.png" alt="使用合成读数的深色菜单" width="320">
</p>

按需展开历史、工作空间和设置，折叠状态会保留。**Services** 决定哪些服务可用，
默认自动检测；关闭的服务不会被采集。

### 工作空间与连接

- **Codex：**展开 **Codex workspaces → Add workspace…**，命名后完成浏览器登录；每个登录独立保存，也能配置已有 profile 目录。
- **Claude：**在 **Online quota → Sign in to Claude…** 登录；已通过 Claude Code 登录时可用 **Verify login**。本地 transcript 总量与在线额度相互独立。
- **Cursor：**先在 Cursor 登录目标账户，再刷新 BeaverMeter。
- **DeepSeek：**选择 **Connect in browser…**，在官方 Platform 页面完成登录。

同一邮箱下的工作空间也保留各自计划、额度和活动。缺失或身份不匹配时，不借用其他
工作空间的读数。[设置指南](docs/guide/setup.zh-CN.md)说明 CLI 要求、profile 配置、
Keychain 访问和浏览器权限。

### 海狸装扮

在 **Appearance → Logo** 选择 Classic Beaver 或节日装扮。
**Automatic · Local Calendar** 根据 Mac 日期和时区自动切换，支持中国农历节日，
不需要日历权限。

原始设计和节日作品保留在[品牌素材](Design/Logo/README.md)中；
[设置指南](docs/guide/setup.zh-CN.md#外观)列出自动日期和本地偏好。

## 桌面小组件

在每个小组件的 **Edit Widget** 中独立选择并排列模块。
一个**模块**是一项服务或一个 Codex 工作空间，包含其可用的主要额度窗口。
来源中有更多工作空间，也不会自动扩展成额外模块。

先在菜单完成服务连接；编辑小组件模块不会改变登录或服务开关。

| 尺寸 | 使用的槽位 | 信息与布局 |
| --- | ---: | --- |
| Small | 前 2 个 | 身份、双窗口剩余值与主窗口重置；1 张主卡或 2 张紧凑卡 |
| Medium | 前 4 个 | 两个窗口的重置详情；最多三列，4 项时 2×2 |
| Large | 前 6 个 | 使用量放在模块内；2–4 条全宽横行，5–6 项时两列 |
| Extra Large | 前 6 个 | 当前用量；恰好 4 个可见模块时 2×2，不显示七日统计／趋势；其他数量保留可用趋势，5–6 项时三列 |

空、重复、无效或被隐藏的选择不会由后续槽位补位。默认先放每个已启用服务的一项，
不显示 `+N`。已删除的工作空间保持不可用，直到修改选择。

身份区域依次显示 **logo → 工作空间名（若有）→ 已知订阅计划**。
不重复显示普通服务名称；完整名称保留在悬停提示和 VoiceOver。
未知计划不占位，也不会根据消费上限推断计划。

### 日间与夜间预览

<table>
  <tr><th>尺寸</th><th>日间／浅色</th><th>夜间／深色</th></tr>
  <tr>
    <th>小号<br>2 个模块</th>
    <td align="center"><a href="screenshots/widget-small-light.png"><img src="screenshots/widget-small-light.png" alt="完成版 Small 浅色小组件" width="160"></a></td>
    <td align="center"><a href="screenshots/widget-small.png"><img src="screenshots/widget-small.png" alt="完成版 Small 深色小组件" width="160"></a></td>
  </tr>
  <tr>
    <th>中号<br>4 个模块</th>
    <td align="center"><a href="screenshots/widget-medium-light.png"><img src="screenshots/widget-medium-light.png" alt="完成版 Medium 浅色小组件" width="320"></a></td>
    <td align="center"><a href="screenshots/widget-medium.png"><img src="screenshots/widget-medium.png" alt="完成版 Medium 深色小组件" width="320"></a></td>
  </tr>
  <tr>
    <th>大号<br>4 个模块</th>
    <td align="center"><a href="screenshots/widget-large-light.png"><img src="screenshots/widget-large-light.png" alt="完成版 Large 浅色小组件" width="320"></a></td>
    <td align="center"><a href="screenshots/widget-large.png"><img src="screenshots/widget-large.png" alt="完成版 Large 深色小组件" width="320"></a></td>
  </tr>
  <tr>
    <th>超大号<br>4 个模块</th>
    <td align="center"><a href="screenshots/widget-extra-large-light.png"><img src="screenshots/widget-extra-large-light.png" alt="完成版 Extra Large 浅色小组件" width="360"></a></td>
    <td align="center"><a href="screenshots/widget-extra-large.png"><img src="screenshots/widget-extra-large.png" alt="完成版 Extra Large 深色小组件" width="360"></a></td>
  </tr>
</table>

图片使用同一组合成选择，依次为 Personal、Plus、Claude、Cursor；Small 仅展示前两项。
点击图片可查看原图。

### 信息留在所属模块内

双主要额度值和主窗口倒计时始终保留；Small 省略次窗口倒计时，更大尺寸展示两个窗口
详情。Claude 有全模型周额度时优先显示它；Cursor 显示月度剩余额度，DeepSeek 显示
主钱包余额及币种。

Large 和 Extra Large 在对应身份内部加入活动：Codex 工作空间显示 **tokens today**，
Claude 显示已记录 token，Cursor 显示今日实际扣费，DeepSeek 显示当月 token 或调用数。
Extra Large 恰好显示 4 个模块时，2×2 卡片内并排展示额度，当前用量固定在底部，不显示七日统计／趋势；
其他模块数量继续显示来源提供的可用历史。已知零保留，缺失日期留空；额度、活动和历史
各自显示状态。

Codex 工作空间活动使用已验证的账户账本，原始服务日桶／报告日期保留在悬停提示和
无障碍详情中。**`Fetched HH:mm <zone>`** 表示查询时刻，与响应生成时间及服务报告日期
分开；缓存保留原始时刻。显示标签不会改变来源周期，也不意味着已经获得完整实时账户总量。

重置卡库存／到期日、Cursor 已用／上限、token 分项和单次调用保留在菜单。
明暗及减色效果由 WidgetKit 适配，正常行不显示重复勾选。
详情见[数据说明](docs/guide/data.zh-CN.md)及[六模块示例](docs/guide/setup.zh-CN.md#小组件选择)。

## 数据与隐私

- 服务级 Codex／Claude 活动来自本地日志；可选 SSH 加入指定远端的 Codex 记录。独立 Codex 工作空间活动使用账户 API。
- 凭据保留在本机，用量快照不含认证 token、Cookie、提示词或回答内容。
- 工作空间身份与缓存范围隔离；认证失败或身份不匹配会清除受影响的受保护读数。
- 临时失败可在对应来源的期限内保留明确标为过期的值。未知不等于零，缺失实时数据不会由预览值补齐。
- 关闭的服务不会被请求；可选 SSH 仅连接配置的主机；更新请求访问 GitHub Release 资源，不携带服务凭据。
- DeepSeek 验证后的浏览器 token 私密保存在本地供后台刷新；Sparkle 不启用系统画像。

应用运行时，本地服务活动通常每 45 秒刷新；完整后台采集默认每五分钟运行。
完整刷新占锁时，快速轮询会合并跳过，而不是排队等待。最终小组件时间线调度由 WidgetKit 控制。

来源、token 算法、账本日期、浏览器／Keychain 行为、缓存期限和文件位置见
[数据与存储](docs/guide/data.zh-CN.md)。

## 帮助与开发

按任务选择指南：

- [设置与更新](docs/guide/setup.zh-CN.md)：安装、连接服务、工作空间配置和模块选择。
- [数据与隐私](docs/guide/data.zh-CN.md)：来源、计算、时间标签、缓存与存储。
- [常见问题](docs/guide/troubleshooting.zh-CN.md)：登录、缺失／过期数据、小组件与更新恢复。
- [开发](docs/guide/development.zh-CN.md)：源码安装、测试、合成预览及打包。

贡献代码时，主要本地检查为：

```sh
./scripts/test.sh
```

项目采用 SwiftUI、WidgetKit 和独立采集器。[合成性能测试](docs/PERFORMANCE.md)与
[真实运行观察](docs/RUNTIME_PERFORMANCE.md)分别记录；不据此宣称帧率或“全部卡顿已解决”。

另见[更新记录](CHANGELOG.md)、[发布政策](docs/RELEASE_POLICY.md)及
[验证记录](docs/RELEASE_VALIDATION.md)。

BeaverMeter 使用 [MIT 许可证](LICENSE)。CodexBarCore、Sparkle、品牌和服务 logo 来源见
[第三方声明](THIRD_PARTY_NOTICES.md)与[服务素材来源](Design/ProviderSources/README.md)。
