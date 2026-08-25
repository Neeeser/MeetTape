# Pipit brand assets

The scenic icon is the primary app icon. `AppIcons/Pipit.icns` contains the
standard macOS icon sizes generated from the 1024 px primary PNG.

The cream, navy, and ochre icons are retained as alternate directions. Their
`-source.png` files contain the ImageGen output. Their `-1024.png` files are
normalized square masters.

`MenuBar/` contains four monochrome template-image states:

- `pipit-idle.png`
- `pipit-recording.png`
- `pipit-paused.png`
- `pipit-warning.png`

Each menu bar PNG is 18 px. Its `@2x` partner is 36 px. The source PNGs are
kept for future size changes.

`README/pipit-readme-hero.png` is the standalone repository hero. `Concept/`
keeps the approved comparison board that established the visual direction.

The app bundle uses `Pipit.icns`, the menu bar controller uses the four template
images, and the root README uses the hero. The executable, Swift package, and
application bundle are all named Pipit.
