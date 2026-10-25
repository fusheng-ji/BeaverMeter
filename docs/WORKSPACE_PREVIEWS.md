# Widget previews and synthetic contracts

The current Widget uses user-selected ordered modules: one service or one Codex
workspace, including both available quota windows. Capacity is Small **2**,
Medium **4**, Large **6**, Extra Large **6**. None and duplicate slots are not
backfilled; additional source workspaces never expand a selection automatically.
There is no overflow navigation or `+N`.

## Canonical documentation images

Build the `BeaverMeterPreviewRenderer` target, then run the built executable:

```sh
BEAVERMETER_PREVIEW_RASTER_ONLY=1 "$preview_renderer_path" \
  --canonical "$PWD/screenshots" --time-zone UTC --logo standard --appearance both
```

Without a `--date` override, data and clocks are frozen at
`UsageSnapshot.previewDate`: **2026-09-22T12:00:00Z**. Every source value is
synthetic. This mode reads no account, credential or production setting files,
starts no collector, and creates no interactive window.

Canonical files are `brand-overview.png`,
`menu-monitoring-collapsed-{light,dark}.png`,
`widget-{small,medium,large,extra-large}.png` (dark), their `-light.png` variants,
and `widget-{large,extra-large}-six-modules[-light].png`.
The main four-family images explicitly order Personal, Plus, Claude and Cursor;
Large has four full-width rows and Small shows the first two modules. Extra
Large with those four visible modules places paired quotas beside the identity
and aligns current usage in a fixed footer, without seven-day statistics/trends.
Boundary images explicitly select six modules and retain
available Extra Large history. There are no extra four-row aliases in
the current README set.

These are offline SwiftUI references, not captured WidgetKit desktop results.
Native material/rendering-mode comparisons can be generated separately:

```sh
"$preview_renderer_path" --widget-appearances "$PWD/.build/widget-appearances"
"$preview_renderer_path" --service-matrix "$PWD/.build/service-combinations" --appearance both
"$preview_renderer_path" --workspace-matrix "$PWD/.build/workspace-previews" --appearance both
```

Service matrices cover 16 subsets, four families, menus and both appearances
(160 PNGs). Workspace matrices exercise identity and selection boundaries.
Gallery HTML, manifests and broad generated matrices belong in `.build`, rather
than the public screenshot set.

## Finished layout: day and night

The four completed sizes use the same ordered synthetic Personal, Plus, Claude
and Cursor selection. Small shows only the first two modules. Links open the
original PNGs.

| Size | Day / light | Night / dark |
| --- | --- | --- |
| Small · 2 modules | [PNG](../screenshots/widget-small-light.png) | [PNG](../screenshots/widget-small.png) |
| Medium · 4 modules | [PNG](../screenshots/widget-medium-light.png) | [PNG](../screenshots/widget-medium.png) |
| Large · 4 modules | [PNG](../screenshots/widget-large-light.png) | [PNG](../screenshots/widget-large.png) |
| Extra Large · 4 modules | [PNG](../screenshots/widget-extra-large-light.png) | [PNG](../screenshots/widget-extra-large.png) |

## Reproducible QA input from a fresh checkout

```sh
python3 -B QA/WidgetHost/module_fixtures.py generate
python3 -B QA/WidgetHost/module_fixtures.py verify
zsh QA/WidgetHost/check.sh
```

The tracked source is `QA/WidgetHost/Fixtures/reference-snapshot.json`;
`fixtures.py` contains only pure helper functions. No ignored template export is
required. Outputs are `.build/widget-module-qa/fixtures/manifest.json`, 35 cases,
140 family expectations, `offline-model-check.json` and an all-pending
`report.template.json`. Hash checks, JSON decoding, ordered composition,
remaining values/reset details, status, usage/history and fetched-label
presence are checked independently by Swift.

Codex fixtures use per-workspace `tokenActivity` with a matching synthetic
account hash, explicit API calendar dates, independent values and query times.
Legacy counters and global totals deliberately differ so accidental fallback
fails. Zero, missing fields, unavailable API, cached values and history gaps
have separate expectations. Injected values are model inputs, not proof that
real logs provide request-account attribution.

`creator_account_id` describes a thread creator. Real local/remote parsers do
not treat it as request-account usage; those records remain global. Legacy
snapshot compatibility is tested separately. The optional API fields preserve
schema-7 compatibility. The service calendar date is retained: a visible
`tokens today` caption is not a new proof of complete local-day coverage.
`Fetched` is the query time, not the source statistics cutoff.

## Information by size

| Size | Information |
| --- | --- |
| Small | Identity/plan, both available remaining values, primary reset. |
| Medium | The same modules plus principal-window reset details. |
| Large | Usage inside each module; 2–4 full-width rows, 5–6 in two columns. |
| Extra Large | Quota/current usage inside each module. Exactly four visible modules in 2×2 omit seven-day statistics/trends; other counts retain available history. |

Reset-card inventory/expiry, monthly used/limit and token breakdowns stay in
the menu. Hidden inventory failures do not change Widget quota state. Missing
selected workspaces stay unavailable instead of borrowing another account.

See [desktop acceptance](WIDGET_DESKTOP_ACCEPTANCE.md) for the remaining native
matrix and the distinction between contract checks, offline renders and desktop
evidence.
