# Geogram icons

The god sign (star) alone. Ink #2A2620 · bone #E8E3D6 · dark #232A2E · sand #F4F1EA.
Stroke thickens as the icon shrinks: 7.5% of the box at large sizes, 9% at 48dp, 11.5% at 32dp, 13% at 24dp, 15% at 18dp.

## android/
- `mipmap-*/ic_launcher_foreground.png` — adaptive foreground, transparent, star in the 66dp safe zone
- `mipmap-*/ic_launcher.png` — legacy square launcher
- `drawable-*/ic_stat_geogram.png` — notification, white on transparent (Android discards colour)
- `ic_launcher_monochrome_432.png` — Android 13 themed-icon layer
- `ic_launcher.xml` — adaptive-icon definition; background colour #232A2E
- `play-store-512.png` — store listing

## ios/
`AppIcon-*.png`, opaque, square, no alpha and no pre-rounded corners — iOS applies its own mask.

## linux/
Freedesktop hicolor tree: install `<size>x<size>/geogram.png` to `/usr/share/icons/hicolor/<size>x<size>/apps/`.
`geogram-512-dark.png` is the light-on-dark variant for dark shells.

## web/
`favicon.svg` (preferred), PNG fallbacks 16–512, `maskable-512.png` with extra padding for PWA installs, `site.webmanifest`.

```html
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon-32.png" sizes="32x32">
<link rel="apple-touch-icon" href="/favicon-180.png">
<link rel="manifest" href="/site.webmanifest">
```

## Flutter
```yaml
flutter_launcher_icons:
  android: true
  ios: true
  image_path: "icons/android/play-store-512.png"
  adaptive_icon_background: "#232A2E"
  adaptive_icon_foreground: "icons/android/mipmap-xxxhdpi/ic_launcher_foreground.png"
  adaptive_icon_monochrome: "icons/android/ic_launcher_monochrome_432.png"
```

Source vectors: `geogram-star.svg`, `geogram-star-notification.svg`.
