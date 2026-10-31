# Antigravity native WidgetKit verification

This isolated workflow wraps the four reviewed `screenshots/antigravity/*.json`
schema-8 synthetic snapshots and adds one derived spacing-stress case. The four
original case bytes and SHA-256 hashes remain unchanged. It does not read or replace production snapshots,
provider settings, accounts, Widget selections or credentials. The legacy
35-case/560-observation matrix stays separate and pending.

## Prepare without desktop interaction

```sh
python3 -B QA/WidgetHost/antigravity_fixtures.py generate
python3 -B QA/WidgetHost/antigravity_fixtures.py verify
zsh QA/WidgetHost/build.sh --antigravity
```

The build uses only `.build/widget-desktop-qa` DerivedData and the private
`com.jiwenbo.beavermeter.widgetqa` / `.widget` bundle identities. It verifies the
signature, runs the executable's temporary-directory `--self-test`, and checks
five cases / 20 family compositions offline. It never opens the host window,
adds a Widget or applies a case. Standard macOS builds can register an app with
LaunchServices; this is separate from adding a desktop Widget.

Generated inputs and evidence templates:

- `.build/widget-antigravity-qa/fixtures/manifest.json`: five hashed, whitelisted cases.
- `.build/widget-antigravity-qa/fixtures/cases/antigravity-both-groups.json`: primary case.
- Other case IDs: `antigravity-full-capacity`, `antigravity-unknown-and-zero`,
  `antigravity-reset-description`, `antigravity-spacing-stress`.
- `.build/widget-antigravity-qa/report.template.json`: 40 pending case/family/theme
  observations. Copy this to a separate results file before recording evidence;
  generation never writes an observation as passed.

The primary case selects exactly `antigravity-group:gemini` and
`antigravity-group:claude-gpt` in slots 1–2, with other providers explicitly
hidden. Full capacity selects those groups first, then Codex Personal, Claude,
Cursor and DeepSeek; each family retains its existing 2/4/6/6 capacity.
The fifth case derives only from the full-capacity synthetic snapshot and uses
long workspace/reset text, 100%, distinct unknown and zero readings, a large USD
amount and CNY 9.9B. Its source preview is provenance, not evidence that this new
case has already been rendered or observed. No legacy matrix input is changed.

## Deliberate native desktop steps

Use the existing [controlled backend](CONTROL.md) with the Antigravity manifest:

```sh
python3 QA/WidgetHost/control_runner.py \
  --control .build/widget-desktop-qa/antigravity-control \
  --app '.build/widget-desktop-qa/Build/Products/Debug/BeaverMeter QA.app' \
  --manifest .build/widget-antigravity-qa/fixtures/manifest.json
```

Alternatively, after deliberately choosing to apply a synthetic case:

```sh
'.build/widget-desktop-qa/Build/Products/Debug/BeaverMeter QA.app/Contents/MacOS/BeaverMeter QA' \
  --apply .build/widget-antigravity-qa/fixtures/cases/antigravity-both-groups.json
```

The apply command writes only the QA directory
`~/Library/Application Support/BeaverMeter-WidgetQA/current-case.json` and asks
WidgetCenter to reload only `BeaverMeterWidgetQA`. It returns without opening a
window. A successful acknowledgment is not evidence that WidgetKit has already
displayed the case; confirm the visible/accessibility `QA caseID` first.

1. In macOS's desktop **Edit Widgets** gallery, deliberately add **BeaverMeter QA**,
   keeping existing production Widgets unchanged. The optional host window only
   displays case metadata; it is not a Widget preview or acceptance surface.
2. Observe the actual desktop Widget at Small, Medium, Large and Extra Large,
   using the gallery or the Widget's size context menu. Extra Large is supported
   on macOS 14+ (`WidgetFamily.systemExtraLarge`), and the private extension
   declares all four families. Record an unavailable host choice as blocked;
   do not substitute a resized app window.
3. For each size, record actual light and dark appearances. Also observe desktop
   focus and another app focused, retaining the existing system dimming policy.
   Record actual rendering mode/focus rather than inferring it from wallpaper.
   Restore any deliberately changed QA appearance after observation.
   The QA container's accessibility label/value retain `QA caseID` and expose
   the extension's actual `family`, `colorScheme` and `widgetRenderingMode`
   environment values. These describe the rendered Widget environment only;
   they do not measure which app or desktop has focus. Record focus from the
   separate observed UI interaction.
4. Check Gemini and Claude/GPT names, independent primary values/periods, reset
   ownership, the optional other window and status. Neither group may show Today,
   tokens, activity, fees or charts. Check clipping, baseline/alignment and both
   color and monochrome contrast. For full capacity, check ordered 2/4/6/6 slots.
5. In the unknown/zero case, Gemini remains unknown while Claude/GPT is truly 0%;
   no group may borrow its sibling's quota. In the reset-description case, retain
   the supplied prose without inventing a date. Check long prose in each size.
6. Each completed record needs case ID, actual family/theme/focus, timestamp,
   screenshot path and specific checks/limitations. Remove only the temporary QA
   Widgets after testing. Do not delete or rewrite production settings.

## Read-only native bounds evidence

The QA extension alone is compiled with `WIDGET_QA`. It exposes the actual card,
chosen fit branch, and text/logo/status accessibility elements; production
accessibility behavior is unchanged. Build the independent reader when needed:

```sh
xcrun swiftc -parse-as-library QA/WidgetHost/Tools/NativeWidgetBounds.swift \
  -o .build/widget-antigravity-qa/NativeWidgetBounds
.build/widget-antigravity-qa/NativeWidgetBounds --self-test
.build/widget-antigravity-qa/NativeWidgetBounds \
  --case antigravity-spacing-stress --family large --appearance dark \
  > .build/widget-antigravity-qa/spacing-stress-large-dark.bounds.json
```

The reader requests no permissions dialog and performs no UI or process action.
It only inspects NotificationCenter windows titled `BeaverMeter QA`, requires
the private `kind: BeaverMeterWidgetQA` and requested case/environment marker,
and matches actual AX window geometry to one onscreen CG window. Each leaf is
associated with its nearest `WidgetQA.card.<moduleID>` ancestor. The report
records window, card and leaf frames, node/parent IDs, safe rectangles, the
visible `WidgetQA.fit.*` choice and overflow in points/physical pixels. When
WidgetKit Remote flattens the fit wrapper, the reader requires one actual
visible logo carrying the selected variant's detail level. The report records
`chosenDetailLevelSource` as `fit-group` or `visible-logo`; absence or ambiguity
cannot pass. Its
one-physical-pixel tolerance comes from that display's actual backing scale.
Missing bounds, private markers, text/logo leaves or a unique fit choice cannot
pass. Normal cards intentionally omit the status icon; when present, its actual
frame is checked with the same tolerance. `--window-id` can disambiguate a
particular QA window.

The measurements are AX layout frames, not glyph ink bounds. Read the captured
Widget screenshot alongside this report to check clipping and visual alignment.
Padding metadata alone is not evidence of actual containment. The reader exits
2 for a blocked or failed observation and emits a JSON explanation; a matching
visible private QA window is required for a pass. Its pure `--self-test` does
not access Accessibility or the desktop.

## Evidence boundaries

`screenshots/antigravity/manifest.json` explicitly says `previewOnly: true`.
The renderer uses ImageRenderer and an offscreen NSHostingView cache for dark
materials; the word "native" in its batch name describes AppKit rasterization.
It does not host a WidgetKit extension, capture desktop compositing, verify focus
transitions or prove timeline updates. The isolated QA extension is a real
WidgetKit `StaticConfiguration` using current `QuotaWidgetContent`, frozen time
and synthetic data. It validates desktop appearance, while production
AppIntent selection, live expiry refresh, registration and actual account reads
require their separately recorded production checks.

Apple references:
[Extra Large availability](https://developer.apple.com/documentation/widgetkit/widgetfamily/systemextralarge),
[desktop Widget controls](https://support.apple.com/guide/mac-help/add-and-customize-widgets-mchl52be5da5/mac).

## Recorded native run

The [2026-10-31 native record](../../docs/ANTIGRAVITY_WIDGET_DESKTOP_VALIDATION.md)
contains the earlier 32 qualified observations and two Large unfocused comparisons.
The later [spacing validation](../../docs/WIDGET_SPACING_VALIDATION.md) reruns
all 32, adds eight spacing-stress observations, and records 120 actual card /
724 text, logo and status leaf bounds. All 40 and two additional unfocused
comparisons passed their separately recorded visual review.
capture/report templates above remain pending by design; generation never
copies a previous run's pass state. Actual family and geometry must both match,
and transient resize/appearance states must settle before screenshots qualify.
