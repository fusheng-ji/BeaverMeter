# Changelog

## [1.0.1] — 2026-10-28

**Build 38.** Cursor sign-in and automatic-refresh fix.

### Fixed

- Read Cursor's newer encrypted macOS sign-in format. Previously the collector
  parsed the encrypted storage envelope as a JWT and failed before it could
  request usage data. Older plaintext sign-ins remain supported.
- Add **Allow Cursor access…** with progress and cancellation when macOS Keychain
  permission is needed. Only this explicit action may request authorization;
  scheduled collection stays noninteractive.
- Reuse an API-verified Cursor session for background refresh. On the affected
  local installation, selecting **Always Allow** did not make subsequent helper
  reads succeed. The verified access token is now stored in BeaverMeter's private
  application-data directory (directory `0700`, file `0600`), bound to the current
  Cursor database and sign-in. The Cursor Safe Storage key is never cached, and
  credentials are never written to usage snapshots.
- Reject expired, changed, malformed or insecure cached sessions. An authentication
  rejection clears the matching session; temporary network failures preserve it.
  Changing Cursor sign-in requires verification again.

### Validation

- 509 Swift, 45 Python and 6 Node tests passed locally, together with collector and
  installation/runtime integrations. The Universal app and mounted DMG passed
  architecture, metadata, resource and signature validation.
- A passive five-minute observation and the next scheduled collection confirmed
  fresh Cursor readings without manual refresh or an authorization request.
  See the [validation record](docs/RELEASE_VALIDATION.md) for scope and limits.

### 修复说明

- Cursor 新版在 macOS 上加密保存登录信息；旧采集器把加密内容当作 JWT，
  因而在请求用量前就报错。本版本支持解密读取，同时兼容旧版明文登录信息。
- 菜单新增 **Allow Cursor access…**，支持授权进度与取消。仅主动授权操作可以
  请求系统许可，后台采集始终静默运行。
- 受影响的本机安装在点击「始终允许」后，后续采集进程仍无法读取钥匙串。
  现在仅在官方用量接口验证成功后，将访问令牌保存在 BeaverMeter 私有目录，
  绑定当前 Cursor 数据库与登录信息；不保存 Safe Storage 密钥，也不把凭据写入用量快照。
- 登录变化、令牌过期或接口拒绝认证时重新验证；临时网络故障保留有效会话。

## [1.0.0]

**Build 37.**

### Features

- Native macOS menu-bar monitoring for Codex, Claude Code, Cursor and DeepSeek,
  with independent service states, service switches and remembered foldouts.
- Separate Codex workspace logins, plans, quotas and verified account ledgers.
  Provider-wide local/optional-SSH totals remain independent; a workspace never
  borrows another account's values. Original service periods and query/response
  clocks remain available behind the `tokens today` display.
- Claude transcript totals, API-price estimates and online quota/reset readings
  stay separate, with explicit login, verification, Keychain access and cancellation.
  Cursor shows actual charges and individual monthly allowance; DeepSeek retains
  returned currencies and current-month wallet/activity data.
- Independently ordered Widget modules with limits **Small 2 / Medium 4 / Large 6 /
  Extra Large 6**. Identity stacks logo, workspace name when present and known plan.
  Small keeps both allowance values/main reset; Medium adds reset details; Large
  adds module activity. Extra Large retains quota/current usage but omits seven-day
  statistics/trends when exactly four modules are visible in 2×2; other counts
  keep available trends.
- Large two-to-four modules use full-width rows. Quota, activity and history
  statuses are independent; zero differs from unknown. Inventory/expiry, Cursor
  used/limit, token categories and individual calls remain in the menu.
- Light/dark and reduced-color rendering, local seasonal beaver appearances,
  bilingual guides and canonical synthetic screenshots.
- Universal-DMG installation and first-launch Widget/background setup, with
  configuration preservation and recovery. Eligible official builds use Sparkle
  startup/twelve-hour checks and a versioned Update button; checks do not
  automatically open a window or install.

### Reliability and performance

- Reused daily/scope summaries avoid duplicate collector-cache traversal;
  presentation parses each service date once. Bounded locked formatter reuse
  preserves exact output, precision, special values and time-zone behavior.
- Snapshot IO/decoding runs off MainActor. Cached immutable reads, revision gates
  and cancellation checks protect concurrent authentication/polling and same-second
  updates. Equivalent menu labels/images avoid repeated work.
- Fast local polls coalesce on snapshot-lock contention instead of waiting behind
  a full refresh. Full refresh/authentication keeps the normal lock and cadence.
- Authentication/identity failures clear protected values; temporary fallback
  retains its original measurement times. Update recovery preserves account data.

### Validation

- Regression coverage includes scoped counters, zero/unknown, schema compatibility,
  authentication cancellation, asynchronous read ordering, module limits and
  cross-process lock behavior. Isolated Sparkle tests use temporary keys and a
  loopback feed; they are not a public-release end-to-end claim.
- [Performance measurements](docs/PERFORMANCE.md), [runtime observations](docs/RUNTIME_PERFORMANCE.md)
  and the [validation record](docs/RELEASE_VALIDATION.md) document actual scope.
  Synthetic improvements do not prove frame rates, absence of leaks or resolution
  of the recorded 493 ms awake interval. A visible usage label does not change
  the account API's reporting period.
