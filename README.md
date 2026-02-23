# Docktor

![Docktor icon](Docktor/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

Docktor is a lightweight macOS menu bar app that lets you run actions by clicking or scrolling on Dock icons.

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
brew install --cask apotenza92/tap/docktor
```

Beta (side-by-side as `Docktor Beta.app`):

```bash
brew install --cask apotenza92/tap/docktor@beta
```

Manual:

1. Download the latest zip from GitHub Releases.
2. Move `Docktor.app` (or `Docktor Beta.app`) to `/Applications`.
3. Launch once and grant permissions.

## Required macOS Permissions

- Accessibility
- Input Monitoring

System Settings paths:

- `Privacy & Security > Accessibility`
- `Privacy & Security > Input Monitoring`

## Build

```bash
xcodebuild -project Docktor.xcodeproj -scheme Docktor -configuration Debug build
```

## Release

1. Ensure `Docktor.xcodeproj` `MARKETING_VERSION` matches the release version.
2. Add the matching heading in `CHANGELOG.md` (`## [vX.Y.Z]` or `## [vX.Y.Z-beta.N]`).
3. Tag and push with:

```bash
./scripts/release.sh 0.0.10
# or prerelease
./scripts/release.sh 0.0.10-beta.1
```
