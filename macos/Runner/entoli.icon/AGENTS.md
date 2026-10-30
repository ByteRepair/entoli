# The app icon

`entoli.icon` is an Icon Composer package (Apple's format for the iOS 26 /
macOS 26 "Liquid Glass" icon), hand-authored from `assets/icons/cookie.svg` —
the app's default icon, the one iOS and macOS show (launcher switching is
Android's `activity-alias` alone; the other icon has no copy here, the way it
has no Linux or Windows one). `ios/Runner/entoli.icon` is a symlink to this directory: it is
one icon for both platforms, `supported-platforms: squares shared`, and the
build compiles it to whatever each target needs.

The research below is what the format's shape and the guidelines' rules were
verified from, for whoever regenerates or hand-edits this file next.

## What the layers are

- `icon.json`'s top-level `fill` (`automatic-gradient`, seeded with the app's
  indigo `#4F46E5` as extended-srgb floats) is the background: the system
  generates its graded glass surface and adapts it per appearance, which is why
  the baked squircle of `cookie.svg` (the `mask` clip group) is not carried
  over — guidelines say to provide square layers and never bake the mask,
  because pre-masked edges break the specular highlight and go jagged
  (developer.apple.com/design/human-interface-guidelines/app-icons,
  developer.apple.com/videos/play/wwdc2025/361/).
- `Assets/cookie-foreground.svg` is the white blob with the chevron and input
  bar, at `cookie.svg`'s same inner geometry (its group's
  `translate(7.2,10.67) scale(0.8667)` composed onto the 1024 canvas:
  `translate(68.266668,101.167408) scale(8.2176)`), no drop-shadow filters and
  no background fill: shadows, blur and glass effects are the system's to
  apply, per the same HIG page.

## What the build does with it

- Wired the way flutter/flutter PR #191059 wires the template's: the `.icon`
  referenced with `lastKnownFileType = folder.iconcomposer.icon` in the
  Resources phase, and the build setting pair
  `ASSETCATALOG_COMPILER_APPICON_NAME = entoli` /
  `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = NO` in every
  configuration. Xcode automatically back-deploys: it generates flattened
  renditions at build time for OS releases the layered format predates.
- The asset-catalog `AppIcon.appiconset`s this replaces are deleted; Apple: an
  `.icon` replaces any existing icon asset catalog. On macOS the whole
  `Assets.xcassets` went with it — its only set was the icon — leaving
  `Assets.car` + `entoli.icns` in the bundle; on iOS the catalog stays for
  `LaunchImage`.
- Verified on actool Xcode 27: the package compiles for `iphoneos` and
  `macosx` at deployment targets 13.0 / 12.0 (and 26.0) with zero warnings, the
  iOS car carrying all six renditions (phone and pad, default and dark and
  tintable, each 1024x1024) auto-derived from the one layer, and the macOS one
  carrying the ladder 32→1024 with `entoli.icns` beside it.

## Format notes nobody should relearn the hard way

- There is **no layered app icon in the asset catalog**: `foreground` /
  `background` image ids in an `.appiconset` are "unassigned child" warnings
  and compile to a flat rendition. Layering exists only through an `.icon`
  package.
- There is **no single-size icon for macOS in the catalog** either: the
  `"platform": "macos"` key is rejected ("Unknown platform value macos", and no
  icns/car emitted); single-size is an iOS/tvOS/watchOS behavior, macOS keeps
  its per-size ladder (which the `.icon` replaces wholesale).
- A `.icon` package behaves as its own actool document: passing one inside an
  `.xcassets` to the CLI finds no matching icon — the file is referenced
  directly, at the top of the Resources phase like any catalog.
- A catalog's rendition demands exact pixels: a macOS ladder PNG that is not
  `size × scale` fails ("icon_512.png is 1024x1024 but should be 512x512").
- Groups cap at four; each is one depth plane carrying `layers`, `shadow`
  (kind neutral, opacity) and `translucency` (enabled, value). Layers carry
  `name`, `image-name`, `fill`, `glass`, `blend-mode`, `position`
  (scale + translation-in-points). The per-appearance `*-specializations` keys
  are undocumented; Apple says author those with Icon Composer, not by hand.
- Dark and tinted variants of a flat icon stay valid in an `.appiconset`
  (`appearances: [{appearance: luminosity, value: dark|tinted}]`, single-size
  entries carrying no `scale` key): dark wants a transparent background, tinted
  a grayscale image. Under an `.icon` the system derives them, so none are
  authored here.
- Numeric safe areas for the icon grid are not published; the grids live in
  the Apple Design Resources templates and Icon Composer. Keep primary content
  centered and clear of the corners the mask crops.