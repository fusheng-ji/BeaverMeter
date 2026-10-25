# Desktop Widget acceptance

The current contract is ordered user-selected modules with capacities **2/4/6/6**.
Each Codex workspace retains its own quota, plan and verified account API ledger.
Unknown, zero, cached and failed values remain distinct. No automatic workspace
expansion, overflow marker or global activity footer is present.

## Evidence available

The current candidate's build and offline checks are listed in
[release validation](RELEASE_VALIDATION.md). Canonical README images are frozen
synthetic offline renders, not desktop captures. The complete native matrix for
the current candidate remains pending; offline checks do not establish WidgetKit
compositing, focus transitions or update smoothness.

The runtime profiling record includes user-operated menu cycles and an observed
main-run-loop awake interval. Animation Hitches exited 139, so no frame-rate or
hitch-free claim is supported; see [runtime performance](RUNTIME_PERFORMANCE.md).

The profile service's dated buckets can change after their labeled day. No
complete local-today source has been established for both workspaces. The UI's
`tokens today` caption retains explicit service/report dates in help and
accessibility. `Fetched` denotes query time; optional response generation and
snapshot generation are separate clocks. Missing dates, percentages, credits
or lifetime residuals must not be converted into an invented today total.

## Current synthetic desktop matrix

From a fresh checkout:

```sh
python3 -B QA/WidgetHost/module_fixtures.py generate
zsh QA/WidgetHost/check.sh
```

The sole input template is tracked at
`QA/WidgetHost/Fixtures/reference-snapshot.json`; all values are invented.
The generator produces 35 cases / 140 family contracts under
`.build/widget-module-qa/fixtures/`, with explicit source-date and API-versus-legacy
expectations. `report.template.json` has **560 pending** case/family/light-dark/
focused-unfocused observations. Offline JSON, model and raster validation never
mark those observations passed. Preserve a separate results file when recording
actual observations.

Each completed desktop result needs the observed QA case ID, screenshot path,
time, family, actual appearance/focus evidence and checks for:

- Correct ordered identities and count, with no slot backfill or quota borrowing.
- Primary and secondary values, readable reset ownership and known plans.
- Long names/amounts, zero/unknown and independent quota/activity/cache statuses.
- No clipping or displaced rows; no hidden-inventory error leaking into Widget state.
- Clear source/query times and eligible dated history without invented missing-day zeros.
- Extra Large with exactly four visible modules in 2×2 keeps quota/current usage
  and omits seven-day statistics/trends. Other Extra Large counts retain available
  history; check these layouts separately.

The optional [private QA host](../QA/WidgetHost/README.md) reads only its synthetic
directory. Missing/invalid input is an explicit failure. Host build, application,
desktop registration and adding/removing the QA Widget are separate actions;
no production data, collector or updater is part of that harness.
