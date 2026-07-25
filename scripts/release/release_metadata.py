#!/usr/bin/env python3
"""Emit validated Dockmint tag metadata for local scripts and GitHub Actions."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from release_contract import MINIMUM_SYSTEM_VERSION, package_contract, require_tag


def release_matrix(is_prerelease: bool) -> dict[str, list[dict[str, str]]]:
    channels = ("beta",) if is_prerelease else ("stable", "beta")
    runners = (
        ("macos-15", "arm64", "arm64"),
        ("macos-15-intel", "x86_64", "x64"),
    )
    return {
        "include": [
            {
                "runner": runner,
                "host_arch": host_arch,
                "xcode_arch": host_arch,
                "arch": arch,
                "channel": channel,
                "product_name": "Dockmint Beta" if channel == "beta" else "Dockmint",
                "package_prefix": "Dockmint-Beta" if channel == "beta" else "Dockmint",
                "bundle_id": "pzc.Dockmint.beta" if channel == "beta" else "pzc.Dockmint",
                "app_icon": "AppIconBeta" if channel == "beta" else "AppIcon",
            }
            for channel in channels
            for runner, host_arch, arch in runners
        ]
    }


def metadata(tag: str) -> dict[str, object]:
    parsed = require_tag(tag)
    return {
        "tag": parsed.tag,
        "version": parsed.version,
        "version_core": parsed.core_version,
        "prerelease": str(parsed.is_prerelease).lower(),
        "build_number": parsed.build_number,
        "minimum_system_version": MINIMUM_SYSTEM_VERSION,
        "release_matrix": release_matrix(parsed.is_prerelease),
        "packages": [
            {
                "channel": channel,
                "arch": arch,
                "artifact": package_contract(channel, arch).artifact_name(parsed.version),
            }
            for channel in (("beta",) if parsed.is_prerelease else ("stable", "beta"))
            for arch in ("arm64", "x64")
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--github-output", action="store_true")
    args = parser.parse_args()
    values = metadata(args.tag)
    if args.github_output:
        output_path = os.environ.get("GITHUB_OUTPUT", "").strip()
        if not output_path:
            raise RuntimeError("GITHUB_OUTPUT is required with --github-output")
        scalar_keys = (
            "tag",
            "version",
            "version_core",
            "prerelease",
            "build_number",
            "minimum_system_version",
        )
        with Path(output_path).open("a", encoding="utf-8") as output:
            for key in scalar_keys:
                output.write(f"{key}={values[key]}\n")
            output.write(
                "release_matrix="
                f"{json.dumps(values['release_matrix'], separators=(',', ':'))}\n"
            )
        return 0
    print(json.dumps(values, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
