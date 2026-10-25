# Release DMG tooling

Run `npm ci --prefix scripts/packaging`, then use:

```sh
node scripts/packaging/create_dmg.mjs /path/to/BeaverMeter.app /path/to/output \
  --no-code-sign '--dmg-title=BeaverMeter 1.0.0'
```

The launcher runs the locked create-dmg 8.1.0 CLI. Its default background,
composed volume icon, 660×400 window, 160pt icons, application/Applications
positions, APFS filesystem and ULFO format are unchanged. Appdmg 0.6.6 is
also checked explicitly; review the adapter when either dependency changes.

The adapter reads `hdiutil attach/info -plist` instead of parsing localized
mount output. Before every detach, it resolves the exact temporary image's
current device from a fresh `hdiutil info -plist`. Only a busy detach (exit
16) is retried. An APFS detach can unmount its volume before reporting busy;
retrying the vanished `/Volumes/...` path would hide that error and leak
the attached device. No force-detach, unrelated-device cleanup, filesystem
fallback or signature-validation bypass is used.

`npm test --prefix scripts/packaging` runs synthetic ownership and cleanup
tests without creating or touching disk images. The release script runs
these tests, packages the image, then independently verifies and mounts it
to validate the complete signed universal application and drag-install link.
