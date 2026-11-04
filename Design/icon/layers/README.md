# Icon Composer layers

For iOS 26's own icon format (`.icon`), which renders the light, dark, clear and tinted
looks from one set of layers.

1. Open Icon Composer (Xcode → Open Developer Tool → Icon Composer), new icon.
2. Drag in `1-cards.svg`, then `2-now.svg` (bottom to top).
3. Background fill: light `#E9E9EE`, dark `#000000`.
4. Dark appearance: cards fill `#2C2C2E`, now line `#FF6B66`.
5. Save as `AppIcon.icon` next to `Tageslicht/` and add it to the app target. Keep
   `Assets.xcassets/AppIcon.appiconset` for iOS 18; the project's icon name stays `AppIcon`.
