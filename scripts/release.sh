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

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: invalid semver version '$VERSION'"
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
text = Path('Docktor.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
match = re.search(r'MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);', text)
print(match.group(1) if match else '')
PY
)"

if [[ "$PROJECT_VERSION" != "$CORE_VERSION" ]]; then
  echo "Error: Docktor MARKETING_VERSION ($PROJECT_VERSION) must match tag core version ($CORE_VERSION)"
  exit 1
fi

git tag "$TAG"
git push origin "$TAG"

echo "Release tag pushed: $TAG"
echo "GitHub Actions release workflow is now building signed artifacts."
