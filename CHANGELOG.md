# Changelog

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
