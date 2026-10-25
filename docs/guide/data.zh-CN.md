# 数据来源与隐私

[English](data.md) · [README](../../README.zh-CN.md)

## 不同读数有不同范围

| 读数 | 来源与含义 |
| --- | --- |
| 菜单的服务级 Codex token／历史 | 配置的本地日志与可选 SSH，跨来源去重 |
| 选中 Codex 工作空间的 token／历史 | 该工作空间已验证原生账户上下文中的官方 profile 账本 |
| Codex 额度／重置卡 | 已有 Codex 登录与服务方额度、重置接口 |
| Claude token／历史 | 本地 Claude Code transcript；费用是 API 标价估算 |
| Claude 额度／Limit resets | Claude Code 当前登录与 usage 接口 |
| Cursor | 官方 Dashboard 实际扣费与个人月度额度 |
| DeepSeek | 官方 Platform 钱包与当月用量 |

这些读数不能互换。额度百分比不能换算为 token，模型标价不是订阅扣费。
工作空间读取失败时，不用服务级或其他工作空间总量补齐。

## Codex

### 本地与可选远程活动

采集器使用固定版本的 [CodexBarCore](https://github.com/steipete/CodexBar/commit/07f2a670229bca1a34bb7eda5284c89657b8df9a)
和 BeaverMeter 记录扫描器，搜索活动及归档 rollout，包含仍在运行任务中新追加的记录，
不受原日期目录限制。重复响应、压缩及会话格式被处理，模型内容不进入用量快照。

当前本地日期总量为 **input + output**。Cached input 属于 input，reasoning 属于
output，两者都不重复相加。

可选 SSH 扫描指定远程 Codex 目录，仅返回哈希后的响应／会话标识、时间与数量，
提示词、回答和凭据不离开远端。本地与远程响应去重后显示。SSH 临时失败可保留同一
本地日期的远程缓存，并标为不完整／过期。改变来源会使旧总量失效。

除配置目录外，也可发现活动 Codex app-server 的 home，去重后合并。多个冲突的活动
home 会报告不完整，不静默任选一个；进程退出后已发现记录仍可保留。无法安全恢复逐
响应历史的旧会话不重复计入，并标为不完整。

完整扫描可把旧值向下修正或改为真实零。部分扫描仅在来源、本地日期和时区一致时
保留较高的兼容缓存。读取错误不等同于有效空结果。

### 工作空间账本与身份

工作空间活动读取 `GET /backend-api/wham/profiles/me`。所选工作空间、原生凭据元数据
和 access JWT 账户必须一致；存在 ID JWT 时也必须一致。拒绝覆盖账户请求头，HTTP
成功本身不能证明覆盖后的范围正确。

只保留总量和原始日桶，不据此编造 input／output／cache／reasoning 分项。
工作空间 ID 和已知计划维持额度／身份对应，但显示 ID 本身不能验证账本上下文。

日志 `creator_account_id` 是不可变线程创建者，不代表每次实际请求账户。本地／远端
记录只保留创建者诊断哈希，不作为请求归属证据。它们仍用于服务级总量，不补工作空间
账本缺口。可选逐记录归属路径需要明确的 typed request-account 证据和有效匹配哈希，
当前只有创建者信息的日志不满足该条件。

### 标签、周期与时间

工作空间行的 **tokens today** 使用接口返回的最新非缺失日桶；只有 lifetime 时显示
**tokens total**。原始服务日桶日期和 `statsAsOf` 报告日期保留在悬停／无障碍详情中，
不推断服务端时区。旧日期桶也可能继续更新，日期不代表不可变精确事件截止时刻。

**`Fetched HH:mm <zone>`** 是客户端查询时刻；响应 `generated_at` 单独保留，两者
都不是来源统计更新时间。失败回退保留原查询／响应时刻，外层快照更晚的 `generatedAt`
不会刷新旧读数的时钟。

缺失／null 日期为未知，不补零；有效明确零仍为零。Lifetime 减有限日窗口、百分比／
credits 或过期零桶，都不能代替独立测得的本机今日总量。界面标签不会改变这些来源限制。


工作空间七日趋势截至最新服务日并保留空隙；菜单服务级 **Last 7 days** 则覆盖 Mac
当地今天及前六天。悬停／点击选择某日与其记录分项，本地总量与工作空间 API 总量独立。

### 额度与 Banked resets

Codex 额度复用登录访问 `/backend-api/wham/usage`，用 `limit_window_seconds` 识别
窗口。主摘要依可用额度窗口展示，不为 credits-only／unlimited 状态编造百分比。
`/wham/rate-limit-reset-credits` 只读重置卡。菜单保留精确到期时间、未知到期和限制；
BeaverMeter 不兑换重置卡。

## Claude Code

本地扫描器读取 `$CLAUDE_CONFIG_DIR/projects` 或受支持的默认 Claude Code／Desktop
transcript 存储，以 message／request 身份去重流式片段。扫描索引私有存储在
BeaverMeter 的 `claude-cost-usage/` 下。

Claude 的 `input_tokens` 不含缓存流量，总量为 **input + cache write + cache read +
output**。费用按 CodexBarCore 内置 API 价格估算，未知模型不编造价格；Pro／Max
订阅不会按该估算计费。没有 transcript 时显示无数据，而非实测零。

在线窗口使用 `https://api.anthropic.com/api/oauth/usage`，包含五小时、全模型周和模型
专属限制。小组件优先全模型周额度并保留五小时值，其他窗口在菜单。
**Limit resets** 复用同一认证请求和受支持 CLI 的重置卡请求形式，字段缺失不意味着
零，也不妨碍有效额度展示。

凭据按配置 profile 的 Keychain 优先规则选择，仅在没有可读 Keychain 文档时使用该
profile 的凭据文件。安全存储覆盖不会借用其他 profile。后台原生读取关闭认证 UI；
经验证的现有 system-reader 兼容路径可复用，但不修改 ACL。凭据输出仅经过有界内存
管道，不写临时文件。

只有明确选择 **Allow Claude access…** 才可能请求系统授权；**Repair Keychain
session…** 另行确认。Keychain 错误不会静默变成退出登录。

过期 token 由 Claude Code 自身续期。BeaverMeter 最多每五分钟短暂启动配置的 CLI，
等待新登录后停止，不发送模型提示词、不回答目录信任问题，也不直接轮换 Claude Code
依赖的 refresh token。`CLAUDE_CLI_PATH` 指定 CLI；`CLAUDE_CLI_REFRESH=0` 禁用该
续期尝试，`CLAUDE_KEYCHAIN_ACCESS=0` 禁用 Keychain 访问。

确认过期／认证失败后，续期之前先清除受保护额度／重置成功缓存，不把被拒 token
当作已续期重试。CLI 缺失、冷却和未完成续期保持可重试；真正登录缺失或被拒才需要
浏览器登录。

## Cursor

采集器读取 Cursor `state.vscdb` 中的已有登录，凭据只在进程内使用，访问官方接口：

```text
https://cursor.com/api/dashboard/get-filtered-usage-events
https://cursor.com/api/usage-summary
```

调用费用使用实际扣除的 `chargedCents`，保留 `$0.00` 调用。有效调用若缺少有效扣费，
该调用保持未知，并隐藏日总额以免低估。

月度额度优先 `individualUsage.plan`，其次是有效个人 `overall`，包括受支持 Enterprise
响应。团队池和管理员 Team Caps 不当作个人额度。菜单额度摘要只显示剩余 USD，
已用／上限留在提示中。计划名称只来自已有 membership 元数据，不根据金额推断。

## DeepSeek

明确连接浏览器时，只读取官方 Platform 的 `userToken`。Chromium 与 Safari Apple
Events 路径限定到该站点／会话；验证后以权限 `600` 保存，供后台刷新。

```text
https://platform.deepseek.com/api/v0/users/get_user_summary
https://platform.deepseek.com/api/v0/usage/amount?month=<month>&year=<year>
https://platform.deepseek.com/api/v0/usage/cost?month=<month>&year=<year>
```

范围从本地当月首日开始。Token 将 cache-hit input、cache-miss input 和 output 各加
一次，金额保留返回币种，不为钱包余额构造额度百分比或重置时间。

## 刷新与失败

应用通常每 **45 秒**轮询本地 Codex／Claude 活动，不调用其他服务或额度 API。
快速轮询遇到快照锁时不发布直接返回，下次计划轮询仍会运行。完整刷新／认证保持串行
写入。完整后台采集默认 **五分钟**，保留已有配置间隔；最终时间线由 WidgetKit 调度。

| 来源／状态 | 行为 |
| --- | --- |
| 工作空间 API 临时失败 | 仅同一已验证上下文保留最多三小时的过期值 |
| 工作空间认证／身份不匹配 | 清除受影响的受保护读数，不切换其他账户 |
| Claude 额度／重置成功 | 共用成功读数复用五分钟 |
| Claude 限流 | 尊重 `Retry-After`，或持久化 5／10／20／30 分钟退避；手动刷新也遵守 |
| Claude 临时缓存 | 保留原测量时刻，最多 30 分钟；已过重置的窗口隐藏 |
| Claude 过期／认证失败 | 续期前使旧额度／重置成功缓存失效 |
| 其他独立来源失败 | 保留符合条件的过期值，不用演示数据补实时缺失 |

缓存年龄提示不等于在线验证成功。额度、活动、历史和隐藏重置库存状态独立，隐藏库存
错误不改变小组件额度状态或无障碍内容。

## 存储与隐私

私有根目录为 `~/Library/Application Support/BeaverMeter/`：

- `beaver-meter-snapshot.json`：schema 7 用量，兼容读取 schema 5／6；不支持的旧快照重新生成。
- `beaver-meter-settings.json`：服务选择。
- `beaver-meter-accounts.json`、`codex-workspaces/`：配置目录与独立托管登录。
- `beaver-meter-appearance.json`：外观偏好。
- `deepseek-platform-token`：已验证 DeepSeek token，权限 `600`。
- 扫描／历史缓存继续验证范围、日期和时区；缓存 schema 与快照 schema 不是同一版本。

数据目录权限 `700`，BeaverMeter 的快照及私有配置／凭据文件以 `600` 原子写入。快照不含认证 token、Cookie、提示词
或回答内容，但可能含显示名称、计划、数值、时间和非凭据身份哈希；真实快照不是匿名
示例数据。

用量请求仅发往对应提供方，可选 SSH 连接配置主机。更新走官方 GitHub Release 源与
资源，不携带服务凭据或启用 Sparkle 系统画像。关闭的服务不采集。仓库正式展示截图
使用合成 fixtures，品牌与服务素材声明见[第三方说明](../../THIRD_PARTY_NOTICES.md)。
