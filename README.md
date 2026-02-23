# Dockter

![Dockter icon](Dockter/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

Dockter is a lightweight macOS menu bar app that lets you run actions by clicking or scrolling on Dock icons.

## Defaults

- First click on an inactive app: `App Expose`
- Click after app activation: `App Expose`
- Scroll up: `Hide Others`
- Scroll down: `Hide App`
- Optional: `>1 window only` can gate App Expose for both first-click and click-after-activation flows

## Install

Homebrew:

```bash
brew tap apotenza92/tap
brew install --cask apotenza92/tap/dockter
```

Beta (side-by-side as `Dockter Beta.app`):

```bash
brew install --cask apotenza92/tap/dockter@beta
```

Manual:

1. Download the latest zip from GitHub Releases.
2. Move `Dockter.app` (or `Dockter Beta.app`) to `/Applications`.
3. Launch once and grant permissions.

## Required macOS Permissions

- Accessibility
- Input Monitoring

System Settings paths:

- `Privacy & Security > Accessibility`
- `Privacy & Security > Input Monitoring`

## Build

```bash
xcodebuild -project Dockter.xcodeproj -scheme Dockter -configuration Debug build
```

## Release

1. Ensure `Dockter.xcodeproj` `MARKETING_VERSION` matches the release version.
2. Add the matching heading in `CHANGELOG.md` (`## [vX.Y.Z]` or `## [vX.Y.Z-beta.N]`).
3. Tag and push with:

```bash
./scripts/release.sh 0.0.9
# or prerelease
./scripts/release.sh 0.0.9-beta.1
```
