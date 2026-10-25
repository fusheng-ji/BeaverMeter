# Isolated Widget QA host

This developer harness uses private IDs `com.jiwenbo.beavermeter.widgetqa`
and `.widget`, Widget kind `BeaverMeterWidgetQA`, and synthetic storage at
`~/Library/Application Support/BeaverMeter-WidgetQA/current-case.json`.
It contains no collector, login, updater or production snapshot loader.
Missing or invalid input is an explicit QA failure, never a production fallback.

## Offline contract checks

From a fresh checkout, no previous `.build` export is required:

```sh
python3 -B QA/WidgetHost/module_fixtures.py generate
python3 -B QA/WidgetHost/module_fixtures.py verify
zsh QA/WidgetHost/check.sh
```

The checked-in `Fixtures/reference-snapshot.json` contains only invented counts,
`example.test` identities and the frozen date `2026-09-22T12:00:00Z`.
`fixtures.py` provides pure builders; `module_fixtures.py` is the current CLI.
The former 4/6/8/12 overflow generator is retired.

Outputs: `.build/widget-module-qa/fixtures/manifest.json`, 35 case JSON files,
`offline-model-check.json`, and an all-pending `report.template.json`.
The Swift checker validates 140 family compositions, account API activity and
history, legacy/missing-state isolation, fetched-label presence and slot order.
Offline success never marks any desktop observation passed.

## Build the optional desktop harness

```sh
zsh QA/WidgetHost/build.sh
```

This builds `.build/widget-desktop-qa/Build/Products/Debug/BeaverMeter QA.app`,
runs a temporary-directory self-test and performs the offline checks above.
Standard macOS app builds can register this private identity with LaunchServices;
they do not launch the host or add a desktop Widget. Actual desktop installation,
case application and cleanup are separate, deliberate QA actions.

Each module is one service or one Codex workspace. Small takes slots 1–2,
Medium 1–4 and Large/Extra Large 1–6. Truncation precedes None, duplicate,
hidden or invalid-slot filtering. No later slot backfills and no workspace
expansion or `+N` occurs. Removed workspaces retain their unavailable slot.
Large and Extra Large keep activity inside each selected module. Extra Large
with exactly four visible modules in 2×2 omits seven-day statistics/trends, retaining
quota/current usage; other counts retain available history. The underlying history
model contract remains independent of this display budget. Every Codex workspace
uses its own `tokenActivity`,
without borrowing another workspace or global totals. Deliberately different
legacy/global counts expose accidental fallback; zero, missing, stale and
unauthenticated readings remain distinct.

See [fixture contract](FIXTURES.md), [controlled case switching](CONTROL.md),
[preview guide](../../docs/WORKSPACE_PREVIEWS.md) and
[desktop evidence requirements](../../docs/WIDGET_DESKTOP_ACCEPTANCE.md).
