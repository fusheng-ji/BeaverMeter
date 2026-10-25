# Data sources and privacy

[简体中文](data.zh-CN.md) · [README](../../README.md)

## Readings have different scopes

| Reading | Source and meaning |
| --- | --- |
| Menu’s provider-wide Codex tokens/history | Configured local logs plus optional SSH, deduplicated across sources |
| Selected Codex workspace tokens/history | Official account-profile ledger in that workspace’s verified native account context |
| Codex quota/reset credits | Existing Codex sign-in and the provider’s allowance/reset interfaces |
| Claude tokens/history | Local Claude Code transcripts; cost is an API list-price estimate |
| Claude quota/limit resets | Claude Code’s current sign-in and usage interface |
| Cursor | Official Dashboard actual charges and individual monthly allowance |
| DeepSeek | Official Platform wallet and current-month usage |

These readings are not interchangeable. Quota percentages cannot be converted
into token counts; model list prices are not subscription charges. A failed
workspace reading never inherits a provider-wide or sibling workspace total.

## Codex

### Local and optional remote activity

The collector uses pinned [CodexBarCore](https://github.com/steipete/CodexBar/commit/07f2a670229bca1a34bb7eda5284c89657b8df9a)
and BeaverMeter’s record scanner. Active and archived rollouts are searched,
including appended records in a still-running task, regardless of the original
date directory. Duplicate responses and compressed/session formats are handled
without reading model content into usage snapshots.

The current local day’s total is **input + output**. Cached input is a subset
of input; reasoning is a subset of output. Neither is added twice.

An optional SSH scanner reads the configured remote Codex directory. It returns
hashed response/session identifiers, timestamps and counts; prompts, responses
and credentials do not leave that host. Local and remote responses are
deduplicated before display. Same-day remote cache can cover a temporary SSH
failure, marked incomplete/stale. Changing the source invalidates its old totals.

Active Codex app-server homes can be discovered in addition to the configured
home; duplicate records are removed. Multiple conflicting active homes are
reported as incomplete rather than silently choosing one. Existing discovered
records can remain available after a process exits. Old sessions whose response
history cannot be safely deduplicated are excluded and marked incomplete.

Completed scans can correct previous counts downward or to real zero. Partial
scans can preserve a higher compatible cached count only for the same source,
local day and time zone. Read failures remain distinct from a valid empty result.

### Workspace ledger and identity

Workspace activity reads `GET /backend-api/wham/profiles/me`. Collection requires
agreement between the selected workspace, native credential metadata and access
JWT account. An ID JWT, when present, must match too. An account-header override
is rejected; a successful response alone does not validate its scope.

Only totals and raw dated buckets are retained. Input/output/cache/reasoning
breakdowns are not invented from this API. A workspace’s ID and known plan keep
its quota/identity together, but the display ID alone does not validate a ledger.

The log field `creator_account_id` identifies the immutable thread creator,
not the account that made every request. Local/remote records retain diagnostic
creator hashes, not request-account proof. They remain useful globally and do
not fill workspace ledger gaps. The optional record-attribution path requires
explicit typed request-account evidence and a valid matching scope hash; current
creator-only logs do not provide that evidence.

### Labels, periods and clocks

Workspace rows use **tokens today** for the latest returned dated bucket;
lifetime-only responses use **tokens total**. The original service bucket date
and `statsAsOf` report date remain in help/accessibility details. Date labels are
preserved without inferring the server’s time zone. A dated bucket may still
update: its date is not a proven immutable event cutoff.

**`Fetched HH:mm <zone>`** is the client query time. Response `generated_at` is
retained separately; neither is the source statistics-update time. Cache fallback
keeps both original times. The outer snapshot’s newer `generatedAt` does not
refresh an old reading’s clock.

Missing/null dates stay unknown, not zero. An explicit valid zero stays zero.
Lifetime minus a finite daily window, percentage/credit amounts and outdated
zero buckets are not substitutes for an independently measured local-today total.
The visible label does not change those source limits.

Workspace seven-day trends end at the latest returned service day, with gaps
preserved. Menu provider-wide **Last 7 days** instead covers today and the prior
six Mac-local days. Hover/click in the menu selects a day and its recorded
categories; these local totals are separate from workspace API totals.

### Quota and banked resets

Codex quota uses the existing login and `/backend-api/wham/usage`; windows are
identified by `limit_window_seconds`. The principal summary follows the
available allowance windows; credits-only/unlimited data does not create a
fabricated percentage. `/wham/rate-limit-reset-credits` supplies read-only banked
reset counts. The menu retains exact expiry, unknown expiry and restrictions;
BeaverMeter never redeems a reset.

## Claude Code

The local scanner reads `$CLAUDE_CONFIG_DIR/projects`, or the supported default
Claude Code/Desktop transcript stores. Streaming chunks are deduplicated by
message/request identity. Its scan index is private to BeaverMeter under
`claude-cost-usage/`.

Claude’s `input_tokens` excludes cache traffic. The displayed total is
**input + cache write + cache read + output**. The estimated cost uses
CodexBarCore’s bundled API prices; unsupported models have no invented cost,
and a Pro/Max subscription is not billed at that estimate. No transcripts means
no data, rather than a measured zero.

Online windows use `https://api.anthropic.com/api/oauth/usage`, including the
five-hour, all-model weekly and model-specific limits. Widgets prefer all-model
weekly when present and keep the five-hour value; other windows remain in the
menu. **Limit resets** shares the same authenticated usage request, including
the reset-credit request surface used by the supported CLI. Missing reset fields
do not imply zero or prevent valid quota display.

Credentials follow the configured profile’s Keychain-first selection, using
that profile’s credentials file only when no readable Keychain document exists.
Secure-storage overrides do not borrow another profile. Native background reads
disable authentication UI. A verified existing system-reader compatibility path
can be reused without modifying an item’s ACL; credential output stays in a
bounded memory pipe, never a temporary file.

Only explicit **Allow Claude access…** may request system authorization.
**Repair Keychain session…** requires separate confirmation. A Keychain error is
not silently converted to sign-out.

Expired tokens are renewed by Claude Code itself: BeaverMeter can briefly start
the configured CLI, wait for a replacement login and stop it, at most once per
five minutes. It sends no model prompt and does not answer a folder-trust dialog.
It does not directly rotate Claude Code’s refresh token. `CLAUDE_CLI_PATH`
selects the CLI; `CLAUDE_CLI_REFRESH=0` disables that renewal attempt, and
`CLAUDE_KEYCHAIN_ACCESS=0` disables Keychain access.

Confirmed expiry/authentication failures clear protected quota/reset caches
before renewal. A rejected token is not retried as if renewed. CLI absence,
cooldown and incomplete renewal remain retryable states; browser sign-in is
reserved for an actual missing or rejected login.

## Cursor

The collector reads Cursor’s existing `state.vscdb` login in process memory and
uses the official Dashboard interfaces:

```text
https://cursor.com/api/dashboard/get-filtered-usage-events
https://cursor.com/api/usage-summary
```

Each call’s charge uses `chargedCents`, the amount actually deducted. `$0.00`
calls remain visible. If an otherwise valid call has an unknown actual charge,
its charge stays unknown and the daily total is withheld rather than understated.

Monthly allowance prefers `individualUsage.plan`, then a valid individual
`overall` allowance, including supported Enterprise responses. Team pools and
administrator Team Caps are not presented as individual allowance. The menu’s
quota footer shows remaining USD; used/limit remain in help. Known membership
metadata can supply the plan name, never a price/limit inference.

## DeepSeek

Explicit browser connection reads only the official Platform’s `userToken`.
Chromium-family extraction and Safari Apple Events access are limited to that
site/session. The validated token is saved locally with mode `600` for future
background reads.

```text
https://platform.deepseek.com/api/v0/users/get_user_summary
https://platform.deepseek.com/api/v0/usage/amount?month=<month>&year=<year>
https://platform.deepseek.com/api/v0/usage/cost?month=<month>&year=<year>
```

The requested period starts at the current local month. Token totals add
cache-hit input, cache-miss input and output once. Money keeps the returned
currency. No quota percentage or reset time is invented for a wallet balance.

## Refresh and failures

The app polls local Codex/Claude activity normally every **45 seconds**. These
polls do not call other providers or quota APIs. A fast poll encountering the
snapshot lock returns without publishing; the next scheduled poll still runs.
Full refresh/authentication retains serialized writes. Full background collection
defaults to **five minutes**, with an existing configured interval preserved.
WidgetKit controls the final five-minute-requested timeline schedule.

| Source/state | Behavior |
| --- | --- |
| Workspace API transient failure | Same verified context may retain a stale reading for at most three hours |
| Workspace auth/identity mismatch | Affected protected reading is cleared; no account fallback |
| Claude successful quota/reset | Shared success is reused for five minutes |
| Claude rate limit | Honor `Retry-After`, or persistent 5/10/20/30-minute backoff; manual refresh respects it |
| Claude transient cache | Original measurement retained for at most 30 minutes; passed reset windows are hidden |
| Claude expiry/auth failure | Old quota/reset success is invalidated before renewal |
| Other independent source failure | Preserve an eligible last reading as stale; missing live data never becomes demo data |

A cache-age warning is not a successful live verification. Quota, activity,
history and hidden reset inventory report independently. Hidden inventory
failures never change Widget quota status or accessibility.

## Storage and privacy

The private root is `~/Library/Application Support/BeaverMeter/`:

- `beaver-meter-snapshot.json`: schema 7 usage, compatible schema 5/6 reads; unsupported older snapshots are regenerated.
- `beaver-meter-settings.json`: provider choices.
- `beaver-meter-accounts.json`, `codex-workspaces/`: configured homes and separate managed logins.
- `beaver-meter-appearance.json`: appearance preference.
- `deepseek-platform-token`: validated DeepSeek token, mode `600`.
- Local scan/history caches remain scope/day/time-zone checked; cache schema and snapshot schema are separate.

The data directory is mode `700`; BeaverMeter writes its snapshot and private
configuration/credential files atomically with mode `600`. Usage snapshots contain no authentication tokens, cookies, prompts
or response content. They can contain display names, plan labels, counts,
timestamps and noncredential identity hashes; do not treat a real snapshot as
anonymous sample data.

Usage requests go to the relevant provider; optional SSH goes to the configured
host. Updates use the official GitHub Release feed/assets without provider
credentials or Sparkle system profiling. Disabled providers are not collected.
Canonical repository screenshots use synthetic fixtures. Original brand/provider
artwork attribution remains in [third-party notices](../../THIRD_PARTY_NOTICES.md).
