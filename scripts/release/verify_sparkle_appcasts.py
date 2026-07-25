#!/usr/bin/env python3
"""Verify Sparkle enclosure signatures against the public key bundled in the app."""

from __future__ import annotations

import argparse
import base64
import plistlib
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path

from release_contract import REPOSITORY, package_contract, require_tag


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def expected_asset_for_feed(feed_name: str, version: str) -> str:
    match = re.fullmatch(r"(stable|beta)-(arm64|x64)\.xml", feed_name)
    if match is None:
        raise ValueError(f"unexpected appcast filename: {feed_name}")
    parsed = require_tag(f"v{version}")
    channel, arch = match.groups()
    if channel == "stable" and parsed.is_prerelease:
        raise ValueError("stable appcast must not reference a prerelease version")
    return package_contract(channel, arch).artifact_name(version)


def verify_feed(feed: Path, asset_dir: Path, public_key_bytes: bytes) -> str:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    root = ET.parse(feed).getroot()
    enclosure = root.find("./channel/item/enclosure")
    if enclosure is None:
        raise ValueError(f"{feed} has no enclosure")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "")
    if not signature:
        raise ValueError(f"{feed} has no Sparkle EdDSA signature")
    url = enclosure.get("url", "")
    asset_name = Path(urllib.parse.urlparse(url).path).name
    version = root.findtext(f"./channel/item/{{{SPARKLE}}}shortVersionString", "")
    expected_asset = expected_asset_for_feed(feed.name, version)
    if asset_name != expected_asset:
        raise ValueError(
            f"{feed.name} references {asset_name!r}, expected {expected_asset!r}"
        )
    expected_url = (
        f"https://github.com/{REPOSITORY}/releases/download/v{version}/{expected_asset}"
    )
    if url != expected_url:
        raise ValueError(f"{feed.name} enclosure URL is {url!r}, expected {expected_url!r}")
    asset = asset_dir / asset_name
    if not asset.is_file():
        raise ValueError(f"{feed} references missing staged asset {asset_name}")
    payload = asset.read_bytes()
    if enclosure.get("length") != str(len(payload)):
        raise ValueError(f"{feed} enclosure length does not match {asset_name}")

    public_key = Ed25519PublicKey.from_public_bytes(public_key_bytes)
    decoded_signature = base64.b64decode(signature, validate=True)
    public_key.verify(decoded_signature, payload)
    tampered = bytearray(payload)
    if not tampered:
        raise ValueError(f"{asset_name} is empty")
    tampered[len(tampered) // 2] ^= 0x01
    try:
        public_key.verify(decoded_signature, bytes(tampered))
    except InvalidSignature:
        pass
    else:
        raise ValueError(f"tampered {asset_name} unexpectedly passed signature verification")

    minimum = root.findtext(f"./channel/item/{{{SPARKLE}}}minimumSystemVersion")
    if minimum != "14.0":
        raise ValueError(f"{feed} minimum system version is {minimum!r}")
    return asset_name


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--info-plist", type=Path, required=True)
    parser.add_argument("--appcast-dir", type=Path, required=True)
    parser.add_argument("--asset-dir", type=Path, required=True)
    args = parser.parse_args()

    info = plistlib.loads(args.info_plist.read_bytes())
    public_key_value = str(info.get("SUPublicEDKey", ""))
    public_key_bytes = base64.b64decode(public_key_value, validate=True)
    if len(public_key_bytes) != 32:
        raise ValueError("Bundled SUPublicEDKey is not a 32-byte Ed25519 public key")

    feeds = sorted(args.appcast_dir.glob("*.xml"))
    expected = {"stable-arm64.xml", "stable-x64.xml", "beta-arm64.xml", "beta-x64.xml"}
    if {feed.name for feed in feeds} != expected:
        raise ValueError(f"Unexpected appcast set: {[feed.name for feed in feeds]}")
    assets = {verify_feed(feed, args.asset_dir, public_key_bytes) for feed in feeds}
    if len(assets) not in {2, 4}:
        raise ValueError(f"Unexpected appcast asset convergence: {sorted(assets)}")
    print(f"Verified {len(feeds)} appcasts and tamper rejection: {sorted(assets)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, ET.ParseError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
