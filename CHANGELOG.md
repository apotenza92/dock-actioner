# Changelog

All notable changes to this project are documented in this file (stable and beta releases share this one changelog).

## [Unreleased]

- Ongoing development.
- Added a documented multi-release Docktor -> Dockmint rollout runbook plus release-time validation for migration phase, legacy appcast mirroring, and canonical `apotenza92/dockmint` release origin checks.

## [v0.2.3]

- Cut over the shipped stable and beta app identities to the final Dockmint bundle identifiers, `pzc.Dockmint` and `pzc.Dockmint.beta`, while keeping one overlap release of legacy Docktor feed mirroring and Homebrew aliases for existing installs.
- Switched cleanup-phase packaged update feeds to the canonical `apotenza92/dockmint` appcasts so post-migration Dockmint builds no longer point at the legacy Docktor repository.
- Fixed GitHub release appcast signing to use Sparkle's native `sign_update` tool, restoring compatibility with legacy exported Sparkle signing-key formats during automated releases.

## [v0.2.2]

- Published the Dockmint stable transition release so existing `Docktor` installs can update in place to Dockmint branding before the later bundle-identifier cleanup release.
- Kept stable and beta updater continuity on the legacy `Docktor` Sparkle feed while allowing beta users to converge back onto the newer stable release when no newer beta is available.
- Updated the download page stable theme colors to match the current Dockmint app icon palette.

## [v0.2.2-beta.2]

- Reissued the Dockmint beta as the planned transition build so existing `Docktor Beta` installs can upgrade in place before the later bundle-identifier cleanup release.
- Kept the Dockmint branding and beta release channel while restoring update compatibility for legacy `pzc.Dockter.beta` installs.
- Corrected the GitHub release configuration to use the original Dockmint Sparkle signing key for future appcast publication.

## [v0.2.2-beta.1]

- Restored Dockmint beta release continuity after the repository rename by publishing the beta channel from the live `apotenza92/dockmint` repo and aligning release metadata with Dockmint bundle/update paths.
- Fixed updater continuity for Dockmint installs so beta appcasts and release downloads resolve under the Dockmint repo instead of dead pre-rename URLs.
- Simplified the app icon and menu bar icon back to the plain Lucide leaf geometry to remove the flipped/skewed leaf rendering.

## [v0.2.1]

- Polished the single-window Settings layout with tighter top-column balancing, clearer section hierarchy, compact permissions rows, and action-table sizing tweaks that remove truncation in common controls.
- Cleaned up update messaging in Settings by showing the short version only and mapping Sparkle "no update found" and cancelled checks to user-friendly status text.
- Restricted duplicate-instance termination to Debug builds so release builds no longer interfere with Sparkle relaunch/update flows.

## [v0.2.0]

- Redesigned Settings into a single compact scrollable window with inline section headers, right-aligned reset actions, richer update status text, and expanded Folder Actions controls.
- Added configurable folder-stack click and scroll actions, including Dock passthrough, Finder opening with view/group/sort options, and custom “Open With” app targets with async app-list warming.
- Improved settings responsiveness with instrumented internal timing logs, fixed pane sizing, shared settings services, and a local benchmark harness for reproducible settings timing runs.
- Hardened Dock hit testing and gesture routing with folder Dock item detection, alternate-axis scroll handling, and drag-path changes that preserve native Dock drag/reorder/drop behavior while reducing drag-start stutter.
- Improved launch/runtime robustness across Docktor-family installs, update-state reporting, and macOS 14 compatibility by removing deprecated activation calls and tightening main-actor isolation around workspace/private-window APIs.
- Added coverage and tooling updates for the new Dock hit-test and scroll decision paths, plus Xcode-aware Debug app resolution in shared test helpers and developer docs.

## [v0.1.2]

- Fixed modifier-click timing so modifier double-click actions no longer get swallowed by the first modifier click, while single-click modifier actions still execute correctly after the system double-click interval.
- Restored reliable modifier toggle behavior for `Hide Others` and `Hide App`, including second-click undo/show-all handling and target-only unhide for `Hide App`.
- Added `scripts/automated_modifier_toggle_checks.sh` to cover real Dock GUI regressions for modifier single-click and double-click action interactions.

## [v0.1.1]

- Added a public macOS download page with stable/beta channel switching, Apple Silicon/Intel selection, direct GitHub release downloads, and matching Homebrew install commands.
- Refreshed project marketing across the download page, README, and GitHub metadata to describe Docktor as customizable Dock click, double-click, and scroll actions, including the shipped default of double click opening App Exposé to show an app's open windows.
- Updated the download page branding so stable/beta copy, icon swapping, and icon-derived accent colors stay aligned with the selected channel.

## [v0.1.0]

- Fixed the default `activateApp -> active-app action` double-click path for `Hide App`, `Hide Others`, `Single App Mode`, `Minimize All`, and `Quit App`, including Mail-specific hide fallback handling and stale first-click recovery.
- Clarified the README defaults so the intended baseline behavior is “double click an app icon to open App Expose” for that app.
- Added broader Dock-click regression coverage, including the new active-click soak runner plus harness fixes for pinned fixtures, repeated `minimizeAll` setup, and stable fixture-pool pair selection.

## [v0.0.39]

- Changed the shipped defaults so `Show menu bar icon` starts enabled, `Show settings on startup` stays off after the first run, and `Start Docktor Beta at login` remains off by default.
- Removed the development-only preference overrides that forced the menu bar icon and startup settings window on, so local builds now match the shipped app behavior.
- Added a settings-shell regression that verifies first launch opens settings once and subsequent launches stay closed when `showOnStartup` is disabled.

## [v0.0.38-beta.1]

- Fixed beta branding so the settings window, status item accessibility label, and menu item labels use the bundle product name consistently (`Docktor Beta` for beta builds).
- Updated remaining settings copy that referenced the stable app name so beta builds no longer show mixed `Docktor`/`Docktor Beta` strings.

## [v0.0.38]

- Fixed settings-window and menu bar labeling to use the bundle product name consistently, so beta builds show `Docktor Beta` instead of mixed stable/beta naming.
- Updated remaining settings copy that referenced the stable app name so beta builds no longer show mixed `Docktor`/`Docktor Beta` strings.

## [v0.0.37]

- Fixed default active-app App Exposé bounce-out by removing mouse-down pre-triggering and enforcing mouse-up pass-through trigger ordering.
- Added rapid second-click promotion logic for default `first click = Activate App` flows so quick double-clicks can still execute mapped active-click actions (including App Exposé) using macOS double-click timing.
- Added and hardened double-click regression harnesses (`automated_default_active_app_expose_double_click.sh`, `automated_default_active_click_double_click_generic.sh`) plus shared click-hold support in `scripts/lib/test_common.sh`.

## [v0.0.36]

- Fixed intermittent Dock icon hang/context-menu regressions on the default `activateApp -> active-app App Exposé` path by hardening click lifecycle recovery in `DockExposeCoordinator` and `DockClickEventTap`.
- Added explicit stale Exposé tracking expiry/cleanup and deferred active-click `App Exposé` triggering safeguards to prevent collapsed or missed invokes during repeated cycles.
- Added `scripts/automated_default_active_app_expose_stress.sh` for deterministic real Dock-click stress validation of the default active-app App Exposé workflow.

## [v0.0.35]

- Fixed an App Exposé regression where the active-app second-click transition could begin and then immediately collapse again because Dock pressed-state recovery posted a synthetic release into the Exposé animation window.
- Tightened the local multi-Space App Exposé harness so it re-establishes the active-app precondition without reintroducing a focus race before the second click.

## [v0.0.34]

- Added Space-aware AX/CG window filtering for window actions, including private window-to-Space lookup and stronger AX-to-CG window identity matching for current-Space `Minimize All` and `Bring All to Front`.
- Fixed active-app second-click consistency for `Hide App`, `Hide Others`, `Minimize All`, and `Quit App`, including preventing Dock release recovery from relaunching apps after `Quit App`.
- Hardened the local regression harnesses for settings and multi-Space Brave checks so release validation covers the new active-app and cross-Space behavior more reliably.

## [v0.0.33]

- Fixed the menu bar icon rendering path to redraw as a template image per display scale, so the glyph stays sharp when moving between non-Retina external displays and Retina MacBook panels.

## [v0.0.32]

- Improved mixed-device scroll direction resolution by preferring AppKit-interpreted deltas (what apps actually receive) and adding conflict handling for disagreeing CGEvent scroll fields.
- Added `scripts/automated_scroll_direction_checks.sh` for deterministic GUI-level scroll routing checks (discrete + continuous events on real Dock icon targets), and wired it into `scripts/run_all_checks.sh`.
- Improved automatic mixed-device handling: discrete mouse-wheel routing now auto-inverts when remapper heuristics (e.g. Mos/LinearMouse/UnnaturalScrollWheels detection) indicate mouse-only direction remapping, while trackpad/Magic Mouse routing remains unchanged.
- Fixed issue #1 follow-up: prevented delayed Dock context-menu popups after second-click `Minimize All` by using action-aware pressed-state recovery for consumed minimize clicks.

## [v0.0.31]

- Refreshed automation reliability to prevent opaque "operation aborted" runs: shared preflight checks, dynamic Debug app discovery, deterministic app selection, and explicit startup/readiness health checks in `scripts/lib/test_common.sh`.
- Hardened App Exposé runtime state handling under rapid churn by confirming invocation evidence before committing tracking state, plus explicit rollback/reset when invocation is unconfirmed.
- Improved event-tap timeout recovery and reduced debug logging pressure to avoid stale/latching interaction state after tap timeout conditions.

## [v0.0.30]

- Fixed Sparkle feed URL injection for packaged builds by parameterizing `SUFeedURL` in `Docktor/Info.plist` (`$(SU_FEED_URL)`) and overriding it per release matrix entry.
- Beta artifacts now embed the Beta appcast URL directly (`beta-arm64` / `beta-x64`), ensuring Beta users receive the Beta track (which already advances to newer stable versions when they surpass prereleases).

## [v0.0.29]

- Fixed release packaging so Sparkle feed URLs are channel+architecture-specific at build time (`stable-arm64`, `stable-x64`, `beta-arm64`, `beta-x64`) instead of a single hardcoded stable feed.
- Ensured Beta app builds consistently follow the Beta appcast track, which already promotes newer stable releases when they are newer than prereleases.

## [v0.0.28]

- Fixed App Exposé state cleanup after dismiss so switching to a different app from the Dock works on the first click instead of intermittently requiring a second click.
- Hardened first-click `Activate App` pass-through by asserting Dock-driven activation when needed, improving reliability after App Exposé close/dismiss flows.

## [v0.0.27]

- Fixed a Sparkle relaunch regression where `Install and Relaunch` could fail to reopen the app if a Finder-style relaunch (`-psn_`) was incorrectly treated as a settings-handoff launch.
- Restricted running-instance settings handoff to explicit `--settings` launches only, while preserving "click app icon to open Settings" behavior for normal Finder/Dock launches.

## [v0.0.26]

- Restored settings discoverability for background-only launches: opening Docktor from Applications/Dock now reliably opens the settings window, including when another Docktor instance is already running.
- Added a running-instance handoff for explicit settings opens so duplicate launches request settings in the existing process, then exit cleanly.
- Auto-restores menu bar icon visibility when settings are explicitly requested (reopen/URL/Finder launch), so users always have a visible way back to settings.

## [v0.0.25]

- Fixed mixed-device scroll direction handling by preferring discrete wheel delta fields for non-continuous mouse events, improving compatibility with per-device remappers like UnnaturalScrollWheels.

## [v0.0.24]

- Reduced rapid App Exposé double-click conflicts by consuming immediate no-window follow-up clicks after first-click activation.
- Matched the no-window App Exposé suppression grace to macOS `NSEvent.doubleClickInterval` for user-consistent timing.
- Added a tiny App Exposé dismiss grace window to avoid accidental instant dismiss on ultra-fast repeat clicks.

## [v0.0.24-beta.1]

- Reduced rapid App Exposé double-click conflicts by consuming immediate no-window follow-up clicks after first-click activation.
- Matched the no-window App Exposé suppression grace to macOS `NSEvent.doubleClickInterval` for user-consistent timing.
- Added a tiny App Exposé dismiss grace window to avoid accidental instant dismiss on ultra-fast repeat clicks.

## [v0.0.23]

- Updated defaults: first click now defaults to `Activate App`, while active-app click stays `App Exposé` with `>1 window only` OFF by default.
- Simplified the action table UI by moving App Exposé gating into picker options (`App Exposé` / `App Exposé (>1 window only)`) for all slots and returning the table to single-row cells.
- Improved scroll direction handling to follow effective per-device event direction (including remappers like LinearMouse) instead of global-only natural-scroll preference.
- Added a GitHub mark button next to `About` in settings and refreshed README default-behavior documentation.
- Standardized Hide toggles so re-running `Hide App` or `Hide Others` now undoes hidden state via `Show All`.

## [v0.0.22]

- Restored first-click default/reset behavior to `App Exposé`.
- Added compatibility migration + legacy fallback seeding for per-slot App Exposé `>1 window only` gates (from legacy first-click/active-click preferences).
- Aligned scroll up/down routing with macOS Natural vs Standard scrolling mode and added unit coverage for both mappings.
- Hardened settings shell automation with menu-bar count wait/retry and made `scripts/release.sh` run required pre-tag validation by default (waiver now requires an issue reference).

## [v0.0.21]

- Fixed Allen-reported Dock regression cases: wrong-target/finicky `Hide App` behavior and swallowed third click during repeated App Exposé clicks.
- Added per-slot `>1 window only` App Exposé gating for modifier rows and scroll mappings, with matching settings UI toggles and preference persistence.
- Hardened App Exposé click-path state handling when the clicked app is already active while Exposé tracking is in progress.

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
