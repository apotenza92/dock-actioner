# Dockmint

Native macOS utility that augments Dock icon interactions with click and scroll actions.

## Stack

- Swift 5 / SwiftUI
- AppKit + CoreGraphics event taps
- Xcode project (`Dockmint.xcodeproj`)

## Common Commands

```bash
xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build
DOCKMINT_TEST_SUITE=1 "$(xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' 'BEGIN { dir = \"\" } /^[[:space:]]*BUILT_PRODUCTS_DIR = / { dir = $2 } /^[[:space:]]*EXECUTABLE_PATH = / { print dir \"/\" $2; exit }')"
swift tools/generate_icons.swift
./scripts/release.sh 0.0.1
```

## Release Rules

- Releases are tag-driven through `.github/workflows/release.yml`.
- Tag formats:
  - Stable: `vX.Y.Z`
  - Beta: `vX.Y.Z-beta.N`
- `Dockmint.xcodeproj` `MARKETING_VERSION` must match tag core version (`X.Y.Z`).
- `CHANGELOG.md` must contain a matching heading: `## [vX.Y.Z]` or `## [vX.Y.Z-beta.N]`.
- The Docktor to Dockmint release migration is complete. Keep runtime compatibility for legacy bundle IDs, URL schemes, defaults, installed-app detection, and Homebrew `zap` paths, but do not restore transition release feeds, artifacts, aliases, or workflow variables.
- Canonical tagged releases must run from `apotenza92/dockmint`; `./scripts/release.sh` validates the canonical origin before tagging.

## CI and Distribution

- `ci.yml`: manually invoked native ARM64 and Intel XCTest, unsigned stable/beta builds, decision-engine tests, and release-contract checks.
- `release.yml`: native signed + notarized ARM64/Intel artifacts, strict package verification, GitHub Release publishing, Sparkle feeds, and Homebrew tap sync.
- Release workflows are tag-push only. They stage an immutable draft, verify signatures and native N-1 Sparkle update behavior, then publish appcasts before validating and updating Homebrew.
- Beta tags run native updater gates for beta ARM64/x64 only. Stable tags run both stable and beta updater gates because a stable release can advance both feeds.
- The shell Settings and Dock suites require a logged-in Aqua session plus Accessibility/Input Monitoring grants, so they remain a required local pre-tag gate in `scripts/release.sh`; hosted CI owns XCTest and credential-free release-contract checks.
- `scripts/release/sparkle-update-bootstrap.json` is a source-pinned exception because the v0.4.1 packages predate the real update-test hook. Stable permits only v0.4.1 -> v0.4.2. Beta permits v0.4.1 -> v0.4.2-beta.1 when the prerelease ships first, or v0.4.1 -> v0.4.2 when the stable tag is the first Beta-feed advance. Those exact first transitions verify the candidate and its hook but cannot prove an install from v0.4.1; every later transition on that channel must install and relaunch from N-1. Never advance, broaden, or bypass this contract.
- Homebrew casks are updated in `apotenza92/homebrew-tap`:
  - `dockmint`
  - `dockmint@beta`
- Beta cask tracks whichever is newer between stable and prerelease channels.

## Release environments and credentials

- `release-signing`: protected P12 and App Store Connect P8 credentials used only by package jobs.
- `sparkle-signing`: tag-restricted, with the Sparkle private key used only by appcast-signing jobs.
- `release-policy`: tag-restricted, with only `IMMUTABLE_RELEASES_READ_TOKEN`, scoped to repository Administration read and used only by the read-only immutable-release policy job.
- `stable-release` and `beta-release`: secret-free controls used only by the final public-release job. Draft staging, updater verification, and appcast publication must not consume their approval gate.
- `homebrew-release`: Homebrew tap token and publication controls.

Environment secrets:

- `APPLE_SIGNING_CERTIFICATE_P12_BASE64`
- `APPLE_SIGNING_CERTIFICATE_PASSWORD`
- `APPLE_NOTARYTOOL_KEY_P8_BASE64`
- `SPARKLE_PRIVATE_ED_KEY`
- `HOMEBREW_TAP_TOKEN`
- `IMMUTABLE_RELEASES_READ_TOKEN`

Repository variables:

- `APPLE_NOTARYTOOL_KEY_ID`
- `APPLE_NOTARYTOOL_ISSUER_ID`
- `APPLE_SIGNING_CERTIFICATE_SHA256`
- `APPLE_PRIOR_SIGNING_CERTIFICATE_SHA256` (N-1 updater package only; retain the prior leaf fingerprint across certificate rotation)
- `APPLE_SIGNING_IDENTITY`
- `APPLE_TEAM_ID`

Release tags must resolve to commits reachable from the repository's `main` default branch.

## UI/Product Constraints

- Keep menu bar icon template-based and legible at 16-18pt.
- Settings window is the only user-facing window and should remain compact.
- No separate Mission Control action; App Expose is the only expose-style action.
