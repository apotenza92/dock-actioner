# Changelog

All notable changes to this project are documented in this file (stable and beta releases share this one changelog).

## [Unreleased]

- Ongoing development.

## [v0.0.7]

- Fixed first-click App Expose interception so when `>1 window only` is off, repeated first clicks on running apps continue dispatching App Expose instead of falling back to Dock activation.
- Added/validated automated first-click and App Expose re-entry regression coverage for this flow.

## [v0.0.6]

- Fixed App Expose re-entry handling so clicking a Dock icon after selecting a window from App Expose reliably triggers "Click after App activation" actions.
- Added a dedicated App Expose re-entry regression suite that reproduces picker-selection then same-icon re-click behavior and verifies App Expose dispatch.
- Hardened action test dispatch timing to avoid retry-induced toggle flakiness in `click hideOthers`.

## [v0.0.5]

- Updated defaults so first click (no modifier) uses App Expose with the "requires multiple windows" safeguard enabled.
- Updated "Reset mappings to defaults" to restore the same first-click App Expose behavior.

## [v0.0.4]

- Fixed first-click App Expose reliability by aligning click interception with down/up event pairs so Dock icons no longer get stuck pressed.
- Reworked App Expose activation flow to use a single-shot trigger with activation-state coordination, removing jumpy re-entry/cancel loops.
- Improved App Expose focus handoff so switching between apps while Expose is open correctly activates the newly selected app when exiting.
- Added a dedicated first-click App Expose automated suite that validates both dispatch and on-screen Expose evidence across repeated iterations.

## [v0.0.3]

- Added native Sparkle updater integration with an in-app "Check for Updates" flow and configurable update check frequency in Settings.
- Added signed Sparkle appcasts for stable/beta and arm64/x64, with release automation that regenerates and publishes appcasts from GitHub releases.
- Unified release notes to a single `CHANGELOG.md` source used by both GitHub Releases and Sparkle update descriptions.
- Improved first-run permission prompting for Accessibility and Input Monitoring and refreshed the compact settings layout with a table-based mapping editor.
- Added a no-op (`-`) action option, updated modifier defaults (`Shift+Click` -> Bring All to Front), and a "Reset mappings to defaults" control.

## [v0.0.2]

- Added full per-modifier action mapping with a table-style settings UI and new Single App Mode action.
- Fixed Preferences opening from the status menu and simplified menu actions to Preferences + Quit.
- Refined app and status-bar iconography, including a separate beta app icon set and larger menu bar glyph.
- Added side-by-side beta distribution support (`DockActioner Beta.app`) across CI, release packaging, and Homebrew casks.

## [v0.0.1]

- Added Dock notification based App Expose triggering for reliable behavior.
- Updated defaults: click -> App Expose, scroll down -> Hide App.
- Refined settings UI layout and removed diagnostics from standard settings surface.
- Added tag-driven release automation with signing, notarization, and Homebrew tap updates.
