# A1-v2 accessory layout validation

## Provenance

All eight edits use approved A1-v2 directly as their sole reference. Each was
generated once with the user-approved built-in ImageGen tool. The saved images
match the original returned files byte for byte, and every exact prompt matches
the recorded layout brief. All nine originals are 1254 × 1254; the classic image
remains byte-identical to A1-v2.

Master SHA-256:
`042ba6424c367007ae01f74e534399986f60b6871a097e070befb17923eb8c84`

## Visual observations

The original tilted expression, eye highlights, nose, smile, short front teeth,
overall head scale and left/bottom crop remain recognizable. Eyes, nose, smile
and teeth are visible in all eight outfits. The original sage-teal background
is retained. The individual originals and complete gallery were inspected.

| Outfit | Observed placement |
| --- | --- |
| New Year | Hat follows the head slope, confetti groups near its tip, blower sits at lower right |
| Lunar New Year | Scarf follows the cropped lower edge; envelope and ingot overlap as one right-side group |
| Lantern Festival | Short loop hangs from the right ear; bowl sits below, with about 10px right clearance |
| Dragon Boat | Leaves sit behind the left ear; zongzi and paddle group at lower right; zongzi overlaps part of the cream cheek |
| Mid-Autumn | Crescent and osmanthus form one upper-right accent; mooncake and additional flowers sit at lower right |
| Programmers' Day | Keyboard, 1024 chip and brackets form one lower-right group; keyboard overlaps the cream cheek, leaving teeth visible |
| Halloween | Hat is the primary accent, with about 15px top clearance; bat sits near its tip and pumpkin below on the right |
| Christmas | Holly attaches to the hat brim; full candy-cane hook stays inside the frame; right ear appears slightly lower and farther right under the brim |

The scarf intentionally meets the original left/bottom crop. No generated
original was repainted, cropped, filtered out or automatically retried.

## Integration checks

- All nine 512px runtime color exports retain the full source canvas, using a
  common 480px frame with a 16px inset. Accessory bounds do not alter face scale.
- All nine 72px menu templates are identical. Finder retains A1-v2 and Widgets
  retain provider logos. No interface code, layout or holiday rule was changed.
- The application and Widget build succeeded. All 18 packaged brand files match
  the runtime exports byte for byte. The navigation/provider bundle check passed
  and confirmed that the Widget does not bundle beaver artwork.
- The preview renderer build, `--check-assets` and three rendering runs passed.
  Six affected previews were refreshed: light/dark collection sheets, Christmas
  popovers and automatic October 24 popovers.
- The other 399 screenshot PNGs and service-gallery HTML retained their previous
  SHA-256. The holiday preview README received only a design-record link update.

Previous generation originals and galleries are archived. No installed app was
replaced and no commit, tag or Release was published.

See [machine-readable validation](validation.json), [generation results](results.json)
and [exact prompts](prompts.json). Local build and preview logs use the
`/tmp/beavermeter-a1-layout-*` prefix.
