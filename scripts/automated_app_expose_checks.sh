#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

LOG_FILE="/tmp/docktor-app-expose-checks.log"

run_test_preflight true
capture_dock_state

cleanup() {
  stop_docktor
  ensure_no_docktor
  restore_dock_state
}
trap cleanup EXIT

assert_log_contains() {
  local needle="$1"
  local label="$2"
  if grep -q "$needle" "$LOG_FILE"; then
    echo "  PASS $label"
  else
    echo "  FAIL $label"
    echo "  expected log: $needle"
    exit 1
  fi
}

activate_target_app_from_dock() {
  local activated=false
  for _ in 1 2 3; do
    dock_click "$TEST_DOCK_ICON_A"
    sleep 0.8
    if [[ "$(frontmost_process)" == "$TEST_PROCESS_A" ]]; then
      activated=true
      break
    fi
  done

  if [[ "$activated" != "true" ]]; then
    echo "  FAIL unable to activate target app '$TEST_DOCK_ICON_A'"
    exit 1
  fi
}

echo "== app expose focused checks =="
set_dock_autohide false
select_two_dock_test_apps

echo "[scenario1] first-click gate (>1 windows)"
write_pref_string firstClickBehavior appExpose
write_pref_bool firstClickAppExposeRequiresMultipleWindows true
write_pref_string clickAction none
start_docktor "$LOG_FILE"
assert_docktor_alive "$LOG_FILE" "scenario1 Docktor process"
set_process_visible "$TEST_PROCESS_A" true
set_process_visible "$TEST_PROCESS_B" true
activate_finder
windows_before="$(process_window_count "$TEST_PROCESS_A")"
dock_click "$TEST_DOCK_ICON_A"
sleep 1.2
stop_docktor
if [[ "$windows_before" =~ ^[0-9]+$ ]] && (( windows_before < 2 )); then
  assert_log_contains "firstClick appExpose skipped by shouldRunFirstClickAppExpose for $TEST_BUNDLE_A" "first-click app expose gate honored"
else
  assert_log_contains "firstClick appExpose executing for $TEST_BUNDLE_A" "first-click app expose executes when window count allows"
fi

echo "[scenario2] active-app click gate (>1 windows)"
write_pref_string firstClickBehavior activateApp
write_pref_string clickAction appExpose
write_pref_bool clickAppExposeRequiresMultipleWindows true
start_docktor "$LOG_FILE"
assert_docktor_alive "$LOG_FILE" "scenario2 Docktor process"
set_process_visible "$TEST_PROCESS_A" true
set_process_visible "$TEST_PROCESS_B" true
activate_finder
activate_target_app_from_dock
windows_active="$(process_window_count "$TEST_PROCESS_A")"
dock_click "$TEST_DOCK_ICON_A"
sleep 1.2
stop_docktor
if [[ "$windows_active" =~ ^[0-9]+$ ]] && (( windows_active < 2 )); then
  assert_log_contains "click appExpose skipped for $TEST_BUNDLE_A" "active-app app expose gate honored"
else
  assert_log_contains "Triggering App Exposé for $TEST_BUNDLE_A" "active-app app expose executes when window count allows"
fi

echo "[scenario3] active-app click triggers when gate disabled"
write_pref_string firstClickBehavior activateApp
write_pref_string clickAction appExpose
write_pref_bool clickAppExposeRequiresMultipleWindows false
start_docktor "$LOG_FILE"
assert_docktor_alive "$LOG_FILE" "scenario3 Docktor process"
set_process_visible "$TEST_PROCESS_A" true
set_process_visible "$TEST_PROCESS_B" true
activate_finder
activate_target_app_from_dock
dock_click "$TEST_DOCK_ICON_A"
sleep 1.2
stop_docktor
assert_log_contains "Triggering App Exposé for $TEST_BUNDLE_A" "active-app app expose invocation observed"

echo "== app expose focused checks passed =="
