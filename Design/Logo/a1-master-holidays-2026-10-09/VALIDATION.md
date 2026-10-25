# A1-v2 holiday family validation

## Reference and originals

The classic image is byte-identical to the approved A1-v2 master. All eight
seasonal images use that original as their sole ImageGen edit reference, each
generated once. Every returned original is saved unmodified at 1254 × 1254.
Per-image metadata records the exact prompt, source path, native dimensions and
reference/output SHA-256. Canonical logo sources match these saved originals.

Master SHA-256:
`042ba6424c367007ae01f74e534399986f60b6871a097e070befb17923eb8c84`

## Visual inspection

The nine-image collection and individual originals were inspected. The seasonal
edits retain the master's lower-left pose, viewing angle, face scale, existing
left/bottom crop, expression and sage-teal background. Eyes, nose, smile and
front teeth remain visible.

Some accessories meet the original cropped frame: the Lunar New Year scarf,
Lantern Festival cord and Programmers' Day keyboard. The Dragon Boat zongzi,
Mid-Autumn mooncake and keyboard overlap part of the outer cream cheek. The
Christmas candy cane is close to the right edge. These observations are recorded
without cropping, repainting or regenerating any original.

## Export and application checks

- All nine color exports retain the full source canvas, using the same 480px
  frame with a 16px inset on a 512 × 512 canvas. No accessory-dependent crop or
  scale is applied.
- All nine 72px menu templates use the same monochrome outline. The existing
  18pt menu-bar rendering and Finder A1-v2 icon are retained.
- The application and Widget build passed with the updated runtime assets.
  The 13 selected `BrandAppearanceTests` and `BrandMenuMarkTests` passed.
- `Tests/navigation_bundle_test.sh` passed for the built application, checking
  application/Widget navigation schemes and bundled provider logos.
- The preview renderer rebuilt successfully and `--check-assets` passed.
  Seven rendering runs refreshed 83 screenshots, including light/dark menus,
  Christmas, automatic October 24 selection, empty/all-service states, long
  values, errors and the blue Update button during refresh.
- All 322 protected Widget and service-gallery files retained their previous
  SHA-256. Widgets continue to show provider logos.

The glass appearance, interface layout, variant IDs, settings format and holiday
dates are unchanged. No installed application was replaced and no commit, tag or
Release was published.

## Local verification logs

The selected test log is `/tmp/beavermeter-a1-direct-brand-tests.log`.
Preview build and asset checks are recorded in
`/tmp/beavermeter-a1-direct-preview-build.log` and
`/tmp/beavermeter-a1-direct-preview-assets.log`; the seven corresponding
`*-render.log` files record the render runs.

See [machine-readable validation](validation.json) and [generation results](results.json).
