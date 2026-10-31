# Release validation

## 1.0.2 / build 39 preparation — 2026-10-31

App and Widget source metadata advance together to **1.0.2 / build 39**.
This is preparation for a small release; the latest published version remains
1.0.1 until the official publication gates complete. No new immutable release
tag, production appcast or public binary is produced by this source preparation.

- Final local Release/arm64 regression passes **608 Swift tests**: 280 App/Widget
  and 328 collector. The 45 Python tests, six packaging tests, seven isolated
  Antigravity fixture checks and nine native-geometry summarizer tests pass.
- Shell syntax, migration, installation/rollback, prebuilt runtime setup and
  update preparation/recovery pass. Fresh-helper collection/authentication,
  workspace isolation, runtime locks and navigation checks all pass against the
  freshly built helper. Claude authentication covers six isolated cases;
  Antigravity covers full/local/hidden/error/cache and snapshot preservation.
- [Widget spacing acceptance](WIDGET_SPACING_VALIDATION.md) records **40 actual
  desktop observations**, two unfocused comparisons, 120 cards and 724 measured
  text/logo/status leaves. Separate visual review passed; no measured leaf
  overflow was observed. Offline matrices contain 40 Antigravity, 320 service
  combination and eight long-content stress images.
- Source cleanup removes a duplicate QA metadata wrapper, keeps native probes
  isolated behind `WIDGET_QA`, and excludes transitional diagnostic captures and
  generated Python caches. Snapshot decoding now lives in the shared model, so
  isolated QA uses the same legacy defaults as production. Final synthetic
  evidence and reproducible inputs stay
  in the source tree. Existing account/configuration and installed Widget choices
  are preserved.
- The preceding local installation and native checks below used 1.0.1/build 38
  metadata. They establish observed functionality, not a public 1.0.2 Universal
  package, Intel execution or production updater acceptance.

## Pre-release implementation: Claude plan rules and Antigravity — 2026-10-31

This local source update was installed in `~/Applications/BeaverMeter.app` while
retaining the existing 1.0.1/build 38 metadata. No public release, tag or updater
feed was published. The prior release history below remains unchanged.

### Automated and offline verification

- The final Release/arm64 build passed **600 Swift tests (272 app + 328
  collector)**. Coverage includes old/new Claude names, actual Ultra windows,
  weekly-only responses, replacement of obsolete session windows, existing
  authentication/renewal/cache behavior, independent Antigravity pools,
  unknown/disabled/zero values, legacy model responses, cache/reset expiry,
  Berlin midnight/DST, private SQLite snapshots, cancellation and process cleanup.
- All fresh-helper integrations passed: collector fixtures, six isolated Claude
  authentication cases, Antigravity full/local/hidden/cache/error preservation,
  genuine cross-process snapshot locks, workspace token/account API isolation,
  and App/Widget navigation schemes plus all five bundled provider logos.
- The 45 Python tests and shell syntax, migration, installer/rollback,
  prebuilt-runtime and update-runtime fixture checks also passed during this
  implementation. Installer schema validation now expects 8 and explicitly
  rejects/rolls back a helper producing the old schema.
- Offline SwiftUI rendering produced **40 Antigravity PNGs** with four synthetic
  snapshots and a manifest, plus **320 service-matrix PNGs** for all 32 service
  combinations (31 nonempty), four Widget sizes, menus and both appearances.
  Gemini/Claude-GPT independence, full slots, unknown versus zero, reset prose
  and long values are covered. The official press SVG supplies the original-color
  and white-mask assets. These references do not establish desktop-host behavior.

### Observed local installation and background results

- The installed collector's noninteractive `--claude-verify` completed successfully
  at **15:10:45Z**: ready/accountAPI, **Claude Ultra**, all-model weekly and Fable
  weekly windows, no 5h window and no login/error message. No new Claude login or
  authorization was requested. Future renewal is covered by regression cases,
  rather than inferred from this one current-account observation.
- With **Antigravity App fully closed**, the installed build returned ready local
  quotas at **15:08:25Z**, followed by another fresh reading at **15:09:13Z**.
  Both independent pools agree with the earlier successful App-local reading.
  Private account amounts are omitted from this public validation record. These are
  actual quota data, not offline conversation counts or token-derived estimates.
- Installed Today collection returned fresh totals and request counts,
  ready/codexBarLocal with an empty error message; private values are omitted.
  The bounded private view adapts
  cold WAL files and the positively identified unkeyed ERROR_MESSAGE step only;
  original Antigravity App DB/WAL hashes remained unchanged. Local activity is
  explicitly separate from account quota.
- Official `agy` **1.4.12** was installed in the user directory after checking its
  official package SHA-512. PATH, aliases and shell profiles were preserved; the
  user completed first-run setup. The current CLI requires local CSRF, so the
  CLI stage adapts the pinned public App -> CLI -> IDE pipeline with a per-run
  nonce and exact owned PID/IPv4-loopback endpoint. App/IDE retain the dependency's
  transport handling; the CLI uses its own official HTTP listener without any
  global certificate override, redirects, proxies, cookies or Google credential
  extraction. Handshake failures remain retryable instead of requesting login.
- A real SIGTERM test against the **installed** collector cancelled an in-flight
  owned CLI in **0.294 seconds**. The CLI exited, the previous snapshot was
  byte-for-byte preserved and no private log-scope directory remained. The test
  signalled only its own helper; fixture tests additionally preserve an unrelated
  process and stop descendants after their root exits. No `agy` process remained
  after the successful reads or cancellation.
- `codesign --verify --deep --strict` passed. Installed App, helper and Widget
  executable hashes match the tested build. PlugInKit lists one current Widget at
  the installed path. Launchd runs the installed script every **300 seconds** and
  completed its next **naturally scheduled** refresh at **15:14:36Z** with ready
  quota/local readings, no error message and no remaining CLI. Its run count
  advanced to **2**, with exit code **0**, while Antigravity App stayed closed.
  Account, workspace,
  configuration and shell-profile preservation hashes all match the baseline.

### Native desktop appearance follow-up

The [dedicated native record](ANTIGRAVITY_WIDGET_DESKTOP_VALIDATION.md) now passes
**32 Antigravity desktop observations** across four sizes, two appearances and
four synthetic cases, plus two Large unfocused comparisons on macOS 27.2.
Actual WidgetKit environment metadata, stable native geometry, window/desktop
captures and visual review qualify each result. Following CUA window-selection
and timeout failures, the user explicitly authorized system scripts and capture.

This follow-up corrected top-heavy Extra Large quota tiles and long reset-prose
overflow/clipping. The final source passed 272 app/Widget tests and was installed;
signatures, production registration, ready live readings and configuration
preservation were checked again. Temporary QA cards, appearance and application
visibility were restored. The current Google quota page, production AppIntent
selection flows and legacy full matrix remain separate scopes. This local arm64
result does not establish Intel hardware or signed public-distribution acceptance.

## 1.0.1 / build 38 — 2026-10-28

The patch repairs Cursor encrypted sign-in and silent background refresh. App and
Widget versions/builds advance together; official identities, feed and EdDSA
public key are unchanged.

- Focused coverage exercises encrypted/legacy token decoding, exact Keychain item
  selection, explicit authorization/cancellation, private cache permissions and
  source binding, expiry, verified-only persistence, authentication rejection and
  transient HTTP failures. Cache placement stays in private application storage
  even when the snapshot output is redirected.
- Live verification on the affected local installation recovered both Cursor
  dashboard readings. A passive five-minute observation and the next natural
  launchd completion showed fresh ready readings without a manual refresh or an
  authorization request. This establishes the observed cycle, not indefinite
  behavior after a future Cursor login or macOS change.
- Local full regression passed **509 Swift tests (253 app + 256 collector)**,
  **45 Python tests**, **6 Node packaging tests** and all shell, runtime-lock,
  workspace-token and account API integrations.
- The **1.0.1/build 38** Universal app and mounted DMG passed validation of all
  **8 signed executable files**, arm64/x86_64 slices, matching App/Widget metadata,
  official identities, production updater settings and runtime/Sparkle resources.
- [GitHub release validation](https://github.com/fusheng-ji/BeaverMeter/actions/runs/40672386372)
  passed on both macOS 15 Apple Silicon and Intel runners: **509 Swift tests per
  architecture**, all **45 Python tests**, and the complete shell/CLI integrations.
  The Intel virtual GPU required `RB_USE_BINARY_ARCHIVE=0`, forwarded to XCTest
  with `TEST_RUNNER_`; all **7 WidgetSurface pixel tests** then passed. No tests or
  Metal error checks were disabled. This setting applies only to the CI process.
- The publishing job downloaded the actual five draft assets, verified hashes and
  EdDSA signatures, mounted/validated the Universal DMG, and compared source ZIP
  contents and file types against the immutable tag. Stable
  [v1.0.1](https://github.com/fusheng-ji/BeaverMeter/releases/tag/v1.0.1) was published
  from source commit `f8d30bc4327c344c58b421cbd12e1c996d7c8e90`. The public `latest`
  appcast was downloaded again and matched the signed local bytes exactly.
- Physical Intel/macOS 14, clean quarantined installation, public
  upgrade/recovery and the complete native Widget matrix remain outside this
  patch's observed validation. Earlier candidate limitations are retained below.

## Previous 1.0.0 candidate — 2026-10-25

- App and Widget are **1.0.0 / build 37**. Existing official identifiers, update
  feed and public key are retained. The internal build floor is **37**;
  validation rejects build 36 or lower even when old release tags are absent.
  No tag or public 1.0.0 Release is created here.
- Baseline regression passed **474 Swift tests (247 app + 227 collector)** and the
  installation/runtime, account API, workspace and genuine record-lock CLI
  integrations. Final Python discovery passed **39 tests**. The packaging
  device-ownership adapter passed **6 Node tests**.
- Offline QA passes **35 synthetic cases / 140 size contracts** from the
  repository-owned fixture, without a prior `.build` template. Seventeen
  canonical demo images cover the menu, update button, four Widget families,
  Large four-row layout and six-module boundaries.
- The Extra Large four-module refinement passed **12 layout-budget tests** and
  all **35 synthetic cases / 140 size contracts**, including visible-count changes
  after empty slots are filtered. Its light/dark SwiftUI references omit seven-day
  charts and labels while keeping allowances, resets and current activity. Paired
  quotas sit beside the identity, with a fixed activity footer across all four
  cards. Long-value, zero/unknown and stale/login fixtures were also rendered. The
  six-module reference retains its trends. The Widget, preview tool and Universal
  candidate compile; these reference checks do not establish desktop-host results.
- The signed Universal candidate passed validation of **8 executable files**,
  arm64/x86_64 slices, runtime/Sparkle resources, matching App/Widget identities,
  the fixed public key, disabled production updates and no demo flags. The final
  APFS/ULFO DMG passes checksum/mount/content/signature checks and contains the
  Applications drag-install link. No local installed app was replaced.
- Isolated real Sparkle integration passed **5.5.0/36 → 1.0.0/37**: wrong feed
  signature, HTTP failure, download cancellation and corrupt archive reject
  safely; the valid signed archive replaces App/Widget/collector and relaunches.
  The test uses temporary copies, an ephemeral signing key and loopback feed;
  it neither reads the production private key nor validates the public feed or
  the production menu-to-installer chain. Ordinary test children cannot inherit
  release-signing material.
- The menu-bar update dot/version button, startup check preference/idempotence,
  busy/error/retry handling and indicator clearing are covered by tests. Only
  eligible production builds use the production updater; candidates remain off.
- Existing macOS 14, Intel hardware, clean quarantined installation and public
  upgrade/runtime recovery validation remain required before public distribution.
  The complete **560-observation native Widget matrix** remains pending. Earlier
  runtime profiling left a 493 ms awake interval unattributed; no hitch-free or
  memory-leak acceptance is claimed for this candidate.

Candidate bytes, checksums and the final source commit are recorded alongside
the local package in `.build/release-candidate/1.0.0/`.
