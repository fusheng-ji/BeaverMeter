# Runtime performance — 2026-10-25

These observations concern the installed app and Widget, separately from the
[synthetic benchmarks](PERFORMANCE.md). They confirm collector lock contention
and some long main-run-loop awake intervals. Animation frame times, the cause
of each menu hesitation and a memory leak are not established. The confirmed
collector lock wait is fixed by coalescing a contended local poll; a controlled
post-fix animation comparison has not been performed.

## Six-minute process observation

`.build/runtime-performance/summary.json` and `analysis.md` cover
**10:42:21.681–10:48:21.548 UTC**: 715 samples over 359.86 seconds. Requested
spacing was 0.5 seconds; actual median spacing was 0.503 seconds. This mixed
window includes collector activity, UI attempts and a failed profiling attempt;
it is not a pure idle baseline.

| Process | Observed CPU delta | Average of one core | RSS first / peak / last |
| --- | ---: | ---: | ---: |
| BeaverMeter | 1.56 s | 0.43% | 16.41 / 50.86 / 15.36 MiB |
| Widget extension | 2.43 s | 0.68% | 19.67 / 34.64 / 13.83 MiB |

CPU percentages divide cumulative CPU changes by observed duration; they are not
instantaneous utilization. Short-lived children and work outside their first/last
observation can be missed. NotificationCenter is shared, so its CPU cannot be
assigned entirely to this Widget. RSS includes shared resident pages and must
not be summed as privately owned physical memory.

Separate `vmmap` snapshots report physical footprint, with the tool's `M` units
preserved verbatim:

| Snapshot | App current / peak | Widget current / peak |
| --- | ---: | ---: |
| Earlier `*-before-vmmap.txt` | 47.5M / 61.0M | 12.3M / 13.6M |
| Later `*-current-vmmap.txt` | 45.8M / 59.8M | 12.1M / 13.6M |

These are not matched workload/retained-heap measurements. They neither prove a
before/after memory reduction nor rule out leaks.

The **90-second Animation Hitches recording failed with exit 139** and an invalid
export. Its unusable 7.7 GiB trace was removed; `trace-failure.json` retains the
failure metadata. No hitch duration, frame rate or animation-latency result is
available from that attempt.

## First manual menu reproduction

The user performed the first requested ten-click batch at
**12:18:08.587–12:18:27.101 GMT+1**. The log contains **11 `menu_did_show` and
11 `menu_did_close` events**, with 11 matching `menu_will_show` events. These
are lifecycle counts, not an independent physical-click count or proof that
every animation finished. No accessibility automation ran during this window.
Earlier automated attempts did not establish true repeated visible cycles and
are excluded.

`manual-processes.json` covers 36 samples inside that window, from
**12:18:09.040 to 12:18:26.680 GMT+1**, spanning 17.640 seconds:

| Process | Observed CPU delta | Average of one core | RSS first / peak / last |
| --- | ---: | ---: | ---: |
| BeaverMeter | 1.71 s | 9.69% | 55.86 / 58.91 / 58.00 MiB |
| Widget extension | 0.00 s at recorded precision | 0.00% at recorded precision | 24.125 / 24.125 / 24.125 MiB |

A zero recorded delta does not prove zero work. This workload differs from the
six-minute capture and is not a controlled before/after comparison.

`manual-interactions.ndjson` records four completed awake intervals in the manual
window: **104.356, 493.263, 139.791 and 137.417 ms**. The observer measures wall
time from main-run-loop `afterWaiting` to `beforeWaiting`, reporting intervals of
at least 100 ms. It excludes the intervening asleep periods. Awake intervals can
contain work or waits: they are **not CPU time, frame durations or click-to-visible
latency**. The 493 ms interval warrants stack correlation; the first capture does
not identify its cause.

## Confirmed collector contention

`overlap-33919.txt` samples an app-child collector at **12:11:36 GMT+1**. Its main
thread is inside `SnapshotWriter.Lock.init → lockf → __fcntl` in **280/280
samples**. This confirms a blocked **collector** thread, not a blocked App
MainActor. The six-minute report described lock waiting only as a hypothesis;
this later stack supplies direct evidence.

The overlapping full collector's `overlap-33818.txt` includes
`CostUsageFetcher → loadClaudeDaily → CostUsageClaudeCacheIO.load → JSONDecoder`
on its cost-usage scan queue. This identifies a sampled Claude-cache decoding
phase. It does not assign the collector's whole lifetime to that phase or prove
that contention caused a particular menu awake interval.

The fix uses `SnapshotWriter.tryLock` for `--codex-only` and `--local-tokens`.
When another refresh owns the snapshot lock, the redundant poll immediately
returns success without reading/replacing the snapshot. The next scheduled
poll still runs; full refreshes and authentication retain the blocking lock.
This can defer the next local reading until that following poll (normally 45 s)
after the in-flight refresh releases its lock. Counters, account scopes and
configured refresh intervals remain unchanged. Filesystem failures remain errors;
only actual nonblocking record-lock `EACCES/EAGAIN` results mean contention.

All **227 collector tests** passed. The isolated cross-process CLI integration
holds a real POSIX lock in a Python parent: the two fast flags return in about
**19/15 ms**, leaving snapshot bytes, mtime, mode, inode and settings unchanged.
An independent probe confirms the original holder retains its lock. Full refresh
waits until release; subsequent polls work, and open permission failures are not
mistaken for contention. Existing API and legacy-cache CLI integrations also pass.

## Additional main-thread sample

`manual-mainthread-sample.txt` covers **12:19:35–12:21:35 GMT+1** at 5 ms spacing.
The second requested manual reproduction was not captured in that window, so it
is a background-runtime sample rather than a second menu-cycle measurement.
Of 21,491 main-thread samples, 21,373 (99.45%) are in normal event-loop Mach wait;
including other synchronous Mach IPC waits gives 21,412 (99.63%). The remaining
paths include small amounts of AppKit/Core Animation and SwiftUI layout; token
projection appears twice. There is no sustained main-thread compute loop in
this sample. The folded tree has no per-sample timestamps: even though it covers
168.879/111.504 ms awake logs, it cannot assign a particular stack to either
interval, or explain the earlier manual 493 ms interval.

## Instrumentation and current status

`RuntimePerformance` uses opt-in OSLog debug events with fixed lifecycle names
and durations, without account payloads. Its main CFRunLoop observer adds no
timer or wakeup and is removed when disabled/stopped. The diagnostic app also
supports the standard accessibility cancel action; that does not retroactively
validate earlier automated interaction attempts. Diagnostics leave token
counters, account scopes and configured refresh frequency unchanged.

| Item | Status / limit |
| --- | --- |
| Diagnostic app tests | 238 app tests passed, 0 failures |
| Signed final installation | Installed; strict signature and all four embedded-file hashes match; five settings hashes unchanged; one production Widget registration, no QA registration |
| Nonblocking fast-poll/coalescing fix | 227 collector tests + genuine cross-process CLI passed; signed Release installed; same isolated contention test also passed using the installed helper |
| Additional 120-second main-thread sample | Background waiting dominates; second manual batch not captured |
| Controlled post-fix interaction and memory comparison | Pending |
| Native frame/hitch metrics | Not established |

Final native Large capture (`desktop-final.jpg/.txt`) retains Personal, Claude,
Cursor and Plus in four rows, subscription labels and `tokens today`. Existing
service settings, account/workspace configuration and appearance are unchanged.
Temporary Finder windows were closed and all profiling/log-stream processes ended.
The failed large trace was removed; lightweight evidence occupies about 6 MiB.

Local evidence is under `.build/runtime-performance/`: `summary.json`,
`analysis.md`, `processes.json`, `*vmmap.txt`, `manual-interactions.ndjson`,
`manual-processes.json`, `overlap-33919.txt`, `overlap-33818.txt` and
`trace-failure.json`. The second reproduction's planned
`manual-mainthread-sample.txt` needs a completed, valid capture before results
are added. This documentation analysis does not operate the UI, run builds,
change authentication/settings or initiate live account calls.
