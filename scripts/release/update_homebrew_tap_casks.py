#!/usr/bin/env python3
"""Update Docktor Homebrew casks in apotenza92/homebrew-tap.

Policy:
- Stable cask tracks latest stable tag (vX.Y.Z).
- Beta cask tracks whichever is newer between latest stable and latest prerelease.
  This keeps beta-channel users moving forward even when stable surpasses beta.
- Beta artifacts install side-by-side as Docktor Beta.app.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path


STABLE_TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
PRERELEASE_TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)-([0-9A-Za-z.-]+)$")


@dataclasses.dataclass(frozen=True)
class ParsedTag:
    major: int
    minor: int
    patch: int
    prerelease: str | None


@dataclasses.dataclass(frozen=True)
class Release:
    tag_name: str
    draft: bool
    prerelease_flag: bool
    assets: tuple["ReleaseAsset", ...]
    parsed: ParsedTag


@dataclasses.dataclass(frozen=True)
class ReleaseAsset:
    name: str
    download_url: str
    size: int
    sha256: str | None


def parse_tag(tag: str) -> ParsedTag | None:
    stable = STABLE_TAG_RE.match(tag)
    if stable:
        return ParsedTag(
            int(stable.group(1)), int(stable.group(2)), int(stable.group(3)), None
        )

    prerelease = PRERELEASE_TAG_RE.match(tag)
    if prerelease:
        return ParsedTag(
            int(prerelease.group(1)),
            int(prerelease.group(2)),
            int(prerelease.group(3)),
            prerelease.group(4),
        )

    return None


def prerelease_key(prerelease: str) -> tuple[tuple[int, int | str], ...]:
    tokens: list[tuple[int, int | str]] = []
    for part in re.split(r"[.-]", prerelease):
        if part.isdigit():
            tokens.append((0, int(part)))
        else:
            tokens.append((1, part.lower()))
    return tuple(tokens)


def version_key(
    parsed: ParsedTag,
) -> tuple[int, int, int, int, tuple[tuple[int, int | str], ...]]:
    is_stable = 1 if parsed.prerelease is None else 0
    suffix = () if parsed.prerelease is None else prerelease_key(parsed.prerelease)
    return (parsed.major, parsed.minor, parsed.patch, is_stable, suffix)


def parse_sha256_digest(raw: object) -> str | None:
    if raw is None:
        return None
    value = str(raw).strip().lower()
    if value.startswith("sha256:"):
        value = value.removeprefix("sha256:")
    if re.fullmatch(r"[0-9a-f]{64}", value):
        return value
    return None


def build_api_headers(user_agent: str, github_token: str | None) -> dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": user_agent,
    }
    if github_token:
        headers["Authorization"] = f"Bearer {github_token}"
    return headers


def fetch_releases(repo: str, github_token: str | None) -> list[Release]:
    url = f"https://api.github.com/repos/{repo}/releases"
    req = urllib.request.Request(
        url,
        headers=build_api_headers(
            user_agent="docktor-homebrew-sync", github_token=github_token
        ),
    )

    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Failed to fetch releases from {repo}: {exc}") from exc

    output: list[Release] = []
    for item in payload:
        tag = item.get("tag_name", "")
        parsed = parse_tag(tag)
        if parsed is None:
            continue

        assets = tuple(
            ReleaseAsset(
                name=str(asset.get("name", "")),
                download_url=str(asset.get("browser_download_url", "")),
                size=int(asset.get("size", 0)),
                sha256=parse_sha256_digest(asset.get("digest")),
            )
            for asset in item.get("assets", [])
        )

        output.append(
            Release(
                tag_name=tag,
                draft=bool(item.get("draft", False)),
                prerelease_flag=bool(item.get("prerelease", False)),
                assets=assets,
                parsed=parsed,
            )
        )

    return [release for release in output if not release.draft]


def pick_latest(releases: list[Release]) -> Release | None:
    if not releases:
        return None
    return max(releases, key=lambda release: version_key(release.parsed))


def version_string(parsed: ParsedTag) -> str:
    base = f"{parsed.major}.{parsed.minor}.{parsed.patch}"
    if parsed.prerelease:
        return f"{base}-{parsed.prerelease}"
    return base


def find_asset(release: Release, name: str) -> ReleaseAsset:
    for asset in release.assets:
        if asset.name == name:
            return asset
    raise RuntimeError(f"Asset '{name}' not found in release {release.tag_name}")


def sha256_for_asset(
    asset: ReleaseAsset, github_token: str | None, cache: dict[str, str]
) -> str:
    if asset.sha256 is not None:
        return asset.sha256

    if asset.download_url in cache:
        return cache[asset.download_url]

    print(f"Computing sha256 for asset {asset.name} ...")
    request = urllib.request.Request(
        asset.download_url,
        headers=build_api_headers(
            user_agent="docktor-homebrew-sha256", github_token=github_token
        )
        | {"Accept": "application/octet-stream"},
    )
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=120) as response:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)

    resolved = digest.hexdigest()
    cache[asset.download_url] = resolved
    return resolved


def render_stable_cask(
    repo: str,
    version: str,
    arm_url: str,
    arm_sha256: str,
    intel_url: str,
    intel_sha256: str,
) -> str:
    return f'''cask "docktor" do
  version "{version}"

  on_arm do
    url "{arm_url}"
    sha256 "{arm_sha256}"
  end

  on_intel do
    url "{intel_url}"
    sha256 "{intel_sha256}"
  end

  name "Docktor"
  desc "Dock gesture actions for macOS"
  homepage "https://github.com/{repo}"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "Docktor.app"

  zap trash: [
    "~/Library/Application Support/Docktor",
    "~/Library/Caches/pzc.Dockter",
    "~/Library/Preferences/pzc.Dockter.plist",
    "~/Library/Saved Application State/pzc.Dockter.savedState",
  ]
end
'''


def render_beta_cask(
    repo: str,
    version: str,
    arm_url: str,
    arm_sha256: str,
    intel_url: str,
    intel_sha256: str,
) -> str:
    return f'''cask "docktor@beta" do
  version "{version}"

  on_arm do
    url "{arm_url}"
    sha256 "{arm_sha256}"
  end

  on_intel do
    url "{intel_url}"
    sha256 "{intel_sha256}"
  end

  name "Docktor Beta"
  desc "Beta channel for Docktor"
  homepage "https://github.com/{repo}"

  livecheck do
    url "https://api.github.com/repos/{repo}/releases"
    strategy :json do |json|
      json
        .reject {{ |release| release["draft"] }}
        .map {{ |release| release["tag_name"] }}
    end
  end

  app "Docktor Beta.app"

  zap trash: [
    "~/Library/Application Support/Docktor Beta",
    "~/Library/Caches/pzc.Dockter.beta",
    "~/Library/Preferences/pzc.Dockter.beta.plist",
    "~/Library/Saved Application State/pzc.Dockter.beta.savedState",
  ]
end
'''


def write_if_changed(path: Path, content: str) -> bool:
    existing = path.read_text(encoding="utf-8") if path.exists() else None
    if existing == content:
        return False
    path.write_text(content, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tap-path",
        type=Path,
        required=True,
        help="Path to local homebrew-tap checkout",
    )
    parser.add_argument(
        "--repo",
        default="apotenza92/docktor",
        help="GitHub repository owner/name",
    )
    parser.add_argument(
        "--github-token",
        default=os.environ.get("GITHUB_TOKEN", "").strip() or None,
        help="GitHub token for API and asset download requests (defaults to GITHUB_TOKEN env var)",
    )
    args = parser.parse_args()

    releases = fetch_releases(args.repo, github_token=args.github_token)
    stable = pick_latest(
        [release for release in releases if release.parsed.prerelease is None]
    )
    prerelease = pick_latest(
        [release for release in releases if release.parsed.prerelease is not None]
    )

    if stable is None and prerelease is None:
        print("No releases found; skipping Homebrew cask update.")
        return 0

    beta_track = None
    if stable is not None and prerelease is not None:
        stable_key = version_key(stable.parsed)
        prerelease_key_value = version_key(prerelease.parsed)
        beta_track = stable if stable_key >= prerelease_key_value else prerelease
    else:
        beta_track = stable or prerelease

    assert beta_track is not None

    casks_dir = args.tap_path / "Casks"
    casks_dir.mkdir(parents=True, exist_ok=True)
    sha_cache: dict[str, str] = {}

    stable_changed = False
    if stable is not None:
        stable_version = version_string(stable.parsed)
        stable_arm_name = f"Docktor-v{stable_version}-macos-arm64.zip"
        stable_intel_name = f"Docktor-v{stable_version}-macos-x64.zip"
        stable_arm_asset = find_asset(stable, stable_arm_name)
        stable_intel_asset = find_asset(stable, stable_intel_name)
        stable_arm_sha = sha256_for_asset(
            stable_arm_asset, github_token=args.github_token, cache=sha_cache
        )
        stable_intel_sha = sha256_for_asset(
            stable_intel_asset, github_token=args.github_token, cache=sha_cache
        )
        stable_changed = write_if_changed(
            casks_dir / "docktor.rb",
            render_stable_cask(
                args.repo,
                stable_version,
                stable_arm_asset.download_url,
                stable_arm_sha,
                stable_intel_asset.download_url,
                stable_intel_sha,
            ),
        )
        print(
            f"Stable cask -> {stable_version} ({'updated' if stable_changed else 'unchanged'})"
        )
    else:
        print("Stable cask unchanged (no stable releases yet)")

    beta_version = version_string(beta_track.parsed)
    beta_arm_name = f"Docktor-Beta-v{beta_version}-macos-arm64.zip"
    beta_intel_name = f"Docktor-Beta-v{beta_version}-macos-x64.zip"
    beta_arm_asset = find_asset(beta_track, beta_arm_name)
    beta_intel_asset = find_asset(beta_track, beta_intel_name)
    beta_arm_sha = sha256_for_asset(
        beta_arm_asset, github_token=args.github_token, cache=sha_cache
    )
    beta_intel_sha = sha256_for_asset(
        beta_intel_asset, github_token=args.github_token, cache=sha_cache
    )
    beta_changed = write_if_changed(
        casks_dir / "docktor@beta.rb",
        render_beta_cask(
            args.repo,
            beta_version,
            beta_arm_asset.download_url,
            beta_arm_sha,
            beta_intel_asset.download_url,
            beta_intel_sha,
        ),
    )
    print(f"Beta cask -> {beta_version} ({'updated' if beta_changed else 'unchanged'})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
