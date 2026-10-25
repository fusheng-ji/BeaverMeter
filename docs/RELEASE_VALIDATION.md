# Release validation — 1.0.0 candidate (build 37)

## Current candidate — 2026-10-25

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
