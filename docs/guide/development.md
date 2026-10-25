# Development

[简体中文](development.zh-CN.md) · [README](../../README.md)

## Build metadata

The current baseline is **1.0.0, build 37**. App and Widget metadata must match.
A source commit or local package does not publish an official tag, DMG or appcast.

The app uses SwiftUI, the desktop extension uses WidgetKit, and the collector
keeps provider reads independent. Shared model code supports app/Widget/collector
without a running CodexBar application. Dependencies are pinned in `project.yml`.

## Build and install

Requirements: macOS 14+, full Xcode, Homebrew and XcodeGen. The source installer
is for development; prebuilt official DMGs do not require these tools.

```sh
git clone https://github.com/fusheng-ji/BeaverMeter.git
cd BeaverMeter
brew install xcodegen
./scripts/install.sh
```

The installer builds before stopping the previous installation, asks for a team
ID/bundle prefix and local/optional remote sources, and installs to
`~/Applications/BeaverMeter.app`. It configures background refresh. Replacement
validation has rollback copies of the affected app/agent/data. Preserve existing
configuration and custom work before changing an installation.

A source build’s updater is disabled. The official app and a custom development
identity are different installations; switching identities can require removing
and re-adding the desktop Widget. Do not publish a custom identity as official.

### Optional source configuration

Fresh installs leave SSH off. Configure an SSH alias, an absolute remote Codex
home and an absolute remote Python executable to enable it. Upgrades preserve
existing enable/disable state and interval. Private `config.env` keys include:

```text
CODEX_REMOTE_SSH_HOST
CODEX_REMOTE_ROOT
CODEX_REMOTE_PYTHON
CLAUDE_CONFIG_DIR
CLAUDE_SECURESTORAGE_CONFIG_DIR
CLAUDE_CLI_PATH
CLAUDE_CLI_REFRESH
CLAUDE_KEYCHAIN_ACCESS
```

The normal background interval defaults to five minutes. Local Codex/Claude
activity polling is a separate 45-second path. Do not reduce safety timeouts,
merge account scopes or enable live requests merely to accelerate tests.

## Tests

Run the complete local check:

```sh
./scripts/test.sh
```

For individual Swift test runs:

```sh
xcodegen generate
xcodebuild -project BeaverMeter.xcodeproj \
  -scheme BeaverMeter -derivedDataPath /tmp/beavermeter-derived test
```

The existing network-free fixture/migration checks can be run separately:

```sh
./Tests/collector_test.sh \
  /tmp/beavermeter-derived/Build/Products/Debug/BeaverMeterCollector
./Tests/migration_test.sh
```

Additional isolated API and real POSIX-lock tests are in
[workspace_token_api_test.py](../../Tests/workspace_token_api_test.py) and
[runtime_lock_test.py](../../Tests/runtime_lock_test.py). Read their arguments
before running; use fixture directories and test outputs, not production files.

Supported fixture controls include:

```text
CODEX_TOKEN_FIXTURE             CODEX_USAGE_FIXTURE
CODEX_HISTORY_FIXTURE           CODEX_RESET_CARDS_FIXTURE
CODEX_WORKSPACE_TOKENS_FIXTURE   CODEX_REMOTE_RESPONSE_FIXTURE
CLAUDE_TOKEN_FIXTURE            CLAUDE_USAGE_FIXTURE
CLAUDE_HISTORY_FIXTURE          CLAUDE_RESET_CARDS_FIXTURE
CURSOR_EVENTS_FIXTURE           CURSOR_SUMMARY_FIXTURE
DEEPSEEK_USAGE_FIXTURE          DEEPSEEK_SUMMARY_FIXTURE
CURSOR_STATE_DB                 CODEX_TOKEN_CACHE_ROOT
CLAUDE_TOKEN_CACHE_ROOT         CLAUDE_CONFIG_DIR
```

Fixtures exercise schema compatibility, source/account isolation, zero/unknown,
partial scans and corrections, cross-host deduplication, authentication expiry,
Keychain cancellation, bounded caches, async read ordering, module limits and
installer rollback. Synthetic inputs are not proof that real logs establish
request-account billing. Keep scope and date semantics in regression tests.

## Synthetic previews

Build the renderer, then use a separate output directory:

```sh
xcodegen generate
xcodebuild -project BeaverMeter.xcodeproj \
  -scheme BeaverMeterPreviewRenderer \
  -derivedDataPath /tmp/beavermeter-preview-derived build
preview_renderer=/tmp/beavermeter-preview-derived/Build/Products/Debug/BeaverMeterPreviewRenderer
"$preview_renderer" --check-assets
BEAVERMETER_PREVIEW_RASTER_ONLY=1 "$preview_renderer" \
  --canonical .build/canonical-review --time-zone UTC --logo standard \
  --appearance both --update-version 1.0.1 --check-assets
"$preview_renderer" --interactive-demo \
  --time-zone UTC --logo standard --appearance light
```

The canonical command keeps the default frozen reference instant; do not add
`--date` when reproducing that set. A supplied `--date YYYY-MM-DD` instead picks
midnight in the selected time zone. Appearance accepts `light`, `dark` or `both`.
`--update-version 1.0.1` produces extra synthetic update-available UI; it does not
check a feed or announce a published version. Screenshot/demo modes use synthetic
data, not installed settings, snapshots or sessions.
The interactive demo keeps changes in memory. Review the canonical Small/Medium/
Large/Extra Large identities, `tokens today`, fetch clocks and history visibility
before replacing repository images. Extra Large with exactly four visible modules
in 2×2 omits seven-day statistics/trends while retaining quota/current usage; other
counts retain available history. Never substitute real accounts for fixtures.

Matrices are development outputs, not the README’s screenshot contract:

```sh
"$preview_renderer" --service-matrix .build/service-matrix --appearance both
"$preview_renderer" --workspace-matrix .build/workspace-matrix --appearance both
```

[Preview notes](../WORKSPACE_PREVIEWS.md) describe the current contract and
[QA/WidgetHost](../../QA/WidgetHost/README.md) describes isolated host/fixture tools.
Selection is always 2/4/6/6; service availability is not a promise that all choices
fit. Generated matrices belong in `.build`, not the canonical public screenshot set.
Offline rendering does not pass real desktop theme/focus/boundary observations.

`--interactive /path/to/snapshot.json` is an advanced supplied-snapshot mode.
Automatic polling is disabled, but explicit Refresh/sign-in actions can collect
or authenticate into the supplied environment when the helper is available.
Use only an authorized test environment; this is different from the synthetic demo.

## Artwork

Original brand masters and provider assets remain in `Design/`. The
[brand source notes](../../Design/Logo/README.md),
[approved artwork](../../Design/Logo/a1-layout-refinement-2026-10-09/README.md) and
[provider sources](../../Design/ProviderSources/README.md) document their origin.
To regenerate derived brand/icon assets after an intentional artwork change:

```sh
swift -module-cache-path /tmp/beavermeter-brand-cache scripts/make_brand_assets.swift
swift -module-cache-path /tmp/beavermeter-brand-cache scripts/make_app_icon.swift
```

Rebuild the renderer afterward. Do not replace original design masters with
screenshots or delete them when cleaning generated preview matrices.

## Local packaging and official release

An unpublished local package uses:

```sh
zsh scripts/build_release.sh --local /tmp/beavermeter-local-release
```

It keeps production updates off and does not create a tag, Release or production
appcast. Node/npm and native packaging dependencies are developer requirements.
Official publication is a separate workflow governed by the
[release policy](../RELEASE_POLICY.md) and requires a separate publication step.

An isolated updater test can exercise the numbering transition without reading
the production signing Keychain:

```sh
source_app=/path/to/BeaverMeter.app
zsh Tests/sparkle_install_test.sh "$source_app" \
  .build/sparkle-tooling/distribution --ephemeral-signing --renumbering
```

This creates a temporary CryptoKit signing key and isolated app copies, checking
**5.5.0/build 36 → 1.0.0/build 37** through the real loopback Sparkle flow. These
numbers are test metadata, not references to a public release. It is not
production end-to-end acceptance: live credentials, LaunchAgents, desktop
Widgets, administrator authorization, quarantined downloads and independently
built public versions still need their own evidence.

## Performance and validation

[Performance](../PERFORMANCE.md) records controlled synthetic workloads;
[runtime performance](../RUNTIME_PERFORMANCE.md) records real process observations,
collector contention and limits. Reduced repeated decoding is not a frame-rate
or leak result. The 493 ms awake interval is not declared resolved.

The [validation record](../RELEASE_VALIDATION.md) keeps results by build/contract.
Do not carry an old screenshot or prior test count forward as current acceptance.
Keep optional diagnostics to fixed event names/durations, without account data,
and preserve normal refresh frequency and authentication behavior.

## Layout of the repository

| Path | Role |
| --- | --- |
| `App/` | Menu app, stores, lifecycle and updater integration |
| `Widget/` | WidgetKit provider, intent and adaptive module views |
| `Shared/` | Snapshot/model/presentation and shared assets |
| `Collector/` | Independent provider reads and scoped caches |
| `PreviewRenderer/`, `QA/WidgetHost/` | Synthetic previews and isolated QA tools |
| `Design/`, `screenshots/` | Original artwork and canonical synthetic product images |
| `docs/guide/` | Current bilingual guides |
| `scripts/`, `Tests/` | Build/install/release tooling and tests |
