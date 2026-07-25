#!/usr/bin/env python3
"""Validate permanent Dockmint release invariants without credentials."""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path

from release_contract import (
    MINIMUM_SYSTEM_VERSION,
    REPOSITORY,
    SPARKLE_PUBLIC_ED_KEY,
    package_contract,
    require_tag,
)


ROOT = Path(__file__).resolve().parents[2]
TEXT_SUFFIXES = {
    ".c",
    ".h",
    ".json",
    ".md",
    ".m",
    ".plist",
    ".py",
    ".rb",
    ".sh",
    ".swift",
    ".xml",
    ".yaml",
    ".yml",
}


def validate_project(tag: str) -> None:
    parsed = require_tag(tag)
    project = (ROOT / "Dockmint.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    versions = set(re.findall(r"MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);", project))
    if versions != {parsed.core_version}:
        raise ValueError(
            f"MARKETING_VERSION values {sorted(versions)} must equal {parsed.core_version}"
        )
    targets = set(re.findall(r"MACOSX_DEPLOYMENT_TARGET = ([0-9]+\.[0-9]+);", project))
    if targets != {MINIMUM_SYSTEM_VERSION}:
        raise ValueError(
            f"deployment targets {sorted(targets)} must equal {MINIMUM_SYSTEM_VERSION}"
        )
    required = (
        "ENABLE_HARDENED_RUNTIME = YES;",
        "ENABLE_APP_SANDBOX = NO;",
        "PRODUCT_BUNDLE_IDENTIFIER = pzc.Dockmint;",
    )
    for token in required:
        if token not in project:
            raise ValueError(f"project is missing release invariant: {token}")


def validate_plist() -> None:
    info = plistlib.loads((ROOT / "Dockmint/Info.plist").read_bytes())
    if info.get("SUPublicEDKey") != SPARKLE_PUBLIC_ED_KEY:
        raise ValueError("Info.plist Sparkle public key changed")
    if info.get("SUVerifyUpdateBeforeExtraction") is not True:
        raise ValueError("Info.plist must verify updates before extraction")
    for key in ("SUAutomaticallyUpdate", "SUEnableAutomaticChecks", "SUEnableInstallerLauncherService"):
        if info.get(key) is not False:
            raise ValueError(f"Info.plist must explicitly disable {key}")
    if info.get("LSUIElement") is not True:
        raise ValueError("Dockmint must remain an LSUIElement app")
    if info.get("CFBundleIconName") != "$(ASSETCATALOG_COMPILER_APPICON_NAME)":
        raise ValueError("Info.plist must bind CFBundleIconName to the selected asset catalog")
    schemes = set(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"])
    if schemes != {"dockmint", "docktor", "dockter"}:
        raise ValueError(f"release URL schemes changed unexpectedly: {sorted(schemes)}")


def validate_changelog(tag: str) -> None:
    heading = f"## [{tag}]"
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    if heading not in changelog.splitlines():
        raise ValueError(f"CHANGELOG.md must include heading: {heading}")


def validate_contracts() -> None:
    expected = {
        ("stable", "arm64"): ("pzc.Dockmint", "Dockmint.app"),
        ("stable", "x64"): ("pzc.Dockmint", "Dockmint.app"),
        ("beta", "arm64"): ("pzc.Dockmint.beta", "Dockmint Beta.app"),
        ("beta", "x64"): ("pzc.Dockmint.beta", "Dockmint Beta.app"),
    }
    for key, values in expected.items():
        contract = package_contract(*key)
        if (contract.bundle_id, contract.app_name) != values:
            raise ValueError(f"package contract changed for {key}")
        if REPOSITORY not in contract.feed_url:
            raise ValueError(f"package feed is not hosted by {REPOSITORY}")


def validate_release_workflow() -> None:
    workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    build = workflow.split("  build-macos:", 1)[1].split(
        "  stage-draft-release:", 1
    )[0]
    gate = workflow.split("  sparkle-update-gate:", 1)[1].split(
        "  publish-release:", 1
    )[0]
    policy = workflow.split("  verify-release-policy:", 1)[1].split(
        "  stage-draft-release:", 1
    )[0]
    draft = workflow.split("  stage-draft-release:", 1)[1].split(
        "  generate-signed-appcasts:", 1
    )[0]
    requirements = {
        "candidate certificate variable": (
            build,
            "APPLE_SIGNING_CERTIFICATE_SHA256: ${{ vars.APPLE_SIGNING_CERTIFICATE_SHA256 }}",
        ),
        "candidate certificate verifier argument": (
            build,
            '--certificate-sha256 "$APPLE_SIGNING_CERTIFICATE_SHA256"',
        ),
        "channel-aware updater matrix": (
            gate,
            "matrix: ${{ fromJSON(needs.prepare.outputs.release_matrix) }}",
        ),
        "updater candidate certificate variable": (
            gate,
            "APPLE_SIGNING_CERTIFICATE_SHA256: ${{ vars.APPLE_SIGNING_CERTIFICATE_SHA256 }}",
        ),
        "updater candidate certificate verifier argument": (
            gate,
            '--candidate-certificate-sha256 "$APPLE_SIGNING_CERTIFICATE_SHA256"',
        ),
        "N-1 prior certificate variable": (
            gate,
            "APPLE_PRIOR_SIGNING_CERTIFICATE_SHA256: ${{ vars.APPLE_PRIOR_SIGNING_CERTIFICATE_SHA256 }}",
        ),
        "N-1 prior certificate verifier argument": (
            gate,
            '--prior-certificate-sha256 "$APPLE_PRIOR_SIGNING_CERTIFICATE_SHA256"',
        ),
    }
    for label, (section, token) in requirements.items():
        if token not in section:
            raise ValueError(f"release workflow is missing {label}")
    if "APPLE_PRIOR_SIGNING_CERTIFICATE_SHA256" in build:
        raise ValueError("candidate packages must not use the prior signing certificate pin")
    if "environment:" in gate or "secrets." in gate:
        raise ValueError("Sparkle update verification must not access a secret-bearing environment")
    if "release_matrix: ${{ steps.meta.outputs.release_matrix }}" not in workflow:
        raise ValueError("prepare job must expose the channel-aware native release matrix")
    if "secrets.APPLE_PRIOR_SIGNING_CERTIFICATE_SHA256" in workflow:
        raise ValueError("the prior signing certificate fingerprint must be a variable, not a secret")
    if "needs:\n      - prepare\n    runs-on:" not in policy:
        raise ValueError("immutable-release policy must depend only on prepared metadata")
    if "stage-draft-release" in policy or "sparkle-update-gate" in policy:
        raise ValueError("immutable-release policy must run before draft staging")
    if "- verify-release-policy" not in draft:
        raise ValueError("draft staging must require immutable-release policy verification")
    if workflow.index("  verify-release-policy:") > workflow.index("  stage-draft-release:"):
        raise ValueError("immutable-release policy must precede draft staging")


def validate_origin() -> None:
    result = subprocess.run(
        ["git", "remote", "get-url", "origin"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    origin = result.stdout.strip()
    canonical = re.compile(
        r"^(https://github\.com/|git@github\.com:)apotenza92/dockmint(?:\.git)?$"
    )
    if result.returncode != 0 or canonical.fullmatch(origin) is None:
        raise ValueError(f"canonical releases require apotenza92/dockmint; origin is {origin!r}")


def repository_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
        capture_output=True,
        check=True,
    )
    return [
        ROOT / raw.decode("utf-8")
        for raw in result.stdout.split(b"\0")
        if raw and (ROOT / raw.decode("utf-8")).exists()
    ]


def validate_repository_hygiene() -> None:
    files = repository_files()
    stale_names = re.compile(
        r"^(?:memory|plan|now|worklog|backlog|roadmap|handoff)(?:[-_.].*)?\.md$",
        re.IGNORECASE,
    )
    generated_path = re.compile(
        r"^(?:DerivedData|build|release|artifacts|test-results|coverage|\.build)(?:/|$)"
    )
    retired_secret = re.compile(
        r"\b(?:APPLE_ID|APPLE_APP_SPECIFIC_PASSWORD|CSC_LINK|CSC_KEY_PASSWORD|DOCKMINT_(?:APPLE|CSC|NOTARY)[A-Z0-9_]*)\b"
    )
    obsolete_paths = {
        "scripts/release/validate_dockmint_migration.py",
        ".github/workflows/packages.yml",
    }

    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        if (
            relative.startswith(("plans/", "evidence/"))
            or stale_names.fullmatch(path.name)
        ):
            raise ValueError(f"changing work state must not be tracked: {relative}")
        if generated_path.match(relative) or relative.endswith((".xcresult", ".pyc")):
            raise ValueError(f"generated output must not be tracked: {relative}")
        if relative in obsolete_paths:
            raise ValueError(f"obsolete release path must not return: {relative}")

        if path.suffix.lower() not in TEXT_SUFFIXES and path.name not in {
            "Package.swift",
            "project.pbxproj",
        }:
            continue
        text = path.read_text(encoding="utf-8")
        if re.search(r"/(?:Users|home)/[^/]+/", text):
            raise ValueError(f"machine-specific home path is tracked in {relative}")

        is_release_source = (
            relative.startswith(".github/workflows/")
            or relative.startswith("scripts/release/")
            or relative == "scripts/release.sh"
        )
        if (
            is_release_source
            and not relative.startswith("scripts/release/tests/")
            and relative != "scripts/release/validate_release_contract.py"
        ):
            if retired_secret.search(text):
                raise ValueError(f"retired release secret name remains in {relative}")

        if relative.startswith(".github/workflows/"):
            for action in re.findall(r"^\s*uses:\s*([^\s#]+)", text, re.MULTILINE):
                if not action.startswith("./") and re.search(r"@[0-9a-f]{40}$", action) is None:
                    raise ValueError(
                        f"third-party Action is not pinned to a full commit in {relative}: {action}"
                    )
            references = [
                match.removeprefix("./")
                for match in re.findall(
                    r"(?:^|[\s'\"`])(\.?/?scripts/[A-Za-z0-9._/-]+\.(?:py|sh))",
                    text,
                    re.MULTILINE,
                )
            ]
            for reference in references:
                if not (ROOT / reference).exists():
                    raise ValueError(f"{relative} references missing path: {reference}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--require-canonical-origin", action="store_true")
    args = parser.parse_args()
    checks = [
        ("project", lambda: validate_project(args.tag)),
        ("plist", validate_plist),
        ("changelog", lambda: validate_changelog(args.tag)),
        ("package contracts", validate_contracts),
        ("release workflow", validate_release_workflow),
        ("repository hygiene", validate_repository_hygiene),
    ]
    if args.require_canonical_origin:
        checks.append(("canonical origin", validate_origin))
    for label, check in checks:
        try:
            check()
        except (KeyError, OSError, subprocess.SubprocessError, ValueError) as exc:
            print(f"FAIL {label}: {exc}", file=sys.stderr)
            return 1
        print(f"PASS {label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
