#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

LOG_FILE="/tmp/dockmint-app-expose-checks.log"

run_test_preflight true
capture_dock_state

cleanup() {
  stop_dockmint
  ensure_no_dockmint >/dev/null 2>&1 || true
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

echo "== app expose focused checks =="
set_dock_autohide false
set_window_tabbing_mode manual

single_target="$(builtin_single_window_dock_target || true)"
multi_target="$(builtin_multi_window_dock_target || true)"

if [[ -z "$single_target" || -z "$multi_target" ]]; then
  echo "error: expected Finder (1 window) and Safari (2+ windows) fixtures for App Exposé checks" >&2
  exit 1
fi

IFS='|' read -r single_icon single_process single_bundle <<<"$single_target"
IFS='|' read -r multi_icon multi_process multi_bundle <<<"$multi_target"

echo "  using 1-window app: $single_icon ($single_bundle)"
echo "  using 2+-window app: $multi_icon ($multi_bundle)"

echo "  multi-window target windows now: $(process_window_count "$multi_process")"

write_pref_string firstClickBehavior appExpose
write_pref_bool firstClickAppExposeRequiresMultipleWindows true
write_pref_bool showOnStartup false
write_pref_bool firstLaunchCompleted true

: >"$LOG_FILE"
start_dockmint "$LOG_FILE"
assert_dockmint_alive "$LOG_FILE" "app expose focused Dockmint process"
set_process_visible "$single_process" true
set_process_visible "$multi_process" true

# Default first click on a 1-window app should pass through to Dock activation.
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
assert_log_contains "firstClick appExpose skipped by multiple-window gate for $single_bundle" "first click on 1-window app passes through"

# Default first click on a 2+-window app should trigger App Exposé.
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
assert_log_contains "firstClick appExpose executing for $multi_bundle" "first click on 2+-window app opens App Exposé"

# Active-app single click should also trigger App Exposé on the shipped profile.
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
    echo "  PASS active click App Exposé observed"
    break
  fi
  if [[ "$attempt" -eq 2 ]]; then
    echo "  FAIL active click should trigger App Exposé"
    exit 1
  fi
done

stop_dockmint

echo "== app expose focused checks passed =="
