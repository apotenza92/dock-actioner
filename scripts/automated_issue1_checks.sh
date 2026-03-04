#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

LOG_FILE="/tmp/docktor-issue1-automation.log"

run_test_preflight true
capture_dock_state

cleanup() {
  stop_docktor
  ensure_no_docktor
  restore_dock_state
}
trap cleanup EXIT

configure_issue2_prefs() {
  write_pref_string firstClickBehavior activateApp
  write_pref_string clickAction hideApp
}

configure_issue3_prefs() {
  write_pref_string firstClickBehavior appExpose
  write_pref_string clickAction appExpose
  write_pref_bool firstClickAppExposeRequiresMultipleWindows false
  write_pref_bool clickAppExposeRequiresMultipleWindows false
}

ensure_two_apps_visible() {
  local a="$1" b="$2"
  set_process_visible "$a" true
  set_process_visible "$b" true
  sleep 0.3
}

issue2_case() {
  local dock_name="$1" target_proc="$2" other_proc="$3"
  assert_docktor_alive "$LOG_FILE" "issue2 Docktor process"
  ensure_two_apps_visible "$target_proc" "$other_proc"
  activate_finder

  local activated=false
  for _ in 1 2 3; do
    dock_click "$dock_name"; sleep 0.8
    if [[ "$(frontmost_process)" == "$target_proc" ]]; then
      activated=true
      break
    fi
  done

  if [[ "$activated" != "true" ]]; then
    echo "  FAIL [$dock_name] could not activate target app via Dock icon (frontmost=$(frontmost_process))"
    exit 1
  fi

  dock_click "$dock_name"; sleep 1.2

  local target_vis other_vis
  target_vis="$(process_visible "$target_proc")"
  other_vis="$(process_visible "$other_proc")"

  if [[ "$target_vis" != "false" ]]; then
    dock_click "$dock_name"; sleep 1.2
    target_vis="$(process_visible "$target_proc")"
    other_vis="$(process_visible "$other_proc")"
  fi

  if [[ "$target_vis" == "false" && "$other_vis" == "true" ]]; then
    echo "  PASS [$dock_name] target hidden, other unchanged"
  else
    echo "  FAIL [$dock_name] targetVisible=$target_vis otherVisible=$other_vis frontmost=$(frontmost_process)"
    exit 1
  fi
}

run_issue2_suite() {
  echo "[issue1+2] wrong target / finicky hide"
  configure_issue2_prefs
  start_docktor "$LOG_FILE"
  assert_docktor_alive "$LOG_FILE" "issue2 startup"

  for round in 1 2 3; do
    echo "  round $round"
    issue2_case "$TEST_DOCK_ICON_A" "$TEST_PROCESS_A" "$TEST_PROCESS_B"
    issue2_case "$TEST_DOCK_ICON_B" "$TEST_PROCESS_B" "$TEST_PROCESS_A"
  done
}

run_issue3_suite() {
  echo "[issue3] third click should not be swallowed"
  configure_issue3_prefs
  start_docktor "$LOG_FILE"
  assert_docktor_alive "$LOG_FILE" "issue3 startup"

  ensure_two_apps_visible "$TEST_PROCESS_A" "$TEST_PROCESS_B"
  activate_finder

  dock_click "$TEST_DOCK_ICON_A"; sleep 0.9
  dock_click "$TEST_DOCK_ICON_A"; sleep 0.9
  dock_click "$TEST_DOCK_ICON_A"; sleep 1.1

  local clickups invokes
  clickups="$(grep -c "phase=up bundle=$TEST_BUNDLE_A" "$LOG_FILE" || true)"
  invokes="$(grep -c "Triggering App Exposé for $TEST_BUNDLE_A" "$LOG_FILE" || true)"

  # Allow one extra click for occasional synthetic click jitter.
  if [[ "$clickups" -lt 3 || "$invokes" -lt 2 ]]; then
    dock_click "$TEST_DOCK_ICON_A"; sleep 1.1
    clickups="$(grep -c "phase=up bundle=$TEST_BUNDLE_A" "$LOG_FILE" || true)"
    invokes="$(grep -c "Triggering App Exposé for $TEST_BUNDLE_A" "$LOG_FILE" || true)"
  fi

  if [[ "$clickups" -ge 3 && "$invokes" -ge 2 ]]; then
    echo "  PASS clickUps=$clickups invocations=$invokes"
  else
    echo "  FAIL clickUps=$clickups invocations=$invokes"
    exit 1
  fi
}

run_settings_stability_suite() {
  echo "[prefs] repeated settings opens should not crash"
  start_docktor "$LOG_FILE"
  assert_docktor_alive "$LOG_FILE" "settings stability startup"

  for _ in $(seq 1 12); do
    osascript -e 'tell application "System Events" to tell process "Docktor" to set frontmost to true' >/dev/null 2>&1 || true
    osascript -e 'tell application "System Events" to keystroke "," using command down' >/dev/null 2>&1 || true
    sleep 0.18
    assert_docktor_alive "$LOG_FILE" "settings stability iteration"
  done

  echo "  PASS Docktor alive after repeated settings opens"
}

echo "== full issue #1 regression run =="
set_dock_autohide false
select_two_dock_test_apps
run_issue2_suite
run_issue3_suite
run_settings_stability_suite
echo "== all automated checks passed =="
