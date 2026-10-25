# Seasonal previews

Real SwiftUI renders using demo usage data. The seasonal specimen sheets cover menu-bar and popover branding. Desktop Widgets
contain only service cards; the four-size light/dark renders below intentionally
remain identical across seasonal editions. No live accounts or user settings are used.

[Light logo specimens](logo-collection-light.png) · [Dark logo specimens](logo-collection.png) · [Christmas popover, light](menu-christmas-light.png) · [Christmas popover, dark](menu-christmas.png)

The specimen sheets use the direct A1-v2 accessory edits, retaining its lower-left pose and sage-teal background, and show colour logos and template marks at 14, 18, 24 and 32pt, rendered at 2×. The menu mark is shared by all outfits; colour accessories appear in the popover. [Original artwork and generation records](../../Design/Logo/a1-layout-refinement-2026-10-09/README.md).

| Edition | Small | Medium | Large | Extra large |
| --- | --- | --- | --- | --- |
| Classic Beaver | [Light](widget-small-standard-light.png) / [Dark](widget-small-standard.png) | [Light](widget-medium-standard-light.png) / [Dark](widget-medium-standard.png) | [Light](widget-large-standard-light.png) / [Dark](widget-large-standard.png) | [Light](widget-extra-large-standard-light.png) / [Dark](widget-extra-large-standard.png) |
| New Year | [Light](widget-small-newYear-light.png) / [Dark](widget-small-newYear.png) | [Light](widget-medium-newYear-light.png) / [Dark](widget-medium-newYear.png) | [Light](widget-large-newYear-light.png) / [Dark](widget-large-newYear.png) | [Light](widget-extra-large-newYear-light.png) / [Dark](widget-extra-large-newYear.png) |
| Lunar New Year | [Light](widget-small-lunarNewYear-light.png) / [Dark](widget-small-lunarNewYear.png) | [Light](widget-medium-lunarNewYear-light.png) / [Dark](widget-medium-lunarNewYear.png) | [Light](widget-large-lunarNewYear-light.png) / [Dark](widget-large-lunarNewYear.png) | [Light](widget-extra-large-lunarNewYear-light.png) / [Dark](widget-extra-large-lunarNewYear.png) |
| Lantern Festival | [Light](widget-small-lanternFestival-light.png) / [Dark](widget-small-lanternFestival.png) | [Light](widget-medium-lanternFestival-light.png) / [Dark](widget-medium-lanternFestival.png) | [Light](widget-large-lanternFestival-light.png) / [Dark](widget-large-lanternFestival.png) | [Light](widget-extra-large-lanternFestival-light.png) / [Dark](widget-extra-large-lanternFestival.png) |
| Dragon Boat | [Light](widget-small-dragonBoat-light.png) / [Dark](widget-small-dragonBoat.png) | [Light](widget-medium-dragonBoat-light.png) / [Dark](widget-medium-dragonBoat.png) | [Light](widget-large-dragonBoat-light.png) / [Dark](widget-large-dragonBoat.png) | [Light](widget-extra-large-dragonBoat-light.png) / [Dark](widget-extra-large-dragonBoat.png) |
| Mid-Autumn | [Light](widget-small-midAutumn-light.png) / [Dark](widget-small-midAutumn.png) | [Light](widget-medium-midAutumn-light.png) / [Dark](widget-medium-midAutumn.png) | [Light](widget-large-midAutumn-light.png) / [Dark](widget-large-midAutumn.png) | [Light](widget-extra-large-midAutumn-light.png) / [Dark](widget-extra-large-midAutumn.png) |
| Programmers' Day | [Light](widget-small-programmerDay-light.png) / [Dark](widget-small-programmerDay.png) | [Light](widget-medium-programmerDay-light.png) / [Dark](widget-medium-programmerDay.png) | [Light](widget-large-programmerDay-light.png) / [Dark](widget-large-programmerDay.png) | [Light](widget-extra-large-programmerDay-light.png) / [Dark](widget-extra-large-programmerDay.png) |
| Halloween | [Light](widget-small-halloween-light.png) / [Dark](widget-small-halloween.png) | [Light](widget-medium-halloween-light.png) / [Dark](widget-medium-halloween.png) | [Light](widget-large-halloween-light.png) / [Dark](widget-large-halloween.png) | [Light](widget-extra-large-halloween-light.png) / [Dark](widget-extra-large-halloween.png) |
| Christmas | [Light](widget-small-christmas-light.png) / [Dark](widget-small-christmas.png) | [Light](widget-medium-christmas-light.png) / [Dark](widget-medium-christmas.png) | [Light](widget-large-christmas-light.png) / [Dark](widget-large-christmas.png) | [Light](widget-extra-large-christmas-light.png) / [Dark](widget-extra-large-christmas.png) |

Regenerate after building `BeaverMeterPreviewRenderer`:

```bash
"$BEAVERMETER_PREVIEW" --holidays screenshots/holidays --appearance both
```

The Christmas popover samples use `--logo christmas --appearance both` in the normal screenshot mode.

The October 24 automatic outfit is shown in the [light](menu-popover-programmerDay-light.png)
and [dark](menu-popover-programmerDay.png) popover samples, using
`--date 2026-10-24 --time-zone Europe/Berlin --logo automatic --appearance both`.
