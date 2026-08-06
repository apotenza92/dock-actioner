#!/usr/bin/env python3
"""Build the common Homebrew publication bundle from reviewed Dockmint casks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(channel: str, tag: str, commit: str, run_id: int, run_attempt: int,
          casks_dir: Path, release_assets: dict, output: Path) -> dict:
    if channel not in {"stable", "beta"} or not re.fullmatch(r"v\d+\.\d+\.\d+(?:-beta\.[1-9]\d*)?", tag):
        raise ValueError("Invalid release identity")
    channels = ["beta"] if channel == "beta" else ["stable", "beta"]
    filenames = ["dockmint@beta.rb"] if channel == "beta" else ["dockmint.rb", "dockmint@beta.rb"]
    assets_by_name = {asset["name"]: asset for asset in release_assets["assets"]}
    output_casks = output / "Casks"
    output_casks.mkdir(parents=True)
    artifacts = []
    for publication_channel, filename in zip(channels, filenames):
        source = casks_dir / filename
        text = source.read_text()
        shutil.copyfile(source, output_casks / filename)
        version = re.search(r'^\s*version\s+"([^"]+)"', text, re.MULTILINE)
        if not version or f"v{version.group(1)}" != tag:
            raise ValueError(f"Cask version mismatch: {filename}")
        shas = re.findall(r'^\s*sha256\s+"([0-9a-f]{64})"', text, re.MULTILINE)
        urls = re.findall(r'^\s*url\s+"(https://github\.com/[^\"]+/releases/download/[^\"]+)"', text, re.MULTILINE)
        if len(shas) != 2 or len(urls) != 2:
            raise ValueError(f"Cask architecture contract mismatch: {filename}")
        for architecture, digest, url in zip(("arm64", "x64"), shas, urls):
            resolved_url = url.replace("v#{version}", tag)
            name = resolved_url.rsplit("/", 1)[-1]
            asset = assets_by_name.get(name)
            if (not asset or asset.get("digest") != f"sha256:{digest}"
                    or not isinstance(asset.get("size"), int) or asset["size"] <= 0):
                raise ValueError(f"Public release asset mismatch: {name}")
            artifacts.append({"name": name, "url": resolved_url, "size": asset["size"],
                              "sha256": digest, "channel": publication_channel,
                              "architecture": architecture})
    manifest = {
        "schema_version": 1,
        "product": "dockmint",
        "source_repository": "apotenza92/dockmint",
        "release_tag": tag,
        "release_commit": commit,
        "channel": channel,
        "casks": filenames,
        "artifacts": artifacts,
        "applications": {value: "Dockmint.app" if value == "stable" else "Dockmint Beta.app" for value in channels},
        "bundle_identifiers": {value: "pzc.Dockmint" if value == "stable" else "pzc.Dockmint.beta" for value in channels},
        "architectures": ["arm64", "x64"],
        "minimum_macos": "14.0",
        "native_validation": {"workflow_run_id": run_id, "workflow_run_attempt": run_attempt,
                              "jobs": ["Validate Homebrew casks (arm64)", "Validate Homebrew casks (x86_64)"]},
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--channel", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--casks", required=True, type=Path)
    parser.add_argument("--release-assets", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    build(args.channel, args.tag, os.environ["GITHUB_SHA"], int(os.environ["GITHUB_RUN_ID"]),
          int(os.environ["GITHUB_RUN_ATTEMPT"]), args.casks,
          json.loads(args.release_assets.read_text()), args.output)


if __name__ == "__main__":
    main()
