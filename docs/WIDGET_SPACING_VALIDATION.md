# Widget spacing validation — 2026-10-31

**Completed and installed locally.** The new spacing evidence uses the private
`BeaverMeterWidgetQA` desktop WidgetKit extension and frozen synthetic data.
The [native gallery](../screenshots/widget-spacing-native/2026-10-31/index.html)
links each actual-window image, surrounding desktop image, AX tree and measured
bounds report. All **40 observations** passed geometry checks and separate visual
inspection, with two additional unfocused comparisons. The
[acceptance report](../screenshots/widget-spacing-native/2026-10-31/report.json)
keeps installation, restoration and visual acceptance separate from the
geometry-only summarizer.

## Fixed spacing and content fitting

The spacing policy depends on the actual visible card count and Widget family.
Content pressure reduces optional detail before altering these insets. All
numbers below are logical points.

| Family | Outer padding | Card gap | Horizontal card inset | Vertical card inset |
| --- | ---: | ---: | --- | --- |
| Small | 10 | 4 | One card: 12; two: 8 | One card: 10; two: 8 |
| Medium | 12 | 6 | One card: 12; two–three: 10; four: 8 | One–three: 10; four: 8 |
| Large | 16 | 8 | One card: 16; two–three: 12; four–six: 10 | One card: 12; two–three: 10; four–six: 8 |
| Extra Large | 16 | 8 | One card: 16; two–six: 12 | One card: 14; two–four: 12; five–six: 10 |

Capacity remains **2 / 4 / 6 / 6**. Detail fitting tries the complete card, then
removes activity detail, activity, secondary-window reset text, subscription
text and the secondary window. Main quota/balance, identity, period and relevant
status remain. Money retains its currency; narrow layouts can put the currency
on a separate line while keeping the complete amount in accessibility/help.

## Evidence and current status

| Check | Status and scope |
| --- | --- |
| App/Widget regression | Final 280 tests passed, reported at 19:24:28 on 2026-10-31 |
| Offline previews | 40 Antigravity, 320 service-combination and 8 spacing-stress images generated; offline rasterization only |
| Isolated QA build | Build, signature and host self-test passed; private identity only |
| Fixture contracts | Five cases / 20 family compositions and seven Python checks passed; original four case SHA-256 values unchanged |
| Native bounds reader | 24 pure self-tests passed; actual native geometry is recorded separately per observation |
| Native geometry matrix | All 40 passed: **120 cards, 724 leaves** (596 text, 120 logos, eight status icons); maximum measured overflow **0 physical pixels** |
| Native visual review | All 40 passed; see the separate [visual review](../screenshots/widget-spacing-native/2026-10-31/visual-review.json) and five original-proportion contact sheets in the gallery |
| Unfocused reduced-color comparison | Two Large comparisons passed under light/dark system appearance; actual Widget environment reported dark/accented |
| Final installed production verification | Signature, matching installed executables, one production Widget registration and 300-second LaunchAgent verified; latest refresh exited 0 |

The five cases are both Antigravity groups, full capacity, unknown versus zero,
reset prose, and a derived spacing-stress case. The fifth combines long
workspace/reset text, 100%, unknown and zero readings, large USD and CNY 9.9B
amounts. It adds eight native observations. The original primary case, all four
original fixture hashes, and the separate legacy 560-observation matrix remain
unchanged.

## What the measured checks establish

`NativeWidgetBounds` reads only actual onscreen NotificationCenter windows
titled `BeaverMeter QA`, with private kind, case and actual family/theme/render
mode markers. It matches the AX and CG window frames, reads card and visible
text/logo/status leaf frames, and preserves AX node/parent identities. The
selected fitting variant is evidenced by a fit group or its actual visible logo
when WidgetKit Remote flattens the wrapper. Metadata can be carried by
AXDescription; AXValue overrides matching keys when present.

The offline summarizer independently recomputes leaf containment, expected
module order/capacity, fixed card insets, nearest-card ancestry, adjacent card
gaps and screenshot dimensions at the measured display scale. Every leaf must
stay inside its actual card's safe rectangle within **one physical pixel**.
The native matrix requires actual `fullColor`, light/dark and desktop focus;
the system's unfocused rendering mode is recorded in two additional comparisons.

All 120 cards exposed the chosen variant through their actual visible logo.
The selected levels were full (82), primary-only (22), without activity (eight)
and without subscription (eight). Actual adjacent card gaps matched the fixed
policy within the one-pixel tolerance. Native window geometry stabilized at
180×180, 360×180, 360×360 and 720×360 pt; these CG frames include system shadow.

AX frames describe layout rectangles, not glyph ink. The CG window includes a
system shadow, so its measured margins to the union of cards do not establish
the visible Widget's outer padding. The report records those margins without
subtracting a hardcoded shadow. Outer-edge appearance, clipping, readability,
alignment, density and color were inspected separately in the linked images.
Main values remained readable, optional information yielded in dense cards,
and long names/reset prose used permitted ellipses. The Large CNY stress card
displayed `9.9B` with an adjacent `CNY` line; Extra Large retained `CN¥9.9B`.
These are synthetic examples, not the user's account values.

## Installation and restoration

The final version is installed at `~/Applications/BeaverMeter.app`. Deep strict
signature verification passed. The installed App, collector and Widget
executable hashes match the final build. PlugInKit lists one production Widget
at the installed path; launchd retains its installed refresh script and
300-second interval, with last exit code 0. All five services' latest quota or
balance readings are ready without errors; Antigravity local usage is also ready.

All nine account/configuration preservation checks match the pre-install
baseline. The temporary QA desktop card was removed and its host exited.
Original application visibility, the original Claude foreground application,
light appearance and automatic-appearance preference were restored. The
production Widget retains x=784, y=41, 360×360 pt, and its selections were not
targeted. No new setting, snapshot field or collection request was added for
spacing.

## Reproduce the offline summary

```sh
python3 -B QA/WidgetHost/Tools/summarize_spacing_native.py --self-test
python3 -B QA/WidgetHost/Tools/summarize_spacing_native.py --require-complete
```

The script reads existing captures and bounds JSON, then writes only
`spacing-summary.json` and `index.html` alongside them. It does not change
capture statuses, operate the desktop, install an application or infer a visual
pass. Its `--require-complete` result concerns the 40 geometry observations;
visual review is not evaluated by this helper. The separate acceptance report
above records the completed inspection; regenerating geometry evidence never
invents a visual pass. Other macOS versions and the legacy 560-observation
matrix remain outside this run.

Five `contact-sheet-antigravity-*.png` files in the capture directory combine
the existing window images by case, four sizes × light/dark. They were generated
offline with `QA/WidgetHost/Tools/NativeSpacingContactSheet.swift` using AppKit;
no Widget or application window was opened. The gallery links these sheets as
review aids. Original window and desktop images remain the detailed evidence.
