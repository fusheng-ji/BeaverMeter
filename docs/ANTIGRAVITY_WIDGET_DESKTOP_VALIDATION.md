# Antigravity desktop Widget validation — 2026-10-31

Completed on macOS **27.2**, with observation times recorded in **Europe/Berlin**.
The private `BeaverMeterWidgetQA` extension ran in the actual desktop WidgetKit
host, using the production shared composition and card views with isolated,
frozen synthetic data. These are desktop captures, not ImageRenderer previews;
their example percentages are not the user's account readings.

[Native screenshot gallery](../screenshots/antigravity-native/2026-10-31/index.html)
and [machine-readable evidence](../screenshots/antigravity-native/2026-10-31/report.json)
contain the final observations, window captures, desktop-region captures and
accessibility metadata.

## Completed observations

| Family | Native window size | Light | Dark |
| --- | --- | --- | --- |
| Small | 180 × 180 pt | Passed | Passed |
| Medium | 360 × 180 pt | Passed | Passed |
| Large | 360 × 360 pt | Passed | Passed |
| Extra Large | 720 × 360 pt | Passed | Passed |

Each cell covers four cases: both Antigravity groups, full module capacity,
unknown versus zero, and reset prose without a timestamp. All **32 observations**
passed visual review and actual family/theme/rendering-mode checks. The window
bounds had to stabilize and match the selected family; PNG dimensions also had
to match the observed 2× display scale. A menu click alone did not qualify.

- Gemini and Claude/GPT retain separate names, primary limits and resets.
  The primary fixture deliberately uses 62%/83% versus 47%/65%.
- The unknown Gemini fixture keeps “—” and its warning, while Claude/GPT
  independently shows a genuine 0% weekly limit and a 100% session limit.
- Antigravity contains no Today, token breakdown, activity, fees or charts.
  The full-capacity fixture retains the existing ordered 2/4/6/6 slots.
- Long reset prose stays within its column. Its complete original text remains
  in accessibility/help; no date or countdown is invented. Medium can omit the
  optional secondary window when the complete stack does not fit vertically.
- Logos, primary values, captions and card boundaries were visually readable in
  both appearances. This is a visual assessment, not a measured contrast ratio.

## Issues found and corrected

**Extra Large placement:** two quota-only Antigravity tiles previously pinned
their content to the top, leaving most of each card empty. With up to three
modules, these tiles now vertically center their existing content. Other cards,
counts, font sizes and data budgets retain their existing behavior.

**Reset-prose containment:** a fixed-width reset caption could extend outside a
Small card or overlap the adjacent Large metric. The fallback text now respects
its column and uses an ellipsis when necessary. Medium Antigravity columns also
try their complete stack before dropping the optional secondary window, keeping
the main allowance and reset readable instead of clipping the bottom row.

The original reproductions remain locally under `before-centering/` and are
excluded from the source release; the final qualified evidence is tracked.
Two initial Small/light attempts captured transitional larger-window geometry;
they are excluded from acceptance. Only the final qualified records count.

## Focus and system rendering mode

Two additional Large observations moved focus to the separate QA application,
positioned outside the Widget's bounds. Under both light and dark system
appearance, the actual Widget environment reported **dark / accented** when
unfocused. Values, names and resets remained readable in the captured window
and desktop region. Full color is not claimed while the system applies this
reduced-color mode. The existing system Widget-style preference was not changed.

These two observations supplement the 32 desktop-focused, `fullColor` cases.
They do not establish every family under every system rendering preference.

## Tests, installation and restoration

- The final source passed **272 app/Widget Swift tests**, including the existing
  surface and layout checks. The earlier full 600-test result remains recorded
  separately; collector logic was not changed by these appearance fixes.
- The isolated QA build, signature/self-test, five Python checks and 16 family
  composition checks passed. The 40 Antigravity and 320 service-combination
  offline images were regenerated; the four source fixture hashes were retained.
- The update was installed at `~/Applications/BeaverMeter.app`. Deep strict
  signature verification passed, installed App/helper/Widget executable hashes
  match the tested build, and PlugInKit lists one current production Widget.
- Launchd's installed refresh completed with exit code 0 and its 300-second
  interval remains registered. Real Claude quota, Antigravity quota and local
  Antigravity usage remain ready with no error messages.
- The temporary QA desktop card was removed and the QA host exited. The original
  light appearance, automatic-appearance option and recorded application
  visibility were restored. The production Widget retained its original
  position and size; production selections were not targeted. Account and
  configuration preservation hashes match their pre-install baseline.

The Google quota page itself, production AppIntent selection flows, other macOS
versions and the separate legacy 560-observation matrix remain outside this
specific native appearance acceptance.
