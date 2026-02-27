# Changelog

All notable changes to this project are documented in this file (stable and beta releases share this one changelog).

## [Unreleased]

- Ongoing development.

## [v0.0.20]

- Reworked the top settings layout into three columns (`General`, `Updates`, `Permissions`) with updated control grouping and wording, including `Active App Click` in the mappings table header.
- Switched permission info indicators to native macOS help tooltips on the `(i)` controls, with a larger hover target and faster tooltip reveal timing.
- Improved settings-window behavior by centering first-open placement and persisting/restoring the window frame across launches/updates.
- Added Debug-build guardrails for local testing: disable Sparkle update checks and force menu bar icon visibility/startup settings on.

## [v0.0.19]

- Fixed synthetic Dock click recovery so it no longer posts mouse-up events at offscreen coordinates, preventing visible pointer jumps during actions like `Option+Click` Single App Mode.

## [v0.0.18]

- Replaced SwiftUI `MenuBarExtra` settings routing with an AppKit `NSStatusItem` menu controller to eliminate status-menu reentrancy issues.
- Replaced responder-chain settings opening (`showSettingsWindow:` / `showPreferencesWindow:`) with a dedicated AppKit `NSWindowController` hosting the existing SwiftUI preferences view.
- Fixed a severe post-click CPU runaway (up to 100%) triggered by opening `Settings…` from the menu bar icon on some machines.
- Validated with real pointer clicks (`cliclick`) in repeated menu open flows, including 30-iteration open/click-inside-controls/close stress with no crashes and no high-CPU runaway.

## [v0.0.17]

- Fixed a settings-open crash in the SwiftUI menu flow by removing a recursive `showSettingsWindow:` bridge path in `AppDelegate`.
- Kept settings routing on system actions only (`showSettingsWindow:` / `showPreferencesWindow:`), avoiding self-targeted responder recursion.
- Re-validated settings stability for launch-argument open, URL open, repeated `Cmd+,`, and status-menu `Settings…` clicks.

## [v0.0.16]

- Switched menu-bar settings action to SwiftUI `SettingsLink` on macOS 14+.
- Removed custom fallback settings window presentation and routed settings opening through system settings actions only.
- Bumped deployment target to macOS 14.0 to support the native SwiftUI settings-link flow.
- Verified settings stability with repeated open checks (`Cmd+,`) and settings shell automation.

## [v0.0.15]

- Reworked the menu-bar shell to SwiftUI `MenuBarExtra` and standardized wording to `Settings…`.
- Added menu icon visibility toggle with lockout protection (`showOnStartup` auto-enable when icon is hidden).
- Added settings fail-safes: launch arguments (`--settings`/aliases) and URL handlers (`docktor://settings`, `dockter://settings`).
- Hardened Dock click/App Exposé decision flow and hide behavior reliability for issue #1 regressions.
- Added `DockDecisionEngine` extraction, XCTest target/scheme support, and expanded automated regression scripts.

## [v0.0.14]

- Fixed menu-bar `Preferences…` opening reliability by using a resilient multi-path action handler (`showSettingsWindow:` -> `showPreferencesWindow:` -> in-app fallback window).

## [v0.0.13]

- Fixed status-bar `Preferences…` action routing to use the standard Settings responder path, preventing crashes when opening settings from the menu bar icon.
- Improved Dock click target reliability by re-resolving the Dock icon bundle on mouse-up before executing actions.
- Hardened `Hide App` execution with post-hide verification and fallback paths, fixing intermittent active-app hide behavior.
- Reduced App Exposé state false-positives and removed swallowed-click/third-click no-op regressions in repeated Dock interactions.

## [v0.0.12]

- Split App Expose gating into two independent `>1 window only` settings: one for `First Click` and one for `Active App` (click-after-activation).
- Updated the mappings table UI to surface and center the separate toggles only when each corresponding action is set to `App Expose`.
- Updated README defaults/behavior notes to reflect independent App Expose gating controls.

## [v0.0.11]

- Reduced accidental scroll double-toggles by adding a cooldown guard for toggle-style scroll actions (`Hide App`, `Hide Others`, and `Single App Mode`).

## [v0.0.10]

- Renamed the product, project, release workflows, scripts, and repository from `Dockter` to `Docktor`.
- Kept existing bundle identifiers (`pzc.Dockter` / `pzc.Dockter.beta`) so existing Sparkle users continue to upgrade in place.
- Added launch-time migration that renames legacy installs (`DockActioner.app` and `Dockter.app`) to `Docktor.app` in `/Applications`.
- Updated release automation and Sparkle appcast tooling for the new repository slug and `Docktor` artifact/cask names.

## [v0.0.9]

- Fixed Single App Mode so switching apps hides only the app you are leaving, then shows/activates the app you click.
- Extended the `>1 window only` App Expose preference to also apply to the "Click after App activation" App Expose path.
- Fixed Brave vertical-tabs compatibility so sidebar/auxiliary panes are excluded from window counts used by first-click App Expose and `>1 window only`.
- Improved first-click App Expose fallback behavior and tracing around mouse-down/up window-state decisions.
- Simplified settings-window presentation to use the fallback preferences window path directly.
- Simplified and refreshed README documentation, including the app icon and streamlined install/build/release guidance.
- Updated CI workflow references from legacy `DockActioner` names to `Docktor` project/scheme/product identifiers.

## [v0.0.8]

- Added a focused App Expose cartesian harness profile (Finder + TextEdit) with machine-readable artifacts and deterministic scenario IDs for gate/cancel reliability testing.
- Hardened Dock click targeting in cartesian runs with cached/revalidated icon points and per-click down/up bundle probes to distinguish hit-test misses from trigger failures.
- Fixed negative-space cancel tracking reset so consumed/non-Dock clicks clear App Expose tracking state correctly and reduce stuck cancel flows.
- Added recovery for consumed click-up paths by posting passthrough synthetic mouse-up events, reducing Dock icons getting visually stuck in a pressed/greyed state.

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
- Added side-by-side beta distribution support (`Docktor Beta.app`) across CI, release packaging, and Homebrew casks.

## [v0.0.1]

- Added Dock notification based App Expose triggering for reliable behavior.
- Updated defaults: click -> App Expose, scroll down -> Hide App.
- Refined settings UI layout and removed diagnostics from standard settings surface.
- Added tag-driven release automation with signing, notarization, and Homebrew tap updates.
