# DockActioner

Native macOS utility that augments Dock icon interactions with click and scroll actions.

## Stack

- Swift 5 / SwiftUI
- AppKit + CoreGraphics event taps
- Xcode project (`DockActioner.xcodeproj`)

## Common Commands

```bash
xcodebuild -project DockActioner.xcodeproj -scheme DockActioner -configuration Debug build
DOCKACTIONER_TEST_SUITE=1 ".build/Build/Products/Debug/DockActioner.app/Contents/MacOS/DockActioner"
swift tools/generate_icons.swift
./scripts/release.sh 0.0.1
```

## Release Rules

- Releases are tag-driven through `.github/workflows/release.yml`.
- Tag formats:
  - Stable: `vX.Y.Z`
  - Beta: `vX.Y.Z-beta.N`
- `DockActioner.xcodeproj` `MARKETING_VERSION` must match tag core version (`X.Y.Z`).
- `CHANGELOG.md` must contain a matching heading: `## [vX.Y.Z]` or `## [vX.Y.Z-beta.N]`.

## CI and Distribution

- `ci.yml`: push/PR verification (build only).
- `release.yml`: signed + notarized macOS artifacts, GitHub Release publishing, Homebrew tap sync.
- Homebrew casks are updated in `apotenza92/homebrew-tap`:
  - `dock-actioner`
  - `dock-actioner@beta`
- Beta cask tracks whichever is newer between stable and prerelease channels.

## Secrets Expected In GitHub

- `APPLE_SIGNING_CERTIFICATE_P12_BASE64`
- `APPLE_SIGNING_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_TEAM_ID`
- `APPLE_NOTARYTOOL_KEY_ID`
- `APPLE_NOTARYTOOL_ISSUER_ID`
- `APPLE_NOTARYTOOL_KEY_P8_BASE64`
- `SPARKLE_PRIVATE_ED_KEY`
- `HOMEBREW_TAP_TOKEN`

## UI/Product Constraints

- Keep menu bar icon template-based and legible at 16-18pt.
- Settings window is the only user-facing window and should remain compact.
- No separate Mission Control action; App Expose is the only expose-style action.
