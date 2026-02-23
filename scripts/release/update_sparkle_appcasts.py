#!/usr/bin/env python3
"""Generate Sparkle appcast feeds for stable and beta channels.

Policy:
- Stable feed tracks latest stable tag (vX.Y.Z)
- Beta feed tracks whichever is newer between latest stable and latest prerelease
- Release notes are sourced from CHANGELOG.md headings (## [vX.Y.Z...])
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import datetime as dt
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
from email.utils import format_datetime
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


STABLE_TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
PRERELEASE_TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)-([0-9A-Za-z.-]+)$")


@dataclasses.dataclass(frozen=True)
class ParsedTag:
    major: int
    minor: int
    patch: int
    prerelease: str | None


@dataclasses.dataclass(frozen=True)
class ReleaseAsset:
    name: str
    size: int
    api_url: str
    download_url: str


@dataclasses.dataclass(frozen=True)
class Release:
    tag_name: str
    html_url: str
    draft: bool
    prerelease_flag: bool
    published_at: str
    assets: tuple[ReleaseAsset, ...]
    parsed: ParsedTag


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


def sparkle_build_version(parsed: ParsedTag) -> str:
    core = (parsed.major * 1_000_000) + (parsed.minor * 1_000) + parsed.patch
    if parsed.prerelease is None:
        stage = 90_000
    else:
        beta_match = re.search(
            r"(?:beta|b)[.-]?(\d+)$", parsed.prerelease, flags=re.IGNORECASE
        )
        if beta_match:
            stage = max(1, min(int(beta_match.group(1)), 89_999))
        else:
            stage = 50_000
    return str((core * 100_000) + stage)


def short_version(parsed: ParsedTag) -> str:
    base = f"{parsed.major}.{parsed.minor}.{parsed.patch}"
    if parsed.prerelease is None:
        return base
    return f"{base}-{parsed.prerelease}"


def extract_notes(changelog_path: Path, tag: str) -> str:
    if not changelog_path.exists():
        raise RuntimeError(f"Missing changelog: {changelog_path}")

    target_heading = f"## [{tag}]"
    lines = changelog_path.read_text(encoding="utf-8").splitlines()

    start = None
    for i, line in enumerate(lines):
        if line.strip() == target_heading:
            start = i + 1
            break

    if start is None:
        raise RuntimeError(f"No changelog heading found for {tag}")

    end = len(lines)
    for i in range(start, len(lines)):
        if lines[i].startswith("## ["):
            end = i
            break

    section = "\n".join(lines[start:end]).strip()
    if not section:
        section = "- Maintenance release."
    return section


def fetch_releases(repo: str, github_token: str | None) -> list[Release]:
    url = f"https://api.github.com/repos/{repo}/releases"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "docktor-sparkle-appcast-sync",
    }
    if github_token:
        headers["Authorization"] = f"Bearer {github_token}"

    req = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Failed to fetch releases from {repo}: {exc}") from exc

    releases: list[Release] = []
    for item in payload:
        parsed = parse_tag(item.get("tag_name", ""))
        if parsed is None:
            continue

        assets = tuple(
            ReleaseAsset(
                name=str(asset.get("name", "")),
                size=int(asset.get("size", 0)),
                api_url=str(asset.get("url", "")),
                download_url=str(asset.get("browser_download_url", "")),
            )
            for asset in item.get("assets", [])
        )

        releases.append(
            Release(
                tag_name=str(item.get("tag_name", "")),
                html_url=str(item.get("html_url", "")),
                draft=bool(item.get("draft", False)),
                prerelease_flag=bool(item.get("prerelease", False)),
                published_at=str(item.get("published_at", "")),
                assets=assets,
                parsed=parsed,
            )
        )

    return [release for release in releases if not release.draft]


def pick_latest(releases: list[Release]) -> Release | None:
    if not releases:
        return None
    return max(releases, key=lambda release: version_key(release.parsed))


def find_asset(release: Release, asset_name: str) -> ReleaseAsset:
    for asset in release.assets:
        if asset.name == asset_name:
            return asset
    raise RuntimeError(f"Asset '{asset_name}' not found in release {release.tag_name}")


def to_rfc2822(iso_timestamp: str) -> str:
    if not iso_timestamp:
        return format_datetime(dt.datetime.now(dt.timezone.utc))
    parsed = dt.datetime.fromisoformat(iso_timestamp.replace("Z", "+00:00"))
    return format_datetime(parsed)


def load_signing_key(signing_secret: str | None) -> Ed25519PrivateKey | None:
    if signing_secret is None:
        return None
    normalized = signing_secret.strip()
    if not normalized:
        return None

    decoded = base64.b64decode(normalized)
    if len(decoded) == 32:
        return Ed25519PrivateKey.from_private_bytes(decoded)
    if len(decoded) == 64:
        return Ed25519PrivateKey.from_private_bytes(decoded[:32])

    raise RuntimeError(
        "Unsupported Sparkle private key format. Expected base64-encoded 32-byte seed."
    )


def download_asset(
    asset: ReleaseAsset, destination: Path, github_token: str | None = None
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)

    headers = {"User-Agent": "docktor-sparkle-signature-sync"}
    download_url = asset.download_url
    if github_token and asset.api_url:
        # Private repositories require authenticated asset fetches via API URL.
        headers["Authorization"] = f"Bearer {github_token}"
        headers["Accept"] = "application/octet-stream"
        download_url = asset.api_url
    else:
        headers["Accept"] = "application/octet-stream"

    request = urllib.request.Request(download_url, headers=headers)

    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    destination.write_bytes(data)


def sign_asset(
    asset: ReleaseAsset,
    private_key: Ed25519PrivateKey,
    cache_dir: Path,
    github_token: str | None = None,
) -> str:
    path = cache_dir / asset.name

    if not path.exists() or path.stat().st_size != asset.size:
        download_asset(asset, path, github_token=github_token)

    payload = path.read_bytes()
    signature = private_key.sign(payload)
    return base64.b64encode(signature).decode("ascii")


def render_appcast(
    *,
    channel_name: str,
    repo: str,
    release: Release,
    asset: ReleaseAsset,
    notes: str,
    signature: str | None,
) -> str:
    update_title = short_version(release.parsed)
    sparkle_version = sparkle_build_version(release.parsed)
    published = to_rfc2822(release.published_at)
    escaped_notes = notes.replace("]]>", "]]]]><![CDATA[>")
    changelog_url = f"https://github.com/{repo}/blob/main/CHANGELOG.md"

    signature_xml = ""
    if signature:
        signature_xml = f'\n                 sparkle:edSignature="{signature}"'

    return f"""<?xml version=\"1.0\" encoding=\"utf-8\"?>
<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\">
  <channel>
    <title>Docktor {channel_name} Updates</title>
    <description>Docktor update feed ({channel_name.lower()} channel)</description>
    <language>en</language>
    <item>
      <title>Version {update_title}</title>
      <link>{release.html_url}</link>
      <sparkle:version>{sparkle_version}</sparkle:version>
      <sparkle:shortVersionString>{update_title}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{changelog_url}</sparkle:fullReleaseNotesLink>
      <description sparkle:format=\"plain-text\"><![CDATA[{escaped_notes}]]></description>
      <pubDate>{published}</pubDate>
      <enclosure url=\"{asset.download_url}\"{signature_xml}
                 length=\"{asset.size}\"
                 type=\"application/octet-stream\" />
    </item>
  </channel>
</rss>
"""


def write_if_changed(path: Path, content: str) -> bool:
    existing = path.read_text(encoding="utf-8") if path.exists() else None
    if existing == content:
        return False
    path.write_text(content, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo",
        default="apotenza92/docktor",
        help="GitHub repository owner/name",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("appcasts"),
        help="Directory where appcast XML files are written",
    )
    parser.add_argument(
        "--changelog",
        type=Path,
        default=Path("CHANGELOG.md"),
        help="Path to unified changelog markdown file",
    )
    parser.add_argument(
        "--github-token",
        default=None,
        help="GitHub token for API requests (optional, can also use GITHUB_TOKEN env var)",
    )
    parser.add_argument(
        "--sparkle-private-key",
        default=None,
        help="Sparkle private key secret (base64-encoded 32-byte seed)",
    )
    parser.add_argument(
        "--require-signatures",
        action="store_true",
        help="Fail if no Sparkle private key is available",
    )
    args = parser.parse_args()

    github_token = args.github_token or os.environ.get("GITHUB_TOKEN")
    signing_secret = args.sparkle_private_key or os.environ.get(
        "SPARKLE_PRIVATE_ED_KEY"
    )
    private_key = load_signing_key(signing_secret)

    if args.require_signatures and private_key is None:
        raise RuntimeError(
            "Missing Sparkle private key. Set SPARKLE_PRIVATE_ED_KEY or --sparkle-private-key."
        )

    releases = fetch_releases(args.repo, github_token)

    stable = pick_latest(
        [release for release in releases if release.parsed.prerelease is None]
    )
    prerelease = pick_latest(
        [release for release in releases if release.parsed.prerelease is not None]
    )

    if stable is None and prerelease is None:
        print("No releases found; skipping appcast generation.")
        return 0

    if stable is None:
        raise RuntimeError(
            "At least one stable release is required for stable appcast generation"
        )

    if prerelease is not None and version_key(prerelease.parsed) > version_key(
        stable.parsed
    ):
        beta_track = prerelease
    else:
        beta_track = stable

    args.output_dir.mkdir(parents=True, exist_ok=True)

    stable_version = short_version(stable.parsed)
    beta_version = short_version(beta_track.parsed)

    stable_arm_asset = find_asset(
        stable, f"Docktor-v{stable_version}-macos-arm64.zip"
    )
    stable_x64_asset = find_asset(
        stable, f"Docktor-v{stable_version}-macos-x64.zip"
    )
    beta_arm_asset = find_asset(
        beta_track,
        f"Docktor-Beta-v{beta_version}-macos-arm64.zip",
    )
    beta_x64_asset = find_asset(
        beta_track,
        f"Docktor-Beta-v{beta_version}-macos-x64.zip",
    )

    stable_notes = extract_notes(args.changelog, stable.tag_name)
    beta_notes = extract_notes(args.changelog, beta_track.tag_name)

    signatures: dict[str, str] = {}
    if private_key is not None:
        with tempfile.TemporaryDirectory(
            prefix="docktor-sparkle-sign-"
        ) as temp_dir:
            cache_dir = Path(temp_dir)
            unique_assets = {
                stable_arm_asset.name: stable_arm_asset,
                stable_x64_asset.name: stable_x64_asset,
                beta_arm_asset.name: beta_arm_asset,
                beta_x64_asset.name: beta_x64_asset,
            }
            for asset in unique_assets.values():
                signatures[asset.name] = sign_asset(
                    asset, private_key, cache_dir, github_token=github_token
                )

    appcasts = {
        "stable-arm64.xml": render_appcast(
            channel_name="Stable",
            repo=args.repo,
            release=stable,
            asset=stable_arm_asset,
            notes=stable_notes,
            signature=signatures.get(stable_arm_asset.name),
        ),
        "stable-x64.xml": render_appcast(
            channel_name="Stable",
            repo=args.repo,
            release=stable,
            asset=stable_x64_asset,
            notes=stable_notes,
            signature=signatures.get(stable_x64_asset.name),
        ),
        "beta-arm64.xml": render_appcast(
            channel_name="Beta",
            repo=args.repo,
            release=beta_track,
            asset=beta_arm_asset,
            notes=beta_notes,
            signature=signatures.get(beta_arm_asset.name),
        ),
        "beta-x64.xml": render_appcast(
            channel_name="Beta",
            repo=args.repo,
            release=beta_track,
            asset=beta_x64_asset,
            notes=beta_notes,
            signature=signatures.get(beta_x64_asset.name),
        ),
    }

    changed_files = 0
    for filename, content in appcasts.items():
        path = args.output_dir / filename
        did_change = write_if_changed(path, content)
        changed_files += 1 if did_change else 0
        print(f"{filename}: {'updated' if did_change else 'unchanged'}")

    print(f"Appcast generation complete ({changed_files} files changed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
