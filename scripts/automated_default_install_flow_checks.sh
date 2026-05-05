#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

LOG_FILE="/tmp/dockmint-default-install-flow.log"
DEFAULT_DOCK_FOLDER_ACTION="dock|automatic|none|none|current|current|current"
DEFAULT_FINDER_FOLDER_ACTION="com.apple.finder|automatic|none|none|current|current|current"
RELEASE_BUNDLE_ID="pzc.Dockmint"
ORIG_RELEASE_SHOW_ON_STARTUP="__missing__"
ORIG_RELEASE_CLICK_ACTION="__missing__"

run_test_preflight true
capture_dock_state
ensure_no_dockmint

cleanup() {
  stop_dockmint
  ensure_no_dockmint >/dev/null 2>&1 || true

  if [[ "$ORIG_RELEASE_SHOW_ON_STARTUP" == "__missing__" ]]; then
    defaults delete "$RELEASE_BUNDLE_ID" showOnStartup >/dev/null 2>&1 || true
  else
    defaults write "$RELEASE_BUNDLE_ID" showOnStartup -bool "$ORIG_RELEASE_SHOW_ON_STARTUP" >/dev/null 2>&1 || true
  fi

  if [[ "$ORIG_RELEASE_CLICK_ACTION" == "__missing__" ]]; then
    defaults delete "$RELEASE_BUNDLE_ID" clickAction >/dev/null 2>&1 || true
  else
    defaults write "$RELEASE_BUNDLE_ID" clickAction -string "$ORIG_RELEASE_CLICK_ACTION" >/dev/null 2>&1 || true
  fi

  restore_window_tabbing_mode >/dev/null 2>&1 || true
  restore_dock_state >/dev/null 2>&1 || true
}
trap cleanup EXIT

assert_log_contains() {
  local needle="$1"
  local label="$2"
  if wait_for_log_contains "$needle" "$LOG_FILE" 4; then
    echo "  PASS $label"
  else
    echo "  FAIL $label"
    echo "  expected log: $needle"
    exit 1
  fi
}

activate_process_direct() {
  local process_name="$1"
  osascript -e "tell application \"$process_name\" to activate" >/dev/null 2>&1 || true
}

retry_on_dock_context_menu() {
  local icon_name="$1"
  local label="$2"
  if dock_item_menu_is_open "$icon_name"; then
    echo "  WARN $label observed Dock context menu during automation; dismissing and retrying"
    capture_gui_failure_artifacts "dock-context-menu-${label//[^[:alnum:]-]/-}" "$LOG_FILE" >/dev/null 2>&1 || true
    capture_dock_icon_snapshot "$icon_name" "dock-context-menu-${label//[^[:alnum:]-]/-}-icon" >/dev/null 2>&1 || true
    dismiss_dock_item_context_menu "$icon_name" >/dev/null 2>&1 || true
    sleep 0.35
    return 0
  fi
  return 1
}

read_pref_string() {
  local key="$1"
  defaults read "$BUNDLE_ID" "$key" 2>/dev/null || echo "__missing__"
}

assert_pref_equals() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(read_pref_string "$key")"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS pref $key=$expected"
  else
    echo "  FAIL pref $key expected '$expected' got '$actual'"
    exit 1
  fi
}

echo "== default install flow checks =="
set_dock_autohide false
set_window_tabbing_mode manual

defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
ORIG_RELEASE_SHOW_ON_STARTUP="$(defaults read "$RELEASE_BUNDLE_ID" showOnStartup 2>/dev/null || echo "__missing__")"
ORIG_RELEASE_CLICK_ACTION="$(defaults read "$RELEASE_BUNDLE_ID" clickAction 2>/dev/null || echo "__missing__")"
defaults write "$RELEASE_BUNDLE_ID" showOnStartup -bool true
defaults write "$RELEASE_BUNDLE_ID" clickAction -string hideApp
start_dockmint "$LOG_FILE"
assert_dockmint_alive "$LOG_FILE" "default-install Dockmint process"
assert_log_contains "Opening settings window explicit=false onboardingIncomplete=true" "first launch opens onboarding"
assert_pref_equals firstLaunchCompleted 0
assert_pref_equals onboardingState notStarted
assert_pref_equals showMenuBarIcon 1
assert_pref_equals showOnStartup 0
assert_pref_equals backgroundUpdateChecksEnabled 1
assert_pref_equals updateCheckFrequency weekly
assert_pref_equals clickAction none
assert_pref_equals firstClickBehavior appExpose
assert_pref_equals firstClickShiftAction hideOthers
assert_pref_equals firstClickOptionAction singleAppMode
assert_pref_equals firstClickShiftOptionAction quitApp
if [[ "$(defaults read "$RELEASE_BUNDLE_ID" showOnStartup 2>/dev/null || echo "__missing__")" != "1" ]]; then
  echo "  FAIL expected release defaults domain to remain unchanged while validating dev isolation"
  exit 1
fi
if [[ "$(defaults read "$RELEASE_BUNDLE_ID" clickAction 2>/dev/null || echo "__missing__")" != "hideApp" ]]; then
  echo "  FAIL expected release defaults domain clickAction to remain unchanged while validating dev isolation"
  exit 1
fi
if [[ "$(defaults read "$BUNDLE_ID" dockmintDefaultsDomainMigrated_v1 2>/dev/null || echo "__missing__")" != "__missing__" ]]; then
  echo "  FAIL expected dev install flow to avoid legacy defaults-domain migration"
  exit 1
fi
assert_pref_equals scrollUpAction appExpose
assert_pref_equals scrollDownAction appExpose
assert_pref_equals folderClickAction "$DEFAULT_DOCK_FOLDER_ACTION"
assert_pref_equals optionFolderClickAction "$DEFAULT_FINDER_FOLDER_ACTION"
stop_dockmint

write_pref_bool firstLaunchCompleted true
write_pref_string onboardingState completed

single_target="$(builtin_single_window_dock_target || true)"
multi_target="$(builtin_multi_window_dock_target || true)"

if [[ -z "$single_target" ]]; then
  echo "  FAIL could not prepare Finder as the 1-window Dock target"
  exit 1
fi
if [[ -z "$multi_target" ]]; then
  echo "  FAIL could not prepare Safari as the multi-window Dock target"
  exit 1
fi

IFS='|' read -r single_icon single_process single_bundle <<<"$single_target"
IFS='|' read -r multi_icon multi_process multi_bundle <<<"$multi_target"

echo "  using 1-window app: $single_icon ($single_bundle)"
echo "  using 2+-window app: $multi_icon ($multi_bundle)"

echo "  multi-window target windows now: $(process_window_count "$multi_process")"

: >"$LOG_FILE"
start_dockmint "$LOG_FILE"
assert_dockmint_alive "$LOG_FILE" "default-install interaction Dockmint process"

for attempt in 1 2; do
  activate_finder
  sleep 0.6
  dock_click_with_hold "$single_icon" 220
  sleep 0.4
  if retry_on_dock_context_menu "$single_icon" "${single_bundle}-single-window-first-click-attempt-${attempt}"; then
    [[ "$attempt" -lt 2 ]] || { echo "  FAIL single-window first click opened Dock context menu twice"; exit 1; }
    continue
  fi
  break
done
assert_log_contains "firstClick appExpose skipped by shouldRunFirstClickAppExpose for $single_bundle" "plain first click on 1-window app passes through"

for attempt in 1 2; do
  activate_finder
  sleep 0.6
  dock_click_with_hold "$multi_icon" 220
  sleep 0.5
  if retry_on_dock_context_menu "$multi_icon" "${multi_bundle}-inactive-first-click-attempt-${attempt}"; then
    [[ "$attempt" -lt 2 ]] || { echo "  FAIL inactive first click opened Dock context menu twice"; exit 1; }
    continue
  fi
  break
done
assert_log_contains "firstClick appExpose executing for $multi_bundle" "plain first click on 2-window app opens App Exposé"

for attempt in 1 2; do
  activate_process_direct "$multi_process"
  sleep 0.8
  before_active="$(grep -Fc "WORKFLOW: Triggering App Exposé for $multi_bundle" "$LOG_FILE" 2>/dev/null || true)"
  dock_click_with_hold "$multi_icon" 220
  sleep 1.0
  if retry_on_dock_context_menu "$multi_icon" "${multi_bundle}-active-single-click-attempt-${attempt}"; then
    [[ "$attempt" -lt 2 ]] || { echo "  FAIL active single click opened Dock context menu twice"; exit 1; }
    continue
  fi
  after_active="$(grep -Fc "WORKFLOW: Triggering App Exposé for $multi_bundle" "$LOG_FILE" 2>/dev/null || true)"
  if (( after_active > before_active )); then
    echo "  PASS active click opens App Exposé"
    break
  fi
  if [[ "$attempt" -eq 2 ]]; then
    echo "  FAIL active click should open App Exposé"
    exit 1
  fi
done

assert_pref_equals scrollUpAction appExpose
assert_pref_equals scrollDownAction appExpose
assert_pref_equals folderClickAction "$DEFAULT_DOCK_FOLDER_ACTION"
assert_pref_equals optionFolderClickAction "$DEFAULT_FINDER_FOLDER_ACTION"

stop_dockmint

echo "== default install flow checks passed =="
