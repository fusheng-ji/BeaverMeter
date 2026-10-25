# Codex today-token sources

Investigation date: **2026-10-25**. The inspected sources do not establish a
complete, current-day token total for Personal or Plus. Keep the available
dated profile reading; do not label a residual, percentage, credit amount or
outdated zero as today's measured usage.

## Findings

| Source | Observation | Limit |
| --- | --- | --- |
| Profile ledger | `stats_as_of` reports **2026-10-24**; `generated_at` is the later response-generation time | The reported date is not a proven immutable event cutoff or proof of the machine's current-day coverage |
| Lifetime minus daily buckets | Personal: 62,706,421,629 − 62,411,913,160 = **294,508,469**; Plus residual is zero | Personal's returned daily range is 2025-10-24–2026-10-24. A lifetime count and an annual window have no proven equal cutoff or coverage; their difference is not a today counter |
| Cumulative / weekly buckets | Personal cumulative buckets equal the returned daily prefix sums; their last value and the weekly sum equal 62,411,913,160 | These are accumulations of the returned window, not an independent all-time or real-time ledger |
| Personal daily endpoint | Both matched contexts return `units: "percent"`; Oct 25 has empty models | Percentages cannot be converted to raw tokens |
| Plus workspace-user daily endpoint | Oct 24 raw components are 3,119 uncached input + 365,696 cached input + 799 output = **369,614** total | The profile reports **501,550** for the same date. Coverage or freshness differs; do not combine them or assign the difference to an unproven category |
| Oct 25 raw fields | The Plus daily response contains zero raw fields, with `data_freshness_ts: "2026-10-24T22:00:00Z"` | This timestamp is Berlin Oct 25 **00:00** (UTC+02:00), not coverage of today's elapsed hours. It does not establish measured today usage of zero |
| Credit events | No raw token counts in the inspected response | Credits are not interchangeable with tokens |
| Profile page / thread estimates | Current credential/client contexts receive **403** | No usable result; the status alone does not establish a specific missing permission or authentication requirement |

The Berlin conversion above does not establish the API bucket time zone.
Installed date-range code constructs UTC `yyyy-MM-dd` labels; the observed
Oct 24–25 query returns both dates, so its end date is included in that response.
Missing dates and empty model lists still do not prove complete zero usage.

The earlier profile counts are timestamped samples, not frozen totals. At the
**00:50 UTC** production fetch and **00:53 UTC** follow-up, Personal's Oct 24
bucket had increased from **136,824,920** to **203,312,014**. Its lifetime and
last cumulative count increased by the same **66,487,094**, while the lifetime
minus returned-daily residual remained **294,508,469**. The other 142 daily
buckets were unchanged; Plus remained **501,550** on Oct 24. Both responses
still reported `stats_as_of: "2026-10-24"`. An older dated bucket can therefore
still update. These observations do not distinguish a service-day time zone
from delayed or backfilled events, and do not establish Pacific, UTC, or the
machine's local day as the aggregation calendar. Comparisons with local/remote
record windows did not establish an exact event-window mapping or request-account
attribution. Do not describe the profile as fixed at yesterday's cutoff.

The Plus model totals and `premium_usage_values` surface totals contain the
same observed counts. They are overlapping projections, not amounts to add.
Choose a validated `text_total_tokens` **or** uncached input + cached input +
output; never add the total to its components. Installed token-chart code reads
`groups ?? models`; its premium-container path serves the credit chart. No
inspected contract establishes that premium, included, regular, overage or
discounted categories can be summed into a complete account total.

## Declared reads

These routes were found in OpenAI source or the installed application, not
guessed through endpoint enumeration. Account contexts stay strictly matched;
header overrides are not used.

| Method / path below `/backend-api` | Declared input / consumed fields |
| --- | --- |
| GET `/wham/profiles/me` | No declared today/refresh query; `stats.lifetime_tokens`, nullable daily buckets `{start_date,tokens}`, response metadata |
| GET `/wham/usage/daily-token-usage-breakdown` | `start_date`, `end_date`, `group_by=day`; `units`, `data_freshness_ts`, dated model values |
| GET `/wham/usage/daily-workspace-user-token-usage-breakdown` | Same base query; a UI variant adds repeated `breakdown_by=model`, `modes=codex`, `modes=work`; dated raw input/cache/output/total fields |
| GET `/wham/usage/credit-usage-events` | No declared time filter in the inspected call; credit events |
| GET `/profiles/me/page` | Matched account header; no declared today/refresh filter |
| POST `/wham/usage/thread-estimates/query` | `{threads:[{thread_id,turn_ids}],include_settled_response_ids:true}`; estimated USD and optional settled response IDs, not a complete dated token ledger |
| POST `/wham/usage/thread_usage/query` | `{thread_ids:[...]}`; thread-level estimated usage and optional token groups, without request timestamps or account-day totals |

The two daily GET calls declare `x-openai-codex-usage-categories: 1` and poll
every minute in the installed UI. Polling is a client policy, not a guarantee
that backend statistics include the current minute. No declared
`include_today` or profile force-refresh flag was found. `account/usage/read`
with `threadId` takes the aggregate `thread_usage/query` branch and returns null account
summary/daily buckets; it is not a real-time account total.

The inspected common request headers do not declare a profile time-zone
header, and the profile GET has no declared time-zone parameter. Chat,
file-upload and voice request bodies carry time-zone fields, while native
attestation carries a time-zone signal; neither establishes a statistics-calendar
contract for this endpoint. The investigation did not change runtime settings,
authentication, cookies or the application's time zone.

## Time labels and evidence

**`Fetched HH:mm <zone>`** means the client query/read time. **statsAsOf** preserves
the service's reported date; it is not an exact immutable event cutoff.
**generated_at** is the response-generation time. Neither fetch time, response
generation nor the outer snapshot's `generatedAt` substitutes for a source
statistics-update timestamp. `data_freshness_ts`, when returned by a different source, describes
that source and must not be transferred to the profile ledger. Cached readings
retain their original fetch time across failures and unrelated fast refreshes.

Diagnostics are local, outside release screenshots:

- `.build/widget-today-token-investigation/today-source-report.json`: conclusion and rejected derivations.
- `samples.json` / `findings.json` in that directory: repeated matched-context profile counts and metadata.
- `profile-followup-delta.json`: the changing Oct 24 bucket, matching lifetime/cumulative increment and unchanged residual.
- `record-window-correlation.json` / `record-window-correlation-summary.json`: local/remote time-window comparisons, without a proven profile event-window or account mapping.
- `daily-breakdown-probe.json` / `daily-breakdown-two-day.json`: units, date boundaries, nested counts and freshness.
- `credit-events-probe.json`, `profile-page-compat-probe.json`, `thread-estimates-probe.json`: actual response outcomes and limitations.
- `.build/widget-plus-source-investigation/declared-daily-usage-contracts.json`, `daily-token-field-semantics.json`, `expanded-route-inventory.json`: static route contracts, arithmetic rules and source hashes.
- `.build/widget-plus-source-investigation/profile-timezone-contract-review.json`: profile/common-header review, native time-zone signal limits and source hashes.

The pinned upstream revision is
[`openai/codex@970111f6`](https://github.com/openai/codex/tree/970111f6cb62cc02fe36a82ea7d71b37a2889c97).
Its backend-client types and account processor keep profile summaries separate
from thread estimates. Installed bundle source hashes and function offsets are
recorded in the investigation directory. Diagnostic artifacts retain shapes,
counts, timestamps and hashes; they do not store real identifiers, authorization
header values, cookies, prompts or response text. Endpoint/header names above
describe the contract only.
