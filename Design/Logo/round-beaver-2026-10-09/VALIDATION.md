# Round Beaver validation · 2026-10-09

## Artwork and deterministic exports

- A1-v2 is the user-approved master. Its original square remains the Finder source.
- The centered transparent master and eight independent outfit edits are retained unmodified at 1254 × 1254, with exact prompts, source paths and hashes.
- All nine faces and accessories were inspected: no accessory covers eyes, nose, smile or incisors; no significant alpha (≥16) touches a source edge. Minimum significant source clearance is 25px. Faint lower-alpha fringe is retained.
- Every 512px runtime color export uses the same full-canvas scale and 16px inset; extra props cannot change the beaver's scale.
- Nine 72px menu templates are byte-identical. Antialiased rounded outlines remain readable at 18pt in light/dark appearance, with an open body and transparent outer edges.
- Ten AppIcon PNGs match Contents.json and cover 16–1024px, preserving A1-v2's sage-teal background and lower-left composition.
- Source and runtime checks are summarized in [source-validation.json](source-validation.json). The family originals and metadata are linked in [README.md](README.md).

## Build and tests

The full existing test script passed in an isolated clean derived-data directory:

```bash
BEAVERMETER_DERIVED_DATA=/tmp/beavermeter-round-brand-derived-20261009 zsh scripts/test.sh
```

- 76 app/shared Swift unit tests and 49 collector unit tests passed (125 total).
- 12 Python tests passed.
- Shell syntax, migration, installation, runtime-setup, App/Widget bundle checks and collector fixtures passed.
- Clean app and Widget builds passed. The Widget bundle contains provider logos and no BrandAssets directory.
- Calendar boundaries, legacy outfit decoding, appearance persistence and the shared menu-template checks passed without changes to variant IDs or scheduling.

The first sandbox run could not access the existing GitHub package dependencies; a subsequent authorized run passed unit tests but detected old assets in an earlier cached embedded Widget bundle. The complete clean run resolved that cache issue without changing Widget code or project configuration.

## Software previews and documentation

- The preview renderer build and its bundled asset check passed.
- 83 demonstration screenshots were refreshed: menu/overview images, light/dark outfit specimens, Christmas and automatic October 24 examples, blue Update states, and 32 service-combination menus.
- Light/dark headers, expanded Appearance, long values, refresh errors and the 14–32pt shared template specimens were inspected.
- Service-gallery Widget images and its index remained byte-identical; the beaver is not part of Widget layouts.
- The refreshing Update screenshots use the existing native offscreen capture fallback, which upscales a 1× host cache to 2× on this machine and is slightly softer. Other ImageRenderer previews and source artwork retain native clarity.
- English/Chinese README image links, the production-family references and the shared menu study resolve to the current files.

No tag, commit, push, installed-app update or public Release is part of this logo change.
