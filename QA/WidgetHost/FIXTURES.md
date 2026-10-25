# Synthetic module fixtures

The sole template is the checked-in `Fixtures/reference-snapshot.json`.
It is an invented schema-7 snapshot; no credentials, production snapshots,
account homes or ignored build exports are read. Dates are fixed at
`2026-09-22T12:00:00Z`; the synthetic account API series preserves its explicit
service-date labels and query time.

```sh
python3 -B QA/WidgetHost/module_fixtures.py generate
python3 -B QA/WidgetHost/module_fixtures.py verify
python3 -B QA/WidgetHost/module_fixtures.py list
zsh QA/WidgetHost/check.sh
```

Current output is `.build/widget-module-qa/fixtures/`. Cases contain required
`caseID`, `snapshot`, `settings`, `referenceDate` and optional
`selectedModuleIDs`. Omission selects balanced defaults; `[]` is explicitly
empty; `none` keeps an empty slot. Limits are 2/4/6/6.

The 35 cases cover every service subset, ordered 0–6 module selections,
source-account growth/reordering, missing and legacy IDs, slot gaps, duplicate
and long labels, long money values, true zero, unknown, cached and sign-out
states. Quota and usage statuses are independent. Valid API activity takes
precedence over deliberately different legacy account counters. Missing legacy
fields and unavailable API readings never borrow global usage. API history
retains source calendar dates and gaps; no service time zone is invented.

The manifest records ordered module IDs, capacities, values, reset times,
plans, activity/history and each contract SHA256. Swift checks use the same
composition and presentation models as the Widget. All 560 desktop
case/family/theme/focus observations remain pending until actual host evidence
is recorded. Generation replaces only the report template, not completed
results.

The older `.build/widget-desktop-qa/fixtures/` overflow matrix is historical
and cannot certify the current module design. Current case switching must use
the module manifest; see [CONTROL.md](CONTROL.md).
