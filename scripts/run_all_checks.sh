#!/usr/bin/env bash
set -uo pipefail

declare -a STAGE_NAMES=()
declare -a STAGE_CODES=()
declare -a STAGE_DURATIONS=()

run_stage() {
  local name="$1"
  shift

  local started_at="$SECONDS"
  local exit_code=0

  echo "==> START: $name"
  "$@"
  exit_code=$?

  local duration=$((SECONDS - started_at))
  STAGE_NAMES+=("$name")
  STAGE_CODES+=("$exit_code")
  STAGE_DURATIONS+=("$duration")

  if (( exit_code == 0 )); then
    echo "==> PASS : $name (${duration}s)"
  else
    echo "==> FAIL : $name (exit=$exit_code, ${duration}s)"
  fi

  return 0
}

run_stage "xcodebuild test" xcodebuild -project Docktor.xcodeproj -scheme Docktor -configuration Debug test -quiet
run_stage "decision engine CLI tests" ./scripts/run_decision_engine_tests.sh
run_stage "automated app expose checks" ./scripts/automated_app_expose_checks.sh
run_stage "automated settings shell checks" ./scripts/automated_settings_shell_checks.sh
run_stage "automated issue1 checks" ./scripts/automated_issue1_checks.sh

echo
echo "== run_all_checks summary =="
failures=0
for i in "${!STAGE_NAMES[@]}"; do
  name="${STAGE_NAMES[$i]}"
  code="${STAGE_CODES[$i]}"
  duration="${STAGE_DURATIONS[$i]}"
  if (( code == 0 )); then
    printf '  [PASS] %s (%ss)\n' "$name" "$duration"
  else
    printf '  [FAIL] %s (exit=%s, %ss)\n' "$name" "$code" "$duration"
    failures=$((failures + 1))
  fi
done

if (( failures > 0 )); then
  echo "run_all_checks: $failures stage(s) failed"
  exit 1
fi

echo "run_all_checks: all stages passed"
