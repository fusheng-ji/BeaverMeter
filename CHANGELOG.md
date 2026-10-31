# Changelog

## [Unreleased]

## [1.0.2] — 2026-10-31

**Build 39.** Claude quota compatibility, Antigravity support and Widget spacing.

### Added

- Google Antigravity service monitoring with independent Gemini and Claude/GPT
  allowance windows, reset times and statuses. Each quota pool is a selectable
  Widget module; today's local token total and available categories stay in the menu.
- Reuse the official Antigravity App/`agy`/IDE local service for quota reads,
  without a separate Google OAuth flow. Temporary quota caches keep their original
  measurement and expire after 30 minutes; authentication failures clear them.
  CLI processes started for collection are cleaned up after completion or cancellation.
- Antigravity light/dark logo assets from Google's official press kit, five-service
  combination previews and dedicated pool, capacity, unknown/zero and reset-caption
  fixtures. Snapshot schema 8 retains compatibility with prior supported snapshots.

### Changed

- Normalize Claude's former Max 5x to Max and Max 20x to Ultra, including legacy
  metadata and saved display labels. Weekly allowance leads the summary; model
  windows remain separate.
- Show Claude's five-hour window only when returned by the current successful
  response. Verified Ultra accounts can have no session limit, while temporary
  limits on unverified Ultra accounts remain visible. Successful responses replace
  prior windows, and a single weekly window is shown in the menu.
- Use a 2×2 menu footer when four quota summaries are visible, keeping Cursor's
  remaining-amount-only summary and existing Widget module selections and capacities.
- Adapt current `agy` local CSRF checks using a temporary nonce bound to the
  exact CLI process BeaverMeter starts. Local handshake failures remain retryable
  and do not ask the user to sign in again. Normal refresh cancellation cleans up
  the owned process group before exiting and does not publish partial readings.
- Read Antigravity SQLite logs through bounded private DB/WAL snapshots, including
  cold WAL files and recognized unkeyed error-message steps. Original logs remain
  unchanged; incomplete scans still cannot publish a guessed zero.
- Center quota-only Antigravity tiles in sparse Extra Large layouts. Constrain
  long reset captions to their columns and omit an optional Medium secondary
  window when needed, fixing clipping found in actual desktop WidgetKit checks.
- Apply one fixed spacing policy to every Widget family and visible module count.
  Optional details yield before card padding; long names and reset descriptions
  stay within their columns, and narrow monetary values retain a separate currency
  line when necessary. Existing module order and 2/4/6/6 capacities are preserved.

### 中文更新说明

- Claude 套餐名称统一为 Max／Ultra，优先周额度，仅展示本次响应实际返回的 5h 窗口。
- 新增 Antigravity，Gemini 与 Claude/GPT 额度独立展示；菜单保留本机日志 token 明细。
- 支持复用官方 `agy` CLI 后台刷新，临时缓存按时过期，关闭服务后停止采集。
- 四尺寸组件采用统一安全留白，辅助信息按空间收减，保留主额度、币种和重置。
- 保留账号、工作空间、设置及现有组件模块顺序和容量。

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
