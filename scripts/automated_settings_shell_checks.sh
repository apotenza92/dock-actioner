#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test_common.sh"

run_test_preflight false
capture_dock_state
ensure_no_docktor

cleanup() {
  stop_docktor
  write_pref_bool showMenuBarIcon true
  write_pref_bool showOnStartup false
  write_pref_bool firstLaunchCompleted true
  ensure_no_docktor
  restore_dock_state
}
trap cleanup EXIT

count_menu_bar_items() {
  osascript -e 'tell application "System Events" to tell process "ControlCenter" to get count of menu bar items of menu bar 1'
}

wait_for_menu_bar_min_count() {
  local minimum="$1"
  local timeout_seconds="${2:-8}"
  local deadline=$((SECONDS + timeout_seconds))
  local current=""

  while (( SECONDS < deadline )); do
    current="$(count_menu_bar_items)"
    if [[ "$current" -ge "$minimum" ]]; then
      echo "$current"
      return 0
    fi
    sleep 0.25
  done

  current="$(count_menu_bar_items)"
  echo "$current"
  return 1
}

wait_for_menu_bar_exact_count() {
  local expected="$1"
  local timeout_seconds="${2:-8}"
  local deadline=$((SECONDS + timeout_seconds))
  local current=""

  while (( SECONDS < deadline )); do
    current="$(count_menu_bar_items)"
    if [[ "$current" -eq "$expected" ]]; then
      echo "$current"
      return 0
    fi
    sleep 0.25
  done

  current="$(count_menu_bar_items)"
  echo "$current"
  return 1
}

echo "[settings-shell] ensure deterministic Dock geometry"
set_dock_autohide false

echo "[settings-shell] menu icon toggle"
base_count="$(count_menu_bar_items)"
write_pref_bool showMenuBarIcon true
start_docktor /tmp/docktor-settings-shell-on.log
on_count="$(wait_for_menu_bar_min_count "$((base_count + 1))" 10 || true)"
stop_docktor

write_pref_bool showMenuBarIcon false
start_docktor /tmp/docktor-settings-shell-off.log
off_count="$(wait_for_menu_bar_exact_count "$base_count" 10 || true)"
stop_docktor

echo "  counts base=$base_count on=$on_count off=$off_count"
if [[ "$on_count" -lt "$((base_count + 1))" ]]; then
  echo "  FAIL: expected icon-on menu count to increase"
  exit 1
fi
if [[ "$off_count" -ne "$base_count" ]]; then
  echo "  FAIL: expected icon-off menu count to return to baseline (after wait)"
  exit 1
fi

echo "[settings-shell] first launch opens settings once"
write_pref_bool showMenuBarIcon true
write_pref_bool showOnStartup false
delete_pref firstLaunchCompleted

start_docktor /tmp/docktor-settings-shell-first-launch.log
wait_for_log_contains "Opening settings window" /tmp/docktor-settings-shell-first-launch.log 6 || true
if ! log_contains "Opening settings window" /tmp/docktor-settings-shell-first-launch.log; then
  echo "  FAIL: expected first launch to open settings"
  exit 1
fi
if ! wait_for_pref_bool firstLaunchCompleted 1 5; then
  first_launch_completed="$(read_pref_bool firstLaunchCompleted)"
  echo "  FAIL: expected firstLaunchCompleted to be persisted after first launch"
  exit 1
fi
stop_docktor

start_docktor /tmp/docktor-settings-shell-second-launch.log
sleep 2
stop_docktor
if log_contains "Opening settings window" /tmp/docktor-settings-shell-second-launch.log; then
  echo "  FAIL: expected subsequent launch to keep settings closed when showOnStartup is off"
  exit 1
fi

echo "[settings-shell] --settings fail-safe"
write_pref_bool showMenuBarIcon false
write_pref_bool showOnStartup false
write_pref_bool firstLaunchCompleted true
start_docktor /tmp/docktor-settings-shell-args.log --settings
wait_for_log_contains "Launch argument requested settings window" /tmp/docktor-settings-shell-args.log 6 || true
wait_for_log_contains "Opening settings window" /tmp/docktor-settings-shell-args.log 6 || true
stop_docktor
if ! log_contains "Launch argument requested settings window" /tmp/docktor-settings-shell-args.log; then
  echo "  FAIL: missing launch-argument settings log"
  exit 1
fi
if ! log_contains "Opening settings window" /tmp/docktor-settings-shell-args.log; then
  echo "  FAIL: missing settings open log for --settings"
  exit 1
fi

echo "[settings-shell] URL fail-safe"
ensure_no_docktor
latest_before="$(ls -t "$HOME"/Code/Docktor/logs/Docktor-*.log 2>/dev/null | head -n 1 || true)"
open -na "$APP_BUNDLE" >/dev/null 2>&1 || true
sleep 2
open "docktor://settings" >/dev/null 2>&1 || true
sleep 2
ensure_no_docktor
sleep 0.5
latest_after="$(ls -t "$HOME"/Code/Docktor/logs/Docktor-*.log 2>/dev/null | head -n 1 || true)"
if [[ -z "$latest_after" ]]; then
  echo "  FAIL: no Docktor log found for URL test"
  exit 1
fi
if [[ "$latest_after" == "$latest_before" ]]; then
  echo "  FAIL: no new Docktor run log created for URL test"
  exit 1
fi
if log_contains "Received URL request to open settings" "$latest_after"; then
  echo "  URL handler log observed"
else
  echo "  WARN: URL handler log not observed in latest debug run (LaunchServices may route URL to another installed Docktor bundle)"
fi

echo "== settings shell checks passed =="
