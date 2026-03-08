#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

# Local-only regression harness for Docktor active-app second-click behavior when
# the target app has windows spread across multiple Spaces.
#
# Required desktop layout before running:
#   Desktop 1: control space; Finder should be able to become frontmost here.
#   Desktop 2: target app window A.
#   Desktop 3: target app window B.
#
# Defaults target Brave, but can be overridden:
#   MULTI_SPACE_TARGET_DOCK_ICON="Brave Browser"
#   MULTI_SPACE_TARGET_PROCESS="Brave Browser"
#   MULTI_SPACE_TARGET_BUNDLE="com.brave.Browser"
#   MULTI_SPACE_CONTROL_SPACE=1
#   MULTI_SPACE_APP_SPACE_A=2
#   MULTI_SPACE_APP_SPACE_B=3
#   TEST_ARTIFACT_ROOT=/tmp/docktor-artifacts

LOG_FILE=""
RUN_LOG_FILE=""
PREF_BACKUP=""
ARTIFACT_NOTES=""
CURRENT_LOG_LABEL=""
CURRENT_LOG_MERGED=true
CHECKLIST_PATH=""
TOTAL_FAILURES=0
CURRENT_SCENARIO_ID=""
CURRENT_SCENARIO_ACTION=""
CURRENT_SCENARIO_ASSERTION_MODE=""

backup_preferences() {
  local output="$1"
  defaults export "$BUNDLE_ID" - >"$output" 2>/dev/null || true
}

restore_preferences() {
  local backup_file="$1"
  if [[ -s "$backup_file" ]]; then
    defaults import "$BUNDLE_ID" "$backup_file" >/dev/null 2>&1 || true
  fi
}

append_note() {
  local line="$1"
  printf '%s\n' "$line" >>"$ARTIFACT_NOTES"
}

merge_current_log() {
  if [[ -z "${LOG_FILE:-}" || -z "${RUN_LOG_FILE:-}" || "${CURRENT_LOG_MERGED:-true}" == "true" ]]; then
    return 0
  fi
  if [[ -f "$LOG_FILE" ]]; then
    {
      printf '\n===== %s =====\n' "${CURRENT_LOG_LABEL:-scenario}"
      cat "$LOG_FILE"
    } >>"$RUN_LOG_FILE"
  fi
  CURRENT_LOG_MERGED=true
}

restart_docktor_for_scenario() {
  local scenario_label="$1"
  merge_current_log
  stop_docktor
  LOG_FILE="$(artifact_path "${scenario_label}-docktor" "log")"
  CURRENT_LOG_LABEL="$scenario_label"
  CURRENT_LOG_MERGED=false
  append_note "docktor_log_${scenario_label}=$LOG_FILE"
  start_docktor "$LOG_FILE"
  assert_docktor_alive "$LOG_FILE" "${scenario_label} Docktor process"
}

log_match_count() {
  local needle="$1"
  grep -Fc "$needle" "$LOG_FILE" 2>/dev/null || true
}

begin_scenario() {
  CURRENT_SCENARIO_ID="$1"
  CURRENT_SCENARIO_ACTION="$2"
  CURRENT_SCENARIO_ASSERTION_MODE="$3"
  local title="$4"
  echo "[$CURRENT_SCENARIO_ID] $title"
  append_note "scenario=${CURRENT_SCENARIO_ID} action=${CURRENT_SCENARIO_ACTION} assertionMode=${CURRENT_SCENARIO_ASSERTION_MODE}"
}

scenario_pass() {
  local label="$1"
  echo "  PASS $label"
}

scenario_fail() {
  local label="$1"
  echo "  FAIL $label"
  append_note "${CURRENT_SCENARIO_ID}_failure=$label"
  TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
}

scenario_expect_log_contains_any() {
  local label="$1"
  shift
  local needle
  for needle in "$@"; do
    if grep -Fq "$needle" "$LOG_FILE"; then
      scenario_pass "$label"
      return 0
    fi
  done

  scenario_fail "$label"
  for needle in "$@"; do
    echo "  expected log: $needle"
    append_note "${CURRENT_SCENARIO_ID}_expected_log=$needle"
  done
}

scenario_expect_state_equals() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(summary_state_value "$file" "$key")"
  if [[ "$actual" == "$expected" ]]; then
    scenario_pass "$label"
  else
    scenario_fail "$label (expected $expected got ${actual:-missing})"
  fi
}

scenario_expect_minimized_count_at_least() {
  local file="$1"
  local expected_minimum="$2"
  local label="$3"
  local actual
  actual="$(summary_standard_window_minimized_count "$file")"
  [[ "$actual" =~ ^[0-9]+$ ]] || actual=0
  if (( expected_minimum > 0 && actual >= expected_minimum )); then
    scenario_pass "$label"
  else
    scenario_fail "$label (expected >= $expected_minimum minimized standard windows, got $actual)"
  fi
}

scenario_expect_unminimized_count_at_least() {
  local file="$1"
  local expected_minimum="$2"
  local label="$3"
  local actual
  actual="$(summary_standard_window_unminimized_count "$file")"
  [[ "$actual" =~ ^[0-9]+$ ]] || actual=0
  if (( expected_minimum > 0 && actual >= expected_minimum )); then
    scenario_pass "$label"
  else
    scenario_fail "$label (expected >= $expected_minimum unminimized standard windows, got $actual)"
  fi
}

switch_to_control_space() {
  switch_to_space "$MULTI_SPACE_CONTROL_SPACE"
  activate_finder
  sleep 0.35
}

capture_target_snapshot() {
  local label_prefix="$1"
  record_frontmost_snapshot "${label_prefix}-frontmost" >/dev/null
  capture_bundle_state_summary "$TEST_MULTI_SPACE_TARGET_BUNDLE" \
    "$TEST_MULTI_SPACE_TARGET_PROCESS" \
    "${label_prefix}-target-state" >/dev/null
  capture_process_ax_window_summary "$TEST_MULTI_SPACE_TARGET_PROCESS" "${label_prefix}-ax" >/dev/null
  capture_artifact_screenshot "${label_prefix}-screen" >/dev/null
}

capture_finder_state_snapshot() {
  local label_prefix="$1"
  capture_bundle_state_summary "com.apple.finder" "Finder" "${label_prefix}-finder-state" >/dev/null
}

capture_dock_snapshot() {
  local label_prefix="$1"
  capture_dock_icon_snapshot "$TEST_MULTI_SPACE_TARGET_DOCK_ICON" "${label_prefix}-dock-icon" >/dev/null
}

capture_app_space_snapshots() {
  local label_prefix="$1"

  switch_to_space "$MULTI_SPACE_APP_SPACE_A"
  capture_artifact_screenshot "${label_prefix}-space${MULTI_SPACE_APP_SPACE_A}-screen" >/dev/null
  record_frontmost_snapshot "${label_prefix}-space${MULTI_SPACE_APP_SPACE_A}-frontmost" >/dev/null

  switch_to_space "$MULTI_SPACE_APP_SPACE_B"
  capture_artifact_screenshot "${label_prefix}-space${MULTI_SPACE_APP_SPACE_B}-screen" >/dev/null
  record_frontmost_snapshot "${label_prefix}-space${MULTI_SPACE_APP_SPACE_B}-frontmost" >/dev/null

  switch_to_control_space
}

activate_target_from_dock() {
  local activated=false
  for _ in 1 2 3; do
    dock_click "$TEST_MULTI_SPACE_TARGET_DOCK_ICON"
    sleep 1.1
    if [[ "$(frontmost_process)" == "$TEST_MULTI_SPACE_TARGET_PROCESS" ]]; then
      activated=true
      break
    fi
  done

  if [[ "$activated" != "true" ]]; then
    return 1
  fi

  return 0
}

activate_target_directly() {
  osascript -e "tell application id \"$TEST_MULTI_SPACE_TARGET_BUNDLE\" to activate" >/dev/null 2>&1 || true
  sleep 1.0
  [[ "$(frontmost_process)" == "$TEST_MULTI_SPACE_TARGET_PROCESS" ]]
}

ensure_target_active_before_second_click() {
  local scenario_id="$1"

  if [[ "$(frontmost_process)" == "$TEST_MULTI_SPACE_TARGET_PROCESS" ]]; then
    return 0
  fi

  append_note "${scenario_id}_warning=target lost focus before second click; reacquiring active-app precondition"
  if ! activate_target_directly && ! activate_target_from_dock; then
    scenario_fail "unable to re-activate target app '$TEST_MULTI_SPACE_TARGET_DOCK_ICON' before second click"
    return 1
  fi

  return 0
}

prepare_second_click_scenario() {
  local scenario_id="$1"
  local action="$2"

  write_pref_string firstClickBehavior activateApp
  write_pref_string clickAction "$action"
  write_pref_bool clickAppExposeRequiresMultipleWindows false
  restart_docktor_for_scenario "$scenario_id"
  switch_to_control_space
  capture_target_snapshot "${scenario_id}-before"

  if ! activate_target_from_dock; then
    scenario_fail "unable to activate target app '$TEST_MULTI_SPACE_TARGET_DOCK_ICON' from the Dock"
    return 1
  fi

  capture_target_snapshot "${scenario_id}-after-first"
  return 0
}

perform_second_click_capture() {
  local scenario_id="$1"
  local settle_seconds="${2:-0.8}"

  if ! ensure_target_active_before_second_click "$scenario_id"; then
    return 1
  fi

  dock_click "$TEST_MULTI_SPACE_TARGET_DOCK_ICON"
  sleep 0.4
  if ! assert_docktor_alive "$LOG_FILE" "${scenario_id} after second click (immediate)"; then
    scenario_fail "Docktor exited unexpectedly immediately after second click"
  fi
  capture_target_snapshot "${scenario_id}-after-second-immediate"
  capture_dock_snapshot "${scenario_id}-after-second-immediate" >/dev/null

  sleep "$settle_seconds"
  if ! assert_docktor_alive "$LOG_FILE" "${scenario_id} after second click (settle)"; then
    scenario_fail "Docktor exited unexpectedly after second-click settle"
  fi
  capture_target_snapshot "${scenario_id}-after-second-settle"
  capture_dock_snapshot "${scenario_id}-after-second-settle" >/dev/null
}

write_manual_checklist() {
  local output
  output="$(artifact_path "MANUAL_CHECKLIST" "md")"
  cat >"$output" <<EOF
# Multi-Space Manual Checklist

Artifacts live in: $TEST_ARTIFACT_DIR

## Setup confirmation
- Desktop ${MULTI_SPACE_CONTROL_SPACE} was the control space and Finder was used as the launcher baseline.
- Desktop ${MULTI_SPACE_APP_SPACE_A} and Desktop ${MULTI_SPACE_APP_SPACE_B} each contained a target-app window before the run.

## Current-Space / Manual Scenarios
- Review \`scenario-none-after-second-settle-screen.png\` and \`scenario-activateApp-after-second-settle-screen.png\`.
- Confirm Docktor did not programmatically switch Spaces for those second clicks.
- Review \`scenario-appExpose-after-second-immediate-screen.png\` and \`scenario-appExpose-after-second-settle-dock-icon.png\`.
- Confirm App Exposé opened and the Dock icon was not left greyed out or visually pressed after settle.

## AX-Visible Window Scenarios
- Review \`scenario-bringAllToFront-after-second-settle-screen.png\`, \`scenario-minimizeAll-after-second-settle-screen.png\`, and the Space 2 / Space 3 screenshots for those scenarios.
- Treat these as AX-visible-only checks: if a window remains visible on another Space while missing from AX summaries, record it as an AX limitation rather than a Docktor failure.
- Review \`scenario-minimizeAll-restore-attempt1-screen.png\` and, if present, \`scenario-minimizeAll-restore-attempt2-screen.png\`.
- Confirm the restore path returns the target app's current AX-visible standard windows without requiring manual intervention.

## App-Global Scenarios
- Review the target-state snapshots for \`scenario-hideApp\`, \`scenario-hideOthers\`, \`scenario-singleAppMode\`, and \`scenario-quitApp\`.
- Confirm those actions completed without Dock-driven Space cycling.
EOF
  printf '%s\n' "$output"
}

cleanup() {
  if [[ -n "${TEST_ARTIFACT_DIR:-}" ]]; then
    CHECKLIST_PATH="${CHECKLIST_PATH:-$(artifact_path "MANUAL_CHECKLIST" "md" 2>/dev/null || true)}"
    if [[ -n "${CHECKLIST_PATH:-}" && ! -f "$CHECKLIST_PATH" ]]; then
      write_manual_checklist >/dev/null 2>&1 || true
    fi
  fi
  merge_current_log
  stop_docktor
  ensure_no_docktor
  restore_dock_state
  if [[ -n "${PREF_BACKUP:-}" ]]; then
    restore_preferences "$PREF_BACKUP"
  fi
}
trap cleanup EXIT

run_scenario_none() {
  begin_scenario "scenario-none" "none" "$MULTI_SPACE_ASSERTION_MODE_CURRENT_SPACE_MANUAL" "clickAction none pass-through"
  if ! prepare_second_click_scenario "$CURRENT_SCENARIO_ID" "none"; then
    return 0
  fi

  perform_second_click_capture "$CURRENT_SCENARIO_ID"
  scenario_expect_log_contains_any "clickAction none logged" ": none for $TEST_MULTI_SPACE_TARGET_BUNDLE"
  capture_app_space_snapshots "${CURRENT_SCENARIO_ID}-after-second-settle"
}

run_scenario_activate_app() {
  begin_scenario "scenario-activateApp" "activateApp" "$MULTI_SPACE_ASSERTION_MODE_CURRENT_SPACE_MANUAL" "clickAction activateApp"
  if ! prepare_second_click_scenario "$CURRENT_SCENARIO_ID" "activateApp"; then
    return 0
  fi

  perform_second_click_capture "$CURRENT_SCENARIO_ID"
  scenario_expect_log_contains_any "activateApp action logged" ": activateApp for $TEST_MULTI_SPACE_TARGET_BUNDLE"
  scenario_expect_state_equals "${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-second-settle-target-state.txt" \
    "frontmostMatchesBundle" "true" "target app remained frontmost"
  scenario_expect_state_equals "${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-second-settle-target-state.txt" \
    "visible" "true" "target app remained visible"
  capture_app_space_snapshots "${CURRENT_SCENARIO_ID}-after-second-settle"
}

run_scenario_app_expose() {
  local before_invokes after_invokes

  begin_scenario "scenario-appExpose" "appExpose" "$MULTI_SPACE_ASSERTION_MODE_CURRENT_SPACE_MANUAL" "clickAction appExpose"
  if ! prepare_second_click_scenario "$CURRENT_SCENARIO_ID" "appExpose"; then
    return 0
  fi

  before_invokes="$(log_match_count "Triggering App Exposé for $TEST_MULTI_SPACE_TARGET_BUNDLE")"
  perform_second_click_capture "$CURRENT_SCENARIO_ID"
  after_invokes="$(log_match_count "Triggering App Exposé for $TEST_MULTI_SPACE_TARGET_BUNDLE")"
  if (( after_invokes > before_invokes )); then
    scenario_pass "App Exposé invocation observed on second click"
  else
    scenario_fail "App Exposé invocation was not observed on second click"
  fi
}

run_scenario_bring_all_to_front() {
  local before_summary
  local before_count
  local after_summary

  begin_scenario "scenario-bringAllToFront" "bringAllToFront" "$MULTI_SPACE_ASSERTION_MODE_AX_VISIBLE_STANDARD_WINDOWS" "clickAction bringAllToFront"
  if ! prepare_second_click_scenario "$CURRENT_SCENARIO_ID" "bringAllToFront"; then
    return 0
  fi

  before_summary="${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-first-ax.txt"
  before_count="$(summary_standard_window_count "$before_summary")"
  if [[ ! "$before_count" =~ ^[0-9]+$ ]] || (( before_count < 1 )); then
    scenario_fail "no AX-visible standard windows were present before bringAllToFront"
    capture_app_space_snapshots "${CURRENT_SCENARIO_ID}-after-second-settle"
    return 0
  fi

  perform_second_click_capture "$CURRENT_SCENARIO_ID"
  after_summary="${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-second-settle-ax.txt"

  scenario_expect_log_contains_any "bringAllToFront action logged" \
    ": bringAllToFront for $TEST_MULTI_SPACE_TARGET_BUNDLE" \
    "WindowManager: Raised "
  scenario_expect_state_equals "${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-second-settle-target-state.txt" \
    "frontmostMatchesBundle" "true" "target app frontmost after bringAllToFront"
  scenario_expect_unminimized_count_at_least "$after_summary" "$before_count" \
    "AX-visible standard windows restored/raised"
  capture_app_space_snapshots "${CURRENT_SCENARIO_ID}-after-second-settle"
}

run_scenario_minimize_all() {
  local before_summary
  local before_count
  local after_summary
  local restore_summary
  local attempt
  local restore_success=false

  begin_scenario "scenario-minimizeAll" "minimizeAll" "$MULTI_SPACE_ASSERTION_MODE_AX_VISIBLE_STANDARD_WINDOWS" "clickAction minimizeAll"
  if ! prepare_second_click_scenario "$CURRENT_SCENARIO_ID" "minimizeAll"; then
    return 0
  fi

  before_summary="${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-first-ax.txt"
  before_count="$(summary_standard_window_count "$before_summary")"
  [[ "$before_count" =~ ^[0-9]+$ ]] || before_count=0
  append_note "${CURRENT_SCENARIO_ID}_before_standard_window_count=$before_count"
  if (( before_count < 1 )); then
    scenario_fail "no AX-visible standard windows were present before minimizeAll"
    capture_app_space_snapshots "${CURRENT_SCENARIO_ID}-after-second-settle"
    return 0
  fi

  perform_second_click_capture "$CURRENT_SCENARIO_ID"
  after_summary="${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-second-settle-ax.txt"

  scenario_expect_log_contains_any "minimizeAll action logged" \
    ": minimizeAll for $TEST_MULTI_SPACE_TARGET_BUNDLE" \
    "WindowManager: Minimized "
  scenario_expect_minimized_count_at_least "$after_summary" "$before_count" \
    "AX-visible standard windows minimized"

  local after_count
  after_count="$(summary_standard_window_count "$after_summary")"
  [[ "$after_count" =~ ^[0-9]+$ ]] || after_count=0
  append_note "${CURRENT_SCENARIO_ID}_after_standard_window_count=$after_count"
  if (( after_count != before_count )); then
    append_note "${CURRENT_SCENARIO_ID}_warning=AX-visible standard window count changed (${before_count} -> ${after_count}); treat off-space deltas as AX limitations"
  fi

  capture_app_space_snapshots "${CURRENT_SCENARIO_ID}-after-second-settle"

  switch_to_control_space
  for attempt in 1 2; do
    dock_click "$TEST_MULTI_SPACE_TARGET_DOCK_ICON"
    sleep 1.0
    if ! assert_docktor_alive "$LOG_FILE" "${CURRENT_SCENARIO_ID} restore attempt $attempt"; then
      scenario_fail "Docktor exited during minimizeAll restore attempt $attempt"
    fi
    capture_target_snapshot "${CURRENT_SCENARIO_ID}-restore-attempt${attempt}"
    restore_summary="${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-restore-attempt${attempt}-ax.txt"
    if summary_standard_window_unminimized_count "$restore_summary" | awk -v min="$before_count" '{ exit !($1 >= min) }'; then
      scenario_pass "restore succeeded on attempt $attempt"
      restore_success=true
      break
    fi
  done

  if [[ "$restore_success" != "true" ]]; then
    scenario_fail "restore did not clear the AX-visible minimized window set within 2 Dock clicks"
  fi
}

run_scenario_hide_app() {
  begin_scenario "scenario-hideApp" "hideApp" "$MULTI_SPACE_ASSERTION_MODE_APP_GLOBAL" "clickAction hideApp"
  if ! prepare_second_click_scenario "$CURRENT_SCENARIO_ID" "hideApp"; then
    return 0
  fi

  perform_second_click_capture "$CURRENT_SCENARIO_ID"
  scenario_expect_log_contains_any "hideApp action logged" ": hideApp for $TEST_MULTI_SPACE_TARGET_BUNDLE"
  scenario_expect_state_equals "${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-second-settle-target-state.txt" \
    "running" "true" "target app still running after hideApp"
  scenario_expect_state_equals "${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-second-settle-target-state.txt" \
    "visible" "false" "target app hidden after hideApp"
  capture_app_space_snapshots "${CURRENT_SCENARIO_ID}-after-second-settle"
}

run_scenario_hide_others() {
  begin_scenario "scenario-hideOthers" "hideOthers" "$MULTI_SPACE_ASSERTION_MODE_APP_GLOBAL" "clickAction hideOthers"
  if ! prepare_second_click_scenario "$CURRENT_SCENARIO_ID" "hideOthers"; then
    return 0
  fi

  capture_finder_state_snapshot "${CURRENT_SCENARIO_ID}-before"
  perform_second_click_capture "$CURRENT_SCENARIO_ID"
  capture_finder_state_snapshot "${CURRENT_SCENARIO_ID}-after-second-settle"

  scenario_expect_log_contains_any "hideOthers action logged" \
    ": hideOthers for $TEST_MULTI_SPACE_TARGET_BUNDLE" \
    "WindowManager: Hide others invoked for $TEST_MULTI_SPACE_TARGET_BUNDLE"
  scenario_expect_state_equals "${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-second-settle-target-state.txt" \
    "frontmostMatchesBundle" "true" "target app frontmost after hideOthers"
  scenario_expect_state_equals "${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-second-settle-finder-state.txt" \
    "visible" "false" "Finder hidden by hideOthers"
  capture_app_space_snapshots "${CURRENT_SCENARIO_ID}-after-second-settle"
}

run_scenario_single_app_mode() {
  begin_scenario "scenario-singleAppMode" "singleAppMode" "$MULTI_SPACE_ASSERTION_MODE_APP_GLOBAL" "clickAction singleAppMode"
  if ! prepare_second_click_scenario "$CURRENT_SCENARIO_ID" "singleAppMode"; then
    return 0
  fi

  perform_second_click_capture "$CURRENT_SCENARIO_ID"
  scenario_expect_log_contains_any "singleAppMode action logged" ": singleAppMode for $TEST_MULTI_SPACE_TARGET_BUNDLE"
  scenario_expect_state_equals "${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-second-settle-target-state.txt" \
    "frontmostMatchesBundle" "true" "target app frontmost after singleAppMode"
  scenario_expect_state_equals "${TEST_ARTIFACT_DIR}/${CURRENT_SCENARIO_ID}-after-second-settle-target-state.txt" \
    "visible" "true" "target app visible after singleAppMode"
  capture_app_space_snapshots "${CURRENT_SCENARIO_ID}-after-second-settle"
}

run_scenario_quit_app() {
  begin_scenario "scenario-quitApp" "quitApp" "$MULTI_SPACE_ASSERTION_MODE_APP_GLOBAL" "clickAction quitApp"
  if ! prepare_second_click_scenario "$CURRENT_SCENARIO_ID" "quitApp"; then
    return 0
  fi

  perform_second_click_capture "$CURRENT_SCENARIO_ID" 1.0
  scenario_expect_log_contains_any "quitApp action logged" \
    ": quitApp for $TEST_MULTI_SPACE_TARGET_BUNDLE" \
    "WindowManager: App $TEST_MULTI_SPACE_TARGET_BUNDLE terminated gracefully" \
    "WindowManager: App $TEST_MULTI_SPACE_TARGET_BUNDLE force-terminated"

  if wait_for_process_terminated_by_bundle "$TEST_MULTI_SPACE_TARGET_BUNDLE" 5; then
    scenario_pass "target app terminated after quitApp"
  else
    scenario_fail "target app did not terminate within 5 seconds of quitApp"
  fi

  capture_bundle_state_summary "$TEST_MULTI_SPACE_TARGET_BUNDLE" \
    "$TEST_MULTI_SPACE_TARGET_PROCESS" \
    "${CURRENT_SCENARIO_ID}-after-termination-target-state" >/dev/null
  capture_artifact_screenshot "${CURRENT_SCENARIO_ID}-after-termination-screen" >/dev/null
}

echo "== multi-space regression checks =="
run_test_preflight true
capture_dock_state
init_artifact_dir "docktor-multi-space" >/dev/null
RUN_LOG_FILE="$(artifact_path "docktor-run" "log")"
: >"$RUN_LOG_FILE"
LOG_FILE=""
ARTIFACT_NOTES="$(artifact_path "NOTES" "txt")"
PREF_BACKUP="$(artifact_path "docktor-preferences" "plist")"
backup_preferences "$PREF_BACKUP"
validate_multi_space_preconditions

append_note "artifact_dir=$TEST_ARTIFACT_DIR"
append_note "target_dock_icon=$TEST_MULTI_SPACE_TARGET_DOCK_ICON"
append_note "target_process=$TEST_MULTI_SPACE_TARGET_PROCESS"
append_note "target_bundle=$TEST_MULTI_SPACE_TARGET_BUNDLE"
append_note "control_space=$MULTI_SPACE_CONTROL_SPACE"
append_note "app_space_a=$MULTI_SPACE_APP_SPACE_A"
append_note "app_space_b=$MULTI_SPACE_APP_SPACE_B"

echo "artifacts: $TEST_ARTIFACT_DIR"
echo "target: dock='$TEST_MULTI_SPACE_TARGET_DOCK_ICON' process='$TEST_MULTI_SPACE_TARGET_PROCESS' bundle='$TEST_MULTI_SPACE_TARGET_BUNDLE'"

write_pref_bool showOnStartup false
write_pref_bool firstLaunchCompleted true
set_dock_autohide false

run_scenario_none
run_scenario_activate_app
run_scenario_app_expose
run_scenario_bring_all_to_front
run_scenario_minimize_all
run_scenario_hide_app
run_scenario_hide_others
run_scenario_single_app_mode
run_scenario_quit_app

CHECKLIST_PATH="$(write_manual_checklist)"
merge_current_log

echo
echo "manual checklist: $CHECKLIST_PATH"
echo "log file: $RUN_LOG_FILE"
echo "artifact bundle: $TEST_ARTIFACT_DIR"

if (( TOTAL_FAILURES > 0 )); then
  echo "== multi-space regression checks complete with $TOTAL_FAILURES failure(s) =="
  exit 1
fi

echo "== multi-space regression checks complete =="
