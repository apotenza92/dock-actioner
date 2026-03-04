#!/usr/bin/env bash

: "${BUNDLE_ID:=pzc.Dockter}"
: "${TEST_SELECTION_MODE:=deterministic}"
: "${DOCKTOR_START_TIMEOUT_SECONDS:=12}"
: "${DOCKTOR_READY_LOG_MARKER:=Event tap started.}"

APP_BIN="${APP_BIN:-}"
APP_BUNDLE="${APP_BUNDLE:-}"
CLICLICK_BIN="${CLICLICK_BIN:-}"

APP_PID=""
TEST_ORIG_AUTOHIDE=""
START_DOCKTOR_LAST_ERROR=""

log_contains() {
  local needle="$1"
  local file="$2"
  [[ -f "$file" ]] && grep -Fq "$needle" "$file"
}

print_log_tail() {
  local file="$1"
  local lines="${2:-40}"
  if [[ -f "$file" ]]; then
    echo "---- last ${lines} lines of $file ----"
    tail -n "$lines" "$file"
    echo "---- end log ----"
  else
    echo "(log file missing: $file)"
  fi
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool '$tool' was not found in PATH" >&2
    return 1
  fi
}

discover_latest_debug_app_bundle() {
  local derived_data_root="$HOME/Library/Developer/Xcode/DerivedData"
  local repo_debug_bundle="$PWD/.build/Build/Products/Debug/Docktor.app"
  local -a candidates=()

  if [[ -d "$repo_debug_bundle" ]]; then
    candidates+=("$repo_debug_bundle")
  fi

  if [[ -d "$derived_data_root" ]]; then
    while IFS= read -r candidate; do
      candidates+=("$candidate")
    done < <(find "$derived_data_root" -type d -path "*/Build/Products/Debug/Docktor.app" 2>/dev/null)
  fi

  local latest_bundle=""
  local latest_mtime=-1
  local candidate
  for candidate in "${candidates[@]}"; do
    local bin="$candidate/Contents/MacOS/Docktor"
    [[ -x "$bin" ]] || continue

    local mtime
    mtime="$(stat -f %m "$bin" 2>/dev/null || echo 0)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0

    if (( mtime > latest_mtime )); then
      latest_mtime="$mtime"
      latest_bundle="$candidate"
    elif (( mtime == latest_mtime )) && [[ "$candidate" > "$latest_bundle" ]]; then
      latest_bundle="$candidate"
    fi
  done

  [[ -n "$latest_bundle" ]] && printf '%s\n' "$latest_bundle"
}

resolve_app_paths() {
  if [[ -n "${APP_BIN:-}" ]]; then
    if [[ ! -x "$APP_BIN" ]]; then
      echo "error: APP_BIN override is not executable: $APP_BIN" >&2
      return 1
    fi
    if [[ -z "${APP_BUNDLE:-}" ]]; then
      APP_BUNDLE="$(cd "$(dirname "$APP_BIN")/../.." && pwd -P)"
    fi
  elif [[ -n "${APP_BUNDLE:-}" ]]; then
    if [[ ! -d "$APP_BUNDLE" ]]; then
      echo "error: APP_BUNDLE override does not exist: $APP_BUNDLE" >&2
      return 1
    fi
    APP_BUNDLE="$(cd "$APP_BUNDLE" && pwd -P)"
    APP_BIN="$APP_BUNDLE/Contents/MacOS/Docktor"
  else
    local discovered_bundle
    discovered_bundle="$(discover_latest_debug_app_bundle || true)"
    if [[ -z "$discovered_bundle" ]]; then
      echo "error: unable to discover Docktor Debug app bundle (set APP_BIN or APP_BUNDLE)" >&2
      return 1
    fi
    APP_BUNDLE="$discovered_bundle"
    APP_BIN="$APP_BUNDLE/Contents/MacOS/Docktor"
  fi

  if [[ ! -x "$APP_BIN" ]]; then
    echo "error: app binary missing at $APP_BIN" >&2
    return 1
  fi

  if [[ -z "${APP_BUNDLE:-}" || ! -d "$APP_BUNDLE" ]]; then
    echo "error: app bundle missing at $APP_BUNDLE" >&2
    return 1
  fi

  return 0
}

require_app_bin() {
  resolve_app_paths
}

resolve_cliclick_bin() {
  if [[ -n "${CLICLICK_BIN:-}" ]]; then
    if [[ ! -x "$CLICLICK_BIN" ]]; then
      echo "error: CLICLICK_BIN override is not executable: $CLICLICK_BIN" >&2
      return 1
    fi
    return 0
  fi

  local discovered
  discovered="$(command -v cliclick || true)"
  if [[ -z "$discovered" ]]; then
    echo "error: cliclick not found (set CLICLICK_BIN or install cliclick)" >&2
    return 1
  fi
  CLICLICK_BIN="$discovered"
}

require_cliclick_bin() {
  resolve_cliclick_bin
}

run_test_preflight() {
  local needs_cliclick="${1:-false}"

  require_tool osascript
  require_tool defaults
  require_tool grep
  require_tool awk
  require_tool sed
  require_tool open
  require_app_bin

  if [[ "$needs_cliclick" == "true" ]]; then
    require_cliclick_bin
  fi
}

docktor_startup_failure_reason_from_log() {
  local log_file="$1"

  if log_contains "startIfPossible: denied (no accessibility)." "$log_file"; then
    printf '%s\n' "accessibility permission denied (startIfPossible)"
    return 0
  fi
  if log_contains "startIfPossible: denied (no input monitoring)." "$log_file"; then
    printf '%s\n' "input monitoring permission denied (startIfPossible)"
    return 0
  fi
  if log_contains "Failed to start event tap." "$log_file"; then
    printf '%s\n' "event tap failed to start"
    return 0
  fi

  return 1
}

wait_for_docktor_ready() {
  local log_file="$1"
  local timeout_seconds="${2:-$DOCKTOR_START_TIMEOUT_SECONDS}"
  local deadline=$((SECONDS + timeout_seconds))
  START_DOCKTOR_LAST_ERROR=""

  while (( SECONDS <= deadline )); do
    local startup_error
    startup_error="$(docktor_startup_failure_reason_from_log "$log_file" || true)"
    if [[ -n "$startup_error" ]]; then
      START_DOCKTOR_LAST_ERROR="$startup_error"
      return 1
    fi

    if log_contains "$DOCKTOR_READY_LOG_MARKER" "$log_file"; then
      return 0
    fi

    if [[ -z "${APP_PID:-}" ]] || ! kill -0 "$APP_PID" >/dev/null 2>&1; then
      startup_error="$(docktor_startup_failure_reason_from_log "$log_file" || true)"
      if [[ -n "$startup_error" ]]; then
        START_DOCKTOR_LAST_ERROR="$startup_error (process exited early)"
      else
        START_DOCKTOR_LAST_ERROR="process exited before readiness marker '$DOCKTOR_READY_LOG_MARKER'"
      fi
      return 1
    fi

    sleep 0.2
  done

  START_DOCKTOR_LAST_ERROR="timed out after ${timeout_seconds}s waiting for '$DOCKTOR_READY_LOG_MARKER'"
  return 1
}

capture_dock_state() {
  TEST_ORIG_AUTOHIDE="$(defaults read com.apple.dock autohide 2>/dev/null || echo 1)"
}

restore_dock_state() {
  if [[ -n "${TEST_ORIG_AUTOHIDE:-}" ]]; then
    defaults write com.apple.dock autohide -bool "$TEST_ORIG_AUTOHIDE" >/dev/null 2>&1 || true
    killall Dock >/dev/null 2>&1 || true
  fi
}

set_dock_autohide() {
  local enabled="$1"
  defaults write com.apple.dock autohide -bool "$enabled"
  killall Dock
  sleep 1
  ensure_dock_ready
}

ensure_dock_ready() {
  for _ in $(seq 1 30); do
    if osascript -e 'tell application "System Events" to exists process "Dock"' 2>/dev/null | grep -qi true; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

ensure_no_docktor() {
  pkill -x Docktor >/dev/null 2>&1 || true
}

start_docktor() {
  local log_file="$1"
  shift

  require_app_bin
  stop_docktor
  ensure_no_docktor
  : > "$log_file"

  DOCKTOR_DEBUG_LOG="${DOCKTOR_DEBUG_LOG:-1}" DOCKTOR_TEST_SUITE=1 "$APP_BIN" "$@" >>"$log_file" 2>&1 &
  APP_PID=$!

  if ! wait_for_docktor_ready "$log_file"; then
    echo "error: Docktor failed to become ready: ${START_DOCKTOR_LAST_ERROR:-unknown startup failure}" >&2
    print_log_tail "$log_file" 80 >&2
    stop_docktor
    return 1
  fi
}

assert_docktor_alive() {
  local log_file="${1:-}"
  local context="${2:-Docktor process}"

  if [[ -z "${APP_PID:-}" ]] || ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    echo "  FAIL: $context exited unexpectedly" >&2
    if [[ -n "$log_file" ]]; then
      local startup_error
      startup_error="$(docktor_startup_failure_reason_from_log "$log_file" || true)"
      if [[ -n "$startup_error" ]]; then
        echo "  reason: $startup_error" >&2
      fi
      print_log_tail "$log_file" 60 >&2
    fi
    return 1
  fi

  return 0
}

stop_docktor() {
  if [[ -n "${APP_PID:-}" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
    APP_PID=""
  fi
}

frontmost_process() {
  osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null || echo "unknown"
}

process_visible() {
  local process_name="$1"
  osascript -e "tell application \"System Events\" to get visible of process \"$process_name\"" 2>/dev/null || echo "missing"
}

set_process_visible() {
  local process_name="$1"
  local visible="$2"
  osascript -e "tell application \"System Events\" to set visible of process \"$process_name\" to $visible" >/dev/null 2>&1 || true
}

activate_finder() {
  osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
  sleep 0.25
}

dock_icon_names() {
  ensure_dock_ready || { echo "error: Dock process not ready" >&2; return 1; }
  osascript -e 'tell application "System Events" to tell process "Dock" to get name of every UI element of list 1' \
    | tr ',' '\n' \
    | sed 's/^ *//; s/ *$//' \
    | awk 'NF && $0 != "missing value" && $0 != "Applications" && $0 != "Downloads" && $0 != "Bin"'
}

user_process_names() {
  osascript -e 'tell application "System Events" to get name of every process whose background only is false' \
    | tr ',' '\n' \
    | sed 's/^ *//; s/ *$//' \
    | awk 'NF'
}

process_name_for_dock_icon() {
  local icon_name="$1"
  local icon_lc
  icon_lc="$(printf '%s' "$icon_name" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r proc; do
    local proc_lc
    proc_lc="$(printf '%s' "$proc" | tr '[:upper:]' '[:lower:]')"
    if [[ "$proc_lc" == "$icon_lc" ]]; then
      printf '%s\n' "$proc"
      return 0
    fi
  done < <(user_process_names)
  return 1
}

process_bundle_id() {
  local process_name="$1"
  osascript -e "tell application \"System Events\" to get bundle identifier of process \"$process_name\"" 2>/dev/null || true
}

process_window_count() {
  local process_name="$1"
  osascript -e "tell application \"System Events\" to tell process \"$process_name\" to get count of windows" 2>/dev/null || echo 0
}

select_two_dock_test_apps() {
  local mode="${TEST_SELECTION_MODE:-deterministic}"
  local -a candidate_icons=()
  local -a candidate_procs=()
  local -a candidate_bundles=()
  local -a rejected=()

  TEST_DOCK_ICON_A=""
  TEST_PROCESS_A=""
  TEST_BUNDLE_A=""
  TEST_DOCK_ICON_B=""
  TEST_PROCESS_B=""
  TEST_BUNDLE_B=""

  while IFS= read -r icon; do
    local proc
    proc="$(process_name_for_dock_icon "$icon" || true)"
    if [[ -z "$proc" ]]; then
      rejected+=("icon='$icon' reason=no-matching-user-process")
      continue
    fi

    local proc_lc
    proc_lc="$(printf '%s' "$proc" | tr '[:upper:]' '[:lower:]')"
    if [[ "$proc_lc" == "docktor" || "$proc_lc" == "finder" ]]; then
      rejected+=("icon='$icon' process='$proc' reason=excluded-process")
      continue
    fi

    local visible
    visible="$(process_visible "$proc")"
    if [[ "$visible" != "true" ]]; then
      rejected+=("icon='$icon' process='$proc' reason=not-visible($visible)")
      continue
    fi

    local windows
    windows="$(process_window_count "$proc")"
    [[ "$windows" =~ ^[0-9]+$ ]] || windows=0
    if (( windows < 1 )); then
      rejected+=("icon='$icon' process='$proc' reason=no-windows")
      continue
    fi

    local bundle
    bundle="$(process_bundle_id "$proc")"
    if [[ -z "$bundle" || "$bundle" == "missing value" ]]; then
      rejected+=("icon='$icon' process='$proc' reason=no-bundle-id")
      continue
    fi

    candidate_icons+=("$icon")
    candidate_procs+=("$proc")
    candidate_bundles+=("$bundle")
  done < <(dock_icon_names)

  local count="${#candidate_icons[@]}"
  if (( count < 2 )); then
    echo "error: unable to discover two suitable Dock test apps dynamically (usable=$count)" >&2
    if (( count > 0 )); then
      echo "info: usable candidates:" >&2
      local i
      for ((i = 0; i < count; i++)); do
        echo "  - icon='${candidate_icons[$i]}' process='${candidate_procs[$i]}' bundle='${candidate_bundles[$i]}'" >&2
      done
    fi
    if (( ${#rejected[@]} > 0 )); then
      echo "info: rejected Dock icons:" >&2
      printf '  - %s\n' "${rejected[@]}" >&2
    fi
    return 1
  fi

  if [[ "$mode" != "deterministic" && "$mode" != "random" ]]; then
    echo "warn: unknown TEST_SELECTION_MODE='$mode' (expected deterministic|random); defaulting to deterministic" >&2
    mode="deterministic"
  fi

  if [[ -n "${TEST_SELECTION_SEED:-}" ]]; then
    RANDOM="$TEST_SELECTION_SEED"
  fi

  local pinned_bundle_a="${TEST_PINNED_BUNDLE_A:-}"
  local pinned_process_a="${TEST_PINNED_PROCESS_A:-}"
  local pinned_icon_a="${TEST_PINNED_DOCK_ICON_A:-}"
  local pinned_bundle_b="${TEST_PINNED_BUNDLE_B:-}"
  local pinned_process_b="${TEST_PINNED_PROCESS_B:-}"
  local pinned_icon_b="${TEST_PINNED_DOCK_ICON_B:-}"

  local idx_a=-1
  local idx_b=-1
  local i

  if [[ -n "$pinned_bundle_a" || -n "$pinned_process_a" || -n "$pinned_icon_a" ]]; then
    for ((i = 0; i < count; i++)); do
      [[ -n "$pinned_bundle_a" && "${candidate_bundles[$i]}" != "$pinned_bundle_a" ]] && continue
      [[ -n "$pinned_process_a" && "${candidate_procs[$i]}" != "$pinned_process_a" ]] && continue
      [[ -n "$pinned_icon_a" && "${candidate_icons[$i]}" != "$pinned_icon_a" ]] && continue
      idx_a="$i"
      break
    done
    if (( idx_a < 0 )); then
      echo "error: pinned target A not found (bundle='${pinned_bundle_a:-*}' process='${pinned_process_a:-*}' icon='${pinned_icon_a:-*}')" >&2
      return 1
    fi
  elif [[ "$mode" == "random" ]]; then
    idx_a=$((RANDOM % count))
  else
    idx_a=0
  fi

  local proc_a_lc
  proc_a_lc="$(printf '%s' "${candidate_procs[$idx_a]}" | tr '[:upper:]' '[:lower:]')"

  if [[ -n "$pinned_bundle_b" || -n "$pinned_process_b" || -n "$pinned_icon_b" ]]; then
    for ((i = 0; i < count; i++)); do
      [[ "$i" -eq "$idx_a" ]] && continue
      [[ -n "$pinned_bundle_b" && "${candidate_bundles[$i]}" != "$pinned_bundle_b" ]] && continue
      [[ -n "$pinned_process_b" && "${candidate_procs[$i]}" != "$pinned_process_b" ]] && continue
      [[ -n "$pinned_icon_b" && "${candidate_icons[$i]}" != "$pinned_icon_b" ]] && continue

      local proc_i_lc
      proc_i_lc="$(printf '%s' "${candidate_procs[$i]}" | tr '[:upper:]' '[:lower:]')"
      [[ "$proc_i_lc" == "$proc_a_lc" ]] && continue

      idx_b="$i"
      break
    done
    if (( idx_b < 0 )); then
      echo "error: pinned target B not found with a distinct process (bundle='${pinned_bundle_b:-*}' process='${pinned_process_b:-*}' icon='${pinned_icon_b:-*}')" >&2
      return 1
    fi
  elif [[ "$mode" == "random" ]]; then
    local -a eligible=()
    for ((i = 0; i < count; i++)); do
      local proc_i_lc
      proc_i_lc="$(printf '%s' "${candidate_procs[$i]}" | tr '[:upper:]' '[:lower:]')"
      if [[ "$proc_i_lc" != "$proc_a_lc" ]]; then
        eligible+=("$i")
      fi
    done

    if (( ${#eligible[@]} == 0 )); then
      echo "error: discovered app candidates map to one process only" >&2
      return 1
    fi

    idx_b="${eligible[$((RANDOM % ${#eligible[@]}))]}"
  else
    for ((i = 0; i < count; i++)); do
      [[ "$i" -eq "$idx_a" ]] && continue
      local proc_i_lc
      proc_i_lc="$(printf '%s' "${candidate_procs[$i]}" | tr '[:upper:]' '[:lower:]')"
      if [[ "$proc_i_lc" != "$proc_a_lc" ]]; then
        idx_b="$i"
        break
      fi
    done

    if (( idx_b < 0 )); then
      echo "error: discovered app candidates map to one process only" >&2
      return 1
    fi
  fi

  TEST_DOCK_ICON_A="${candidate_icons[$idx_a]}"
  TEST_PROCESS_A="${candidate_procs[$idx_a]}"
  TEST_BUNDLE_A="${candidate_bundles[$idx_a]}"
  TEST_DOCK_ICON_B="${candidate_icons[$idx_b]}"
  TEST_PROCESS_B="${candidate_procs[$idx_b]}"
  TEST_BUNDLE_B="${candidate_bundles[$idx_b]}"

  echo "selected apps ($mode, candidates=$count): A='$TEST_DOCK_ICON_A'($TEST_PROCESS_A) B='$TEST_DOCK_ICON_B'($TEST_PROCESS_B)"
}

dock_icon_center() {
  local icon_name="$1"
  ensure_dock_ready || { echo "error: Dock process not ready" >&2; return 1; }
  osascript -e "tell application \"System Events\" to tell process \"Dock\" to get {position, size} of UI element \"$icon_name\" of list 1" \
    | awk -F',' '{gsub(/ /,""); printf "%d,%d", int($1+$3/2), int($2+$4/2)}'
}

dock_click() {
  local icon_name="$1"
  require_cliclick_bin
  "$CLICLICK_BIN" c:"$(dock_icon_center "$icon_name")"
}

write_pref_string() {
  local key="$1"
  local value="$2"
  defaults write "$BUNDLE_ID" "$key" -string "$value"
}

write_pref_bool() {
  local key="$1"
  local value="$2"
  defaults write "$BUNDLE_ID" "$key" -bool "$value"
}
