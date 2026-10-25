# BeaverMeter brand assets

The current beaver is based on the user-approved **A1-v2** design from
[IP as Logo](https://github.com/s1dashu/ip-as-logo-skill/blob/main/SKILL.md).
It uses a rounded chestnut head, a broad cream muzzle, plump cheeks, round ears,
a gentle smile and two short front incisors. The built-in ImageGen tool produced
the original artwork; its interface does not expose the model name.

The [six first-round candidates and A1-v2 refinement](ip-as-logo-candidates-2026-10-09/README.md)
are retained with their original pixels and generation records.
[The production family](a1-layout-refinement-2026-10-09/README.md) uses A1-v2
directly for all eight accessory edits, retaining its lower-left emergence,
viewing angle, scale, crop and sage-teal background. Exact prompts and per-image
metadata are saved alongside the original outputs.

## Artwork and usage

- `beaver-app-icon.png` retains A1-v2's sage-teal background and lower-left
  emergence composition. Finder uses this everyday image throughout the year.
- `beaver-standard.png` is a byte-for-byte copy of approved A1-v2, used by
  the popover. Each outfit uses A1-v2 itself as its sole edit reference.
- The eight seasonal source names use stable variant IDs. Every edit starts
  from the same standard master, preserving the face, expression and framing.
- `beaver-menu-outline.svg` is the editable monochrome drawing used by all
  nine menu-bar variants. It retains round ears, full cheeks, a tiny smile
  and short incisors; it omits shading, whiskers and a forehead tuft.
- Widgets use official provider logos; changing the beaver's outfit does not
  change those service marks.

The previous production masters and menu drawing are preserved in
`legacy-classic-2026-10-09/`. The original candidate artwork remains intact.

## Eight outfits

| ID / filename suffix | Accessory brief |
| --- | --- |
| `newYear` | Party hat, party blower and sparse confetti |
| `lunarNewYear` | Red scarf, red envelope and small gold ingot |
| `lanternFestival` | Red lantern and a small bowl of tangyuan |
| `dragonBoat` | Green leaves, wrapped zongzi and small wooden paddle |
| `midAutumn` | Golden crescent, mooncake and osmanthus flowers |
| `programmerDay` | Mini keyboard, 1024 chip and code brackets |
| `halloween` | Witch hat, pumpkin lantern and small bat |
| `christmas` | Santa hat, striped candy cane and holly |

Accessories use broad rounded shapes and coordinated accent colors. They sit
around the original head without covering eyes, nose, smile or incisors. The
full square and original sage-teal background remain part of every image.
No free-form accessory editor is implied.

The latest layout revision attaches small accents to the main accessory and
groups related props along the outer brown edge: holly joins the Santa hat,
the bat sits near the witch-hat tip, and the zongzi/paddle and keyboard/chip
form compact ensembles. The [previous layout](a1-master-holidays-2026-10-09/README.md)
is retained with its original artwork and records.

The existing automatic dates, manual selection and persistence format remain
unchanged. Programmers' Day is October 24 in the Mac's current time zone.
Previously saved `nationalDay` selections continue to map to `programmerDay`.

## Deterministic exports

From the repository root on macOS:

```bash
swift -module-cache-path /tmp/beavermeter-brand-cache scripts/make_brand_assets.swift
swift -module-cache-path /tmp/beavermeter-brand-cache scripts/make_app_icon.swift
```

The first script exports nine **512px** color PNGs and nine identical **72px**
menu templates to `Design/BrandAssets/`, plus `holiday-collection.png`.
All masters must share one square canvas. The exporter fits that complete canvas
into the same 480×480 frame with a 16px inset for every variant: it never crops
or scales by individual accessory bounds, so additional props cannot shrink the
beaver. The old 1254px-specific crop is no longer used.

The menu SVG has a transparent 64×64 viewBox, 4-unit round strokes and small solid
eyes and nose. Native WebKit renders its antialiased masks. Display the template
at **18pt** so macOS supplies the appropriate tint.
`--templates-only` rebuilds the masks and
[light/dark menu study](../../screenshots/menu-bar-logo-study.png) without changing
the color artwork.

The second script renders all **16–1024px** AppIcon sizes from the full approved
square. It applies the conventional rounded macOS body and outer margin,
preserving the original picture rather than alpha-cropping a transparent head
or adding a separate background plate.

The [light and dark outfit specimens](../../screenshots/holidays/README.md)
show the current runtime assets, including small template sizes. Rebuild the
preview renderer after exporting resources. All software screenshots use
bundled demonstration data, without real account values.
