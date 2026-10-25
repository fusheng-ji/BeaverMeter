# Holiday refinement prompts

The current family edits the user-approved A1-v2 master directly, retaining its lower-left composition, viewing angle, face size, crop and sage-teal background, with grouped accessory placement. See the [design record](a1-layout-refinement-2026-10-09/README.md) and [exact production prompts](a1-layout-refinement-2026-10-09/prompts.json). The previous [direct-edit layout](a1-master-holidays-2026-10-09/README.md), [centered-head study](round-beaver-2026-10-09/README.md) and the prompts below are preserved as historical work.

Generated with the built-in ImageGen tool, one edit call per edition, with `transparent_background: true`. Each input was the existing `beaver-<ID>.png` holiday master; outputs replace those masters with original alpha preserved. No API/CLI fallback was used.

## Shared prompt

Replace `{EDITION EDIT}` with the corresponding text below.

```text
Use case: precise-object-edit. Asset: BeaverMeter transparent holiday logo. Input image is the edit target. {EDITION EDIT} Preserve the existing beaver face exactly: same eyes, smile, cream muzzle, two front teeth, brown outlines, warm shading, head size and position. Preserve existing accessories. New props use the same polished illustrated logo style and bold outlines. Keep eyes and front teeth fully visible. No hands, body, text, badge background or watermark. Keep the same square canvas and face scale; fit decorations into existing transparent margins, do not shrink the head to make room. Maintain at least 2% transparent clearance at every edge. Genuine transparent background.
```

## Edition edits

### christmas

Keep the Santa hat. Add a red-and-cream striped hooked candy cane nestled along the lower-left outer cheek, and a small green holly sprig with three red berries on the hat trim.

### halloween

Keep the witch hat. Add a small warm orange smiling carved pumpkin lantern nestled at the lower-right outer cheek and one tiny charcoal bat flying beside the upper-left of the hat.

### newYear

Keep the party hat. Add a small curled teal and gold party blower beside the lower-right outer cheek (do not cover the mouth), plus just three sparse gold/teal confetti pieces beside the hat.

### lunarNewYear

Keep the red scarf and red envelope. Add one small polished gold yuanbao ingot nestled at the lower-left scarf edge.

### lanternFestival

Keep the hanging red lantern. Add one small red ceramic bowl with three cream tangyuan rice balls nestled at the lower-left outer cheek.

### dragonBoat

Keep the green leaf and wrapped zongzi. Add one small wooden boat paddle tucked diagonally behind the zongzi, staying near the outer cheek.

### midAutumn

Keep the gold crescent moon. Add a small golden scalloped mooncake at the lower-left outer cheek and a tiny osmanthus sprig with gold flowers near the moon.

### programmerDay

Replaces the retired outfit. Edited from `beaver-standard.png` with the built-in ImageGen tool and `transparent_background: true`.

```text
Use case: precise-object-edit / logo-brand. Edit target: image 1, the existing BeaverMeter standard transparent mascot master. Create the October 24 Programmer Day edition by adding ONLY three coordinated accessories: a small warm ivory mechanical keyboard near the lower-left OUTER cheek edge, a compact muted teal green microchip badge near the lower-right OUTER cheek edge with the EXACT readable digits "1024" in cream on its face, and two small muted teal coding angle brackets < > positioned above the ears. Keep the entire original beaver head EXACTLY unchanged in face shape, proportions, position, size, expression, eye highlights, cream muzzle, prominent two front teeth, chestnut outlines, ears, fur tuft, warm brown colors and softly shaded crisp illustration style. Keep the head the same scale and center as the input. Accessories should be supportive and compact: no accessory over the eyes, nose, teeth or forehead, no body, no large monitor, no clothes, no national flags, national emblems, ribbons, fireworks, or political symbols. Match the warm friendly polished illustration style of the mascot; accessories have chestnut outlines and gentle dimensional shading, not neon cyberpunk. Maintain a square genuinely transparent background, all four outer margins clear, at least 5% safety clearance from edges. No background, checkerboard, text or wordmark elsewhere, watermark or scene. Preserve existing alpha and framing; do not shrink the beaver to fit the props.
```
