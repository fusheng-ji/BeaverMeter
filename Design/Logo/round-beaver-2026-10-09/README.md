# BeaverMeter · Round Beaver family

> Historical centered-head study. The current outfits use [A1-v2 directly](../a1-layout-refinement-2026-10-09/README.md), preserving its lower-left pose and sage-teal background, with grouped accessory placement. These originals and their generation records remain preserved.

The user selected [A1-v2](../ip-as-logo-candidates-2026-10-09/A1-v2.png) after the [IP as Logo exploration](../ip-as-logo-candidates-2026-10-09/README.md). This production family carries its soft round cheeks, chestnut head, cream muzzle, short incisors and calm expression into a complete centered avatar and eight seasonal outfits.

The approved square [A1-v2 original](../ip-as-logo-candidates-2026-10-09/A1-v2.png) remains the separate Finder AppIcon source, retaining its sage-teal background and lower-left emergence. Its exact edit prompt and native dimensions remain in [A1-v2.metadata.json](../ip-as-logo-candidates-2026-10-09/A1-v2.metadata.json).

## Sources and generation

All nine images below are original **1254 × 1254** PNG outputs from the built-in `image_gen.imagegen` tool. The interface does not expose a model name. The user approved using this tool; no model identity is inferred and no API/CLI fallback was used. Original output bytes are retained here without resizing or image edits.

The centered [classic master](beaver-standard.png) was edited once from A1-v2 with `transparent_background: true`, reconstructing the complete cheeks and lower head. Each of the eight outfits was then edited independently, once, from this same `beaver-standard.png` master with `transparent_background: true`; no outfit was derived from another outfit.

The production prompts preserve the master’s face, position, scale and rounded shapes while adding compact accessories around its head. They request at least 40 pixels of clear perimeter space and keep eyes, nose, smile and teeth visible. This is a separate production adaptation after the six-image candidate stage: the transparent centered avatars intentionally use different framing from the selected square Finder source.

[prompts.json](prompts.json) contains the exact master prompt, reference chain and all eight complete accessory prompts. Each linked metadata file records the actual generation result, source/reference information and native dimensions. The first-round candidate records remain preserved separately.

## Nine-original preview

| Classic Beaver | New Year | Lunar New Year |
| --- | --- | --- |
| ![Classic round beaver](beaver-standard.png) | ![Round beaver with party hat, blower and confetti](beaver-newYear.png) | ![Round beaver with red scarf, envelope and gold ingot](beaver-lunarNewYear.png) |

| Lantern Festival | Dragon Boat Festival | Mid-Autumn Festival |
| --- | --- | --- |
| ![Round beaver with lantern and tangyuan](beaver-lanternFestival.png) | ![Round beaver with leaves, zongzi and paddle](beaver-dragonBoat.png) | ![Round beaver with crescent, mooncake and osmanthus](beaver-midAutumn.png) |

| Programmers’ Day | Halloween | Christmas |
| --- | --- | --- |
| ![Round beaver with keyboard, 1024 chip and code brackets](beaver-programmerDay.png) | ![Round beaver with witch hat, pumpkin and bat](beaver-halloween.png) | ![Round beaver with Santa hat, candy cane and holly](beaver-christmas.png) |

## Outfit records

Variant IDs and local-calendar dates retain the existing application behavior. Automatic mode resolves the Mac’s local date and time zone; a fixed selection displays the chosen outfit throughout the year. Lunar holidays match normal months, with Lunar New Year’s Eve identified by the following day being the first lunar day of the year.

| Stable ID | Outfit / automatic dates | Accessories | Original and metadata |
| --- | --- | --- | --- |
| `standard` | Classic Beaver / other dates | Complete round head without accessories | [PNG](beaver-standard.png) · [Metadata](beaver-standard.metadata.json) |
| `newYear` | 元旦 · New Year / January 1 | Rounded party hat, party blower, sparse confetti | [PNG](beaver-newYear.png) · [Metadata](beaver-newYear.metadata.json) |
| `lunarNewYear` | 春节 · Lunar New Year / lunar New Year’s Eve through first month day 7 | Red scarf, red envelope, small gold ingot | [PNG](beaver-lunarNewYear.png) · [Metadata](beaver-lunarNewYear.metadata.json) |
| `lanternFestival` | 元宵 · Lantern Festival / lunar first month day 15 | Red lantern, small bowl of tangyuan | [PNG](beaver-lanternFestival.png) · [Metadata](beaver-lanternFestival.metadata.json) |
| `dragonBoat` | 端午 · Dragon Boat Festival / lunar fifth month day 5 | Broad green leaves, zongzi, small wooden paddle | [PNG](beaver-dragonBoat.png) · [Metadata](beaver-dragonBoat.metadata.json) |
| `midAutumn` | 中秋 · Mid-Autumn Festival / lunar eighth month day 15 | Gold crescent, mooncake, osmanthus sprig | [PNG](beaver-midAutumn.png) · [Metadata](beaver-midAutumn.metadata.json) |
| `programmerDay` | 程序员日 · Programmers’ Day / **October 24** | Compact keyboard, mint `1024` chip, code brackets | [PNG](beaver-programmerDay.png) · [Metadata](beaver-programmerDay.metadata.json) |
| `halloween` | 万圣节 · Halloween / October 31 | Rounded witch hat, friendly pumpkin lantern, small bat | [PNG](beaver-halloween.png) · [Metadata](beaver-halloween.metadata.json) |
| `christmas` | 圣诞节 · Christmas / December 24–26 | Santa hat, candy cane, holly with red berries | [PNG](beaver-christmas.png) · [Metadata](beaver-christmas.metadata.json) |

## Runtime artwork

The complete transparent family is intended for the popover and documentation. The menu bar uses one shared monochrome outline derived from the new classic character across all nine outfit selections, with the system supplying its tint. Widgets retain official provider logos. The existing frosted-glass interface, appearance persistence and holiday rules remain in place.

Keep these originals as the generation archive; size-specific runtime exports and presentation images are derived resources. The earlier holiday prompts remain available in the [historical refinement record](../holiday-refinement-prompts.md). The [validation record](VALIDATION.md) covers source transparency, runtime sizes, builds, tests and updated software previews.
