#!/usr/bin/env python3
"""Stage the exact Homebrew publication bundle from local draft assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

from build_homebrew_publication import build
from update_homebrew_tap_casks import render_beta_cask, render_stable_cask


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def asset(prefix: str, tag: str, arch: str, assets: Path) -> tuple[Path, dict]:
    name = f"{prefix}-{tag}-macos-{arch}.zip"
    path = assets / name
    if not path.is_file() or path.stat().st_size <= 0:
        raise ValueError(f"Missing release asset: {name}")
    url = f"https://github.com/apotenza92/dockmint/releases/download/{tag}/{name}"
    return path, {"name": name, "browser_download_url": url, "size": path.stat().st_size,
                  "digest": f"sha256:{sha256(path)}"}


def stage(tag: str, assets: Path, output: Path) -> None:
    version = tag.removeprefix("v")
    channel = "beta" if "-beta." in tag else "stable"
    output.mkdir(parents=True, exist_ok=True)
    casks = output / "candidate-casks"
    casks.mkdir()
    release_assets: list[dict] = []

    if channel == "stable":
        arm, arm_meta = asset("Dockmint", tag, "arm64", assets)
        intel, intel_meta = asset("Dockmint", tag, "x64", assets)
        release_assets.extend((arm_meta, intel_meta))
        (casks / "dockmint.rb").write_text(render_stable_cask(
            "dockmint", "Dockmint", "Dock gesture actions", "apotenza92/dockmint", version,
            arm_meta["browser_download_url"], sha256(arm), intel_meta["browser_download_url"], sha256(intel)))

    arm, arm_meta = asset("Dockmint-Beta", tag, "arm64", assets)
    intel, intel_meta = asset("Dockmint-Beta", tag, "x64", assets)
    release_assets.extend((arm_meta, intel_meta))
    (casks / "dockmint@beta.rb").write_text(render_beta_cask(
        "dockmint@beta", "Dockmint Beta", "Beta channel for Dockmint", "apotenza92/dockmint", version,
        arm_meta["browser_download_url"], sha256(arm), intel_meta["browser_download_url"], sha256(intel)))

    publication = output / "publication"
    build(channel, tag, os.environ["GITHUB_SHA"], int(os.environ["GITHUB_RUN_ID"]),
          int(os.environ["GITHUB_RUN_ATTEMPT"]), casks, {"assets": release_assets}, publication)
    checksum_paths = [publication / "manifest.json", *sorted((publication / "Casks").glob("*.rb"))]
    (publication / "SHA256SUMS").write_text("".join(
        f"{sha256(path)}  {path.relative_to(publication)}\n" for path in checksum_paths))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--tag", required=True); parser.add_argument("--assets", type=Path, required=True); parser.add_argument("--output", type=Path, required=True); args = parser.parse_args()
    try: stage(args.tag, args.assets, args.output)
    except (KeyError, ValueError) as exc: print(str(exc), file=sys.stderr); raise SystemExit(1)
