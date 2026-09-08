#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: ./scripts/release.sh <version>"
  echo "Examples:"
  echo "  ./scripts/release.sh 1.0.0"
  echo "  ./scripts/release.sh 1.0.0-beta.1"
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[1-9][0-9]*)?$ ]]; then
  echo "Error: version must match X.Y.Z or X.Y.Z-beta.N with N >= 1 ('$VERSION')"
  exit 1
fi

TAG="v$VERSION"
CORE_VERSION="${VERSION%%-*}"

echo "Preparing release tag: $TAG"

if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "Error: releases must be tagged from main"
  exit 1
fi

if ! git diff-index --quiet HEAD --; then
  echo "Error: working tree has uncommitted changes"
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: tag $TAG already exists"
  exit 1
fi

if [[ ! -f CHANGELOG.md ]]; then
  echo "Error: CHANGELOG.md not found"
  exit 1
fi

if ! grep -q "^## \[$TAG\]" CHANGELOG.md; then
  echo "Error: CHANGELOG.md must include heading: ## [$TAG]"
  exit 1
fi

PROJECT_VERSION="$(python3 - <<'PY'
import re
from pathlib import Path
text = Path('Dockmint.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
match = re.search(r'MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);', text)
print(match.group(1) if match else '')
PY
)"

if [[ "$PROJECT_VERSION" != "$CORE_VERSION" ]]; then
  echo "Error: Dockmint MARKETING_VERSION ($PROJECT_VERSION) must match tag core version ($CORE_VERSION)"
  exit 1
fi

PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/validate_release_contract.py \
  --tag "$TAG" \
  --require-canonical-origin

RELEASE_VALIDATION_WAIVER="${DOCKMINT_RELEASE_VALIDATION_WAIVER:-}"

if [[ -n "$RELEASE_VALIDATION_WAIVER" ]]; then
  if [[ ! "$RELEASE_VALIDATION_WAIVER" =~ (https://github.com/.+/issues/[0-9]+|#[0-9]+) ]]; then
    echo "Error: DOCKMINT_RELEASE_VALIDATION_WAIVER must reference an issue (e.g. #123 or full GitHub issue URL)"
    exit 1
  fi
  echo "WARNING: skipping required release validation under waiver: $RELEASE_VALIDATION_WAIVER"
else
  echo "Running required pre-release validation..."
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/release/tests -v
  ./scripts/run_decision_engine_tests.sh
  ./scripts/run_app_expose_invoker_tests.sh
  xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug -destination 'platform=macOS' test
  xcodebuild -project Dockmint.xcodeproj -scheme Dockmint -configuration Debug build
  if [[ "${DOCKMINT_RUN_LOCAL_UI_CHECKS:-0}" == "1" ]]; then
    ./scripts/run_all_checks.sh
  else
    echo "Skipping local UI checks: these alter Dock state and require explicit opt-in."
  fi
fi

git tag "$TAG"
git push origin "$TAG"

echo "Release tag pushed: $TAG"
echo "GitHub Actions release workflow is now building signed artifacts."
