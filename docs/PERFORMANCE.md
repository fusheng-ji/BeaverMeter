# Performance — 2026-10-25

This pass removes repeated collection, decoding and formatting work without
changing token counters, account isolation, refresh intervals or network requests.
The compact workspace usage label now reads `tokens today`; its original service
bucket/report dates remain in help and accessibility details. This label change
does not establish a new current-day data source.

Installed-process samples, manual menu observations and the pending collector
contention follow-up are recorded in [Runtime performance](RUNTIME_PERFORMANCE.md).

## Changes

- The collector reuses one compact daily/scope summary instead of decoding and
  traversing the seven-day scan cache again for workspace activity. One bucketing
  pass replaces repeated per-day and per-account filters. Standalone callers and
  incompatible summaries retain the scanner fallback.
- Workspace presentation parses each service date once, indexes its value and
  reuses that index for validation, the latest reading and seven history slots.
  Invalid dates, conflicting duplicates, true zero and missing days retain their
  existing behavior; local/global counts never fill missing workspace readings.
- `SnapshotFileReader` performs file reads and JSON decoding off MainActor.
  Device/inode, size and nanosecond modification time detect replacement; unchanged
  files reuse one immutable snapshot with shared value storage, without retaining
  the JSON data. A second file check rejects reads that crossed a replacement.
  Monotonic revisions prevent late async results from rolling back same-second
  updates. Concurrent authentication/polling consumers can read the same revision,
  and cancellation/suspension guards preserve the refresh lifecycle.
- Menu-bar updates observe relevant snapshot/settings/appearance changes, skip
  equivalent output and replace the cached logo only when its variant changes.
  The existing popover host and image caches remain reused.
- Amount formatters use a locked, **32-entry** cache keyed by currency/precision.
  Configuration and use are serialized. Relative formatting reuses one formatter
  and rebuilds it when the current calendar/time zone changes. Exact `en_US`
  output, precision, fallback strings, negative zero and special values are preserved.

## Measurements

These are same-machine optimized synthetic workloads, not desktop frame timings.

| Workload / metric | Before | After |
| --- | ---: | ---: |
| Collector, 42,000 records: warm median wall time | 5.881 s | 0.82788 s |
| Same collector: median CPU time, user + system | 4.23 s | 0.75 s |
| Same collector: median process peak RSS | 116.3 MB | 110.2 MB |
| One workspace, 365-day presentation: median per projection | 9.97 ms | 0.556 ms |
| USD formatting: median per call | 44.11 µs | 0.773 µs |

Collector fixtures contain 28 files, seven days and two workspaces, with networking
disabled. Each executable has five warm child-process measurements; its output
counter hash is identical before and after. RSS uses decimal MB. The presentation
comparison uses three runs of 100 projections per revision. Formatting uses the
same Release binary, alternating 50-call batches, with 2,000 calls per variant
and exact before/after output checks.

Host contention affects elapsed times. The collector's full scan-cache decode
still dominates part of its memory footprint. Relative-age/reset timings were
essentially unchanged; currency churn beyond the cache's capacity was about 12%
slower, rather than growing an unbounded cache. Three passive App/Widget samples
did not show monotonic RSS growth. No memory leak or sustained production RSS
reduction is claimed, and microbenchmarks do not prove smoother desktop rendering.
After installation and menu interaction, three 10-second-interval samples showed
App RSS **49.1–51.0 MiB**, Widget RSS **36.9–37.0 MiB** and unchanged accumulated
CPU time across that 20-second window. These warm processes used more RSS than
the varying pre-install passive samples (App 19.2–39.7 MiB, Widget 16.9–28.4 MiB).
UI/cache warm-up and OS residency were not controlled, so this is neither proof
of a regression nor evidence of reduced resident App/Widget memory. The measured
memory improvement above applies only to the fixed collector workload.

## Validation and evidence

The full suite passed **455 XCTest cases, 0 failures: 232 app + 223 collector**.
Seven formatter tests cover exact output, precision, currency churn, time-zone/DST
changes and concurrent mixed calls. The four-stage Account API and five-stage
legacy CLI integrations also passed. Signed Release and PreviewRenderer builds
passed; 24 four-size/color-mode previews were generated and representative
Small, Medium, Large and Extra Large images were inspected. The installed native
Large widget shows `tokens today`, four rows and the existing subscription labels.
Menu history navigation was exercised and restored to today. Deep/strict signing,
four embedded-file hashes, one production Widget registration and the absence of
QA registration were verified; all five configuration-file hashes are unchanged.
Native frame timings and the full family/theme/focus matrix were not measured.

Local diagnostics are under `.build/performance-optimization/`:

- `collector-report.json`, `collector-before-release.json`, `collector-after-release.json`: workload, counters, CPU/RSS and limitations.
- `comparison.json`: presentation methodology and runs.
- `formatting-before-after.json`, `formatting-tests.log`: formatter comparison and seven-test result.
- `process-baseline.json`, `audit-findings.json`: passive samples and source audit.
- `process-after.json`: matching post-install passive samples.
- `install-audit.json`, `desktop-large.{jpg,txt}`, `menu-interaction.txt`, `previews/`: installation and native/offline visual evidence.

Benchmark diagnostics use synthetic fixtures or process counters; benchmarks do
not read authentication, modify settings or write production snapshots. Native
acceptance screenshots show the installed app's existing accounts; saved
accessibility text redacts email addresses.
