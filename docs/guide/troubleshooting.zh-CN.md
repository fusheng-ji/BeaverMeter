# 常见问题

[English](troubleshooting.md) · [README](../../README.zh-CN.md)

## 无法使用自动更新检查

源码、本地安装包和预览构建有意不访问生产 updater，版本元数据本身不会使安装包成为
正式发布。需要应用内更新时，从 [GitHub Releases](https://github.com/fusheng-ji/BeaverMeter/releases/latest)
安装官方 DMG；本 checkout 仍可按[源码安装](development.zh-CN.md#构建与安装)操作。
更新流程见[设置](setup.zh-CN.md#更新)。

## Codex 没有 token

先确认是哪一种读数：

- 菜单服务级总量需要本地 Codex 记录或已配置 SSH。运行一次本地会话后刷新；数据放在别处时检查 home。
- 工作空间行需要其自身已验证账户 API 账本。重新连接该空间，不复制其他空间的值，也不把缺失当零。

同一邮箱仍可对应独立账户上下文。所选／原生／access token 身份必须一致，有 ID token
时也要匹配。覆盖工作空间请求头不足以验证范围，本地创建者 ID 也不是实际请求账户
证据。详见[数据](data.zh-CN.md#codex)。

## Claude 没有本地 token

运行一次 Claude Code；非默认目录可在私有 `config.env` 设置 `CLAUDE_CONFIG_DIR`。
本地 transcript 可用不代表在线额度已授权，没有 transcript 时为无数据而非实测零。

## Claude Online quota 需要处理

| 状态 | 操作 |
| --- | --- |
| 登录缺失／被拒 | **Sign in to Claude…** 并完成浏览器授权 |
| 已通过 Claude Code 登录 | **Verify login** |
| 已有 Keychain 登录无法访问 | **Allow Claude access…**，明确向系统申请权限 |
| Keychain 解锁会话异常 | 阅读 **Repair Keychain session…** 确认内容后再决定 |
| 被限流 | 等待提示的重试时刻；手动刷新遵守同一冷却 |
| CLI 缺失／冷却／续期未完成 | 修复 CLI／profile 后重试，不自动变成另一次浏览器登录 |

登录后会在线验证额度，CLI 成功退出不等于登录已验证。过期／撤销登录可能需要授权。
确认过期或认证失败会清除旧在线额度／重置读数，本地 transcript 活动保持独立。

修复操作先锁定登录 Keychain，再由 macOS 请求解锁；取消可能令其继续锁定。不会删除
凭据或改变 ACL，计划读取也不发起修复或交互授权。自定义 profile／CLI 开关见
[数据](data.zh-CN.md#claude-code)。

## Cursor 提示 Sign in，或缺少月度额度

打开 Cursor，确认目标账户处于登录状态后刷新。加密登录读取受阻时，点击
**Allow Cursor access…** 完成系统授权；验证后的私有会话支持静默刷新。
切换 Cursor 登录后需要重新验证，详见[设置](setup.zh-CN.md#cursor)。

团队共享池／管理员 cap 不是个人月度额度；没有受支持个人上限时保持不可用。

有效零扣费调用保持零，缺少实际扣费则未知，并可隐藏日总额；不能用模型标价代替。

## DeepSeek 提示 Connect

选择 **Connect in browser…**，在官方 Platform 页面完成登录，再用 **Check now**。
Safari 需开启[设置指南](setup.zh-CN.md#deepseek)中的两项开发者／Apple Events 设置，
并允许访问目标官方标签。不要把 token 粘贴进问题报告或截图。

## 远程 Codex 缺失

确认配置的 SSH 别名能非交互连接，远程 Codex 与 Python 绝对路径存在。
`config.env` 中的设置为 `CODEX_REMOTE_SSH_HOST`、`CODEX_REMOTE_ROOT`、
`CODEX_REMOTE_PYTHON`。首次安装默认关闭 SSH，升级保留既有启用／关闭状态。

Codex 移动 home 后更新远端根目录。发现机制可在迁移期间保留今日记录，但冲突目录
和读取失败仍明确报告不完整。临时失败可保留兼容的同日远端缓存，不编造新远端活动。

## 数据过期、未知或服务日期较旧

`—` 是未知，`0` 是已知值。**Fetched** 为原始查询时刻，不保证统计更新到该时刻。
工作空间服务日期保留在提示／VoiceOver 中，可能与 Mac 日期不同。缓存不会重置时钟。
详见[标签、周期与时间](data.zh-CN.md#标签周期与时间)。

检查 `~/Library/Logs/BeaverMeter/` 以及对应服务连通性：`chatgpt.com`、
`api.anthropic.com`、`cursor.com`、`platform.deepseek.com`。某来源失败不代表全部失败。

完整刷新占快照锁时，快速本地轮询不改变快照直接退出，下次计划轮询照常运行。
它消除冗余等待采集器，不等于所有 UI 卡顿已解决。[运行报告](../RUNTIME_PERFORMANCE.md)
区分清醒区间、尚未取得的帧耗时和受控修复后比较。

## 小组件为空或某模块消失

检查 **Services** 和该小组件的 **Edit Widget**。Small 只读前两槽，Medium 前四槽，
Large／Extra Large 前六槽。空、重复、无效或隐藏选项不会由后续补位。已删除工作空间
保持不可用直到重新选择；更多来源空间不自动出现。明确空选择保持空。

## 小组件缺失或重复注册

优先使用一个受支持安装目录。改变应用身份时，macOS 可能需要移除该身份的小组件
再添加 BeaverMeter。源码目录中的修复工具为：

```sh
./scripts/repair_widget.sh
```

它协调注册、刷新 WidgetKit 缓存并重新打开应用。仅在需要修复时使用，不作为周期刷新。
保留设置与登录，小组件空白本身不意味着需要删除数据。

## 更新失败或未能重新启动

安装前先完成账户登录。下载／验证失败应保留当前应用；未能重启时重新打开已安装
BeaverMeter 完成运行状态恢复。源码／本地安装包不使用实时更新源，他人拥有的应用目录
可能需要管理员授权。不要为绕过错误关闭签名验证或替换发布密钥。

## 提交问题

提供应用版本／build、macOS 版本、服务／小组件尺寸，以及当时是实时、过期还是未知。
优先给合成复现，遮去邮箱及私有 profile／主机名。不要附认证文件、浏览器 token、
Cookie、提示词、完整 transcript 或未经检查的真实快照。
