# BeaverMeter release policy

## Current baseline

The current version is **1.0.0, build 37**. No new `v1.0.0` tag or official DMG
has been published. Local packaging keeps production updates off and does not
publish assets; official publication uses the separate workflow below.

## Official packages and installation

Stable official releases provide a Universal app for macOS 14+ on Apple Silicon
and Intel. One `BeaverMeter-X.Y.Z-universal.dmg` serves Finder installation and
Sparkle updates. Users need no Xcode, XcodeGen or Homebrew. Packaging developers
need the toolchain and pinned npm `create-dmg` 8.1.0 dependencies.

Drag the app to `/Applications` or `~/Applications`, eject the image and open the
installed app. When both locations contain the official app, `/Applications`
takes precedence. The other copy opens the preferred app; duplicates are not
silently deleted. Downloads, Desktop, mounted images and App Translocation are
not runtime installation locations.

Official identities are `io.github.fushengji.beavermeter` and
`io.github.fushengji.beavermeter.widget`. Custom source identities remain local
and do not use the production updater. Switching from an old/custom identity
may require removing and re-adding the desktop Widget.

First launch registers the Widget and configures the per-user background agent.
Existing configuration, sign-ins and snapshots are preserved. Supported imports
do not overwrite existing BeaverMeter files. Configured refresh intervals are
preserved, with five minutes as the default.

Lifecycle changes use a system lock and rollback state. Failed setup restores
prior agent files and loaded state; failed recovery retains its private backup
and logs for the next launch. Upgrading does not invoke uninstall. Collection
continues through the agent when the menu app quits.

Current apps are ad-hoc signed and **not Apple notarized**. Follow
[Apple's guidance](https://support.apple.com/en-us/102445) for a trusted blocked
download. The app does not disable Gatekeeper or strip quarantine. An unwritable
installation location or another-user-owned app can require administrator approval.

## Official update behavior

Only eligible tagged production builds enable `BeaverMeterUpdatesEnabled`.
Sparkle 2.10.0 runs in the main app, not separate Widget/collector updaters.
Source builds, `--local` packages, demos and previews do not start the
production updater.

The configured production-feed endpoint requires a published signed appcast:

`https://github.com/fusheng-ji/BeaverMeter/releases/latest/download/appcast.xml`

One startup check supplements Sparkle's normal **twelve-hour** schedule when
automatic checking is enabled. Repeated application preparation does not create
multiple updaters or duplicate launch checks. The user's automatic-check
preference is respected.

A newer version produces a menu-bar notification dot and a versioned button,
for example **Update 1.0.1**.
Clicking it, or **Check for Updates…**, enters Sparkle's native release-notes,
download, verification and **Install and Relaunch** flow. Automatic checks do
not open an update window or automatically install. Automatic background download
and system profiling are disabled; provider credentials are not attached to
GitHub requests. Sparkle owns preferences, scheduling, download, replacement and
relaunch; no competing self-copy updater is implemented.

App and Widget versions/builds match. `CFBundleVersion` increases for later
installable builds and controls update ordering. Future published versions must
advance their version/build metadata. Official feeds use full stable DMGs, not
local test packages, prereleases or delta assets.

Before installation, active account sign-in blocks the update. Runtime preparation
stops new collection, records the app path/target build/prior agent state in a
private journal, unloads its agent and drains only that bundle's helpers for the
current user. Unrelated/source-build processes are not targeted. Failure refuses
installation and recovers previous services. Download or authorization failure
does not replace the installed app.

After relaunch, recovery and Widget registration finish before live collection
and checks begin. If relaunch fails, reopen BeaverMeter to recover. There is no
separate recovery watchdog. A failed installation must not delete account data.

## Signing and assets

A persistent EdDSA key authenticates the DMG, feed and release notes. Its public
key is committed in `Config/SparklePublicKey.txt` and embedded as `SUPublicEDKey`.
Private material belongs in the `BeaverMeter.Release` Keychain account and the
repository Actions secret `BEAVERMETER_SPARKLE_PRIVATE_KEY`, with an independently
protected backup. A missing-key error must not automatically generate a new key.

Release-owner provisioning commands, used only with the intended existing key:

```sh
zsh scripts/configure_update_signing.sh --check
zsh scripts/configure_update_signing.sh --backup "$HOME/Documents/BeaverMeter-update.private-key.enc"
zsh scripts/configure_update_signing.sh --github-secret
```

Backup prompts locally for a password; keep it separately. GitHub secret setup
needs an authenticated account with the appropriate secret-management permission.
Private key input travels through stdin, not command arguments or logs. Never
commit plaintext secrets. Restore an encrypted backup with `openssl enc -d
-aes-256-cbc -pbkdf2 -iter 600000` into a private temporary file, import it with
Sparkle's `generate_keys --account BeaverMeter.Release -f <private-file>`, then
remove the plaintext export.

`SUVerifyUpdateBeforeExtraction`, `SURequireSignedFeed` and zero feed-failure
expiration require verification without a timeout fallback. EdDSA is not Apple
notarization and does not bypass first-launch Gatekeeper. Without a Developer ID
fallback, losing the private signing key requires manually installing an app
with a new public key; it is not grounds to disable validation.

| Official asset | Purpose |
| --- | --- |
| `BeaverMeter-X.Y.Z-universal.dmg` | Complete app, Widget, collector, scripts and Sparkle |
| `BeaverMeter-X.Y.Z-source.zip` | Exact tagged source and build instructions |
| `appcast.xml` | Signed current stable update with exact-tag asset URL |
| `release-notes.md` | Signed notes shown by Sparkle |
| `SHA256SUMS` | Checksums of the other four assets |

Signatures and hashes cover final bytes. Do not edit signed feed/notes or rebuild
the DMG afterward. SHA256 checks corruption; EdDSA authenticates the signing-key
holder. Recreating an artifact changes its signed bytes and requires validation
and signing again before publication.

## Packaging and publication gates

Local, unpublished packaging:

```sh
zsh scripts/build_release.sh --local /tmp/beavermeter-local-release
```

This produces a local package/checksum with production updates off, without an
official source archive/appcast or any tag/commit/publication action.

For a separately approved official release:

1. Finalize source/resources, matching app/Widget versions and increased build,
   release notes and changelog. Create the exact release tag only after approval.
2. Run Apple Silicon/Intel tests, resolve pinned dependencies, check the intended
   signing key and build Universal binaries. Preserve nested Sparkle permissions,
   symlinks and signatures.
3. Validate identities, versions, keys, architecture slices, signatures and runtime
   resources. Mount/check the Finder DMG and verify the exact-tag source archive.
4. Generate signed feed/notes and checksums. Upload a draft, download its assets
   and verify the uploaded bytes before an explicit final publish decision.

The official packaging command uses an approved existing tag:

```sh
zsh scripts/build_release.sh /tmp/beavermeter-release vX.Y.Z
```

Before the first official updater release, validate real check/download/signature/
installation/relaunch/recovery/Widget behavior using two actual versions. Test
cancel, bad signatures, authorization refusal, setup failure, duplicate copies
and data preservation. Downloaded/quarantined installation and macOS 14 need
separate checks; unit tests and a local signature are not substitutes.

The opt-in Sparkle integration test uses isolated copies and a loopback feed:

```sh
source_app=/path/to/BeaverMeter.app
zsh Tests/sparkle_install_test.sh "$source_app" \
  .build/sparkle-tooling/distribution --ephemeral-signing --renumbering
```

The ephemeral mode uses a temporary CryptoKit key and does not read the formal
release Keychain. Renumbering tests **5.5.0/build 36 → 1.0.0/build 37** using isolated
copies; these numbers are test metadata, not references to a public release. It tests signed feed/download/installer/relaunch, cancellation and corrupt
data, not production credentials, live agents/Widgets, administrator authorization,
quarantined downloads or two independently built public releases. Current evidence and pending limits
belong in [release validation](RELEASE_VALIDATION.md), not inferred from this policy.
