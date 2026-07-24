#!/usr/bin/env python3
"""Strictly verify one signed, notarized Dockmint release ZIP."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path, PurePosixPath

from release_contract import (
    MINIMUM_SYSTEM_VERSION,
    SPARKLE_PUBLIC_ED_KEY,
    package_contract,
)


MACH_O_MARKER = "Mach-O"
SIGNED_BUNDLE_SUFFIXES = {".app", ".framework", ".xpc"}
ALLOWED_ENTITLEMENTS = {
    "com.apple.security.files.user-selected.read-only": True,
    "com.apple.application-identifier": "org.sparkle-project.Sparkle.Autoupdate",
}
REQUIRED_SPARKLE_PATHS = (
    "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
)


def normalize_fingerprint(value: str) -> str:
    normalized = re.sub(r"[^0-9A-Fa-f]", "", value).upper()
    if len(normalized) != 64:
        raise ValueError(f"expected a SHA-256 certificate fingerprint, got {value!r}")
    return normalized


def run(
    command: list[str],
    *,
    check: bool = True,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_bytes: bytes | None = None,
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode != 0:
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"{' '.join(command)} failed ({result.returncode}): {output}")
    return result


def validate_zip_entries(archive: Path) -> None:
    seen: set[str] = set()
    with zipfile.ZipFile(archive) as bundle:
        if not bundle.infolist():
            raise ValueError("release ZIP is empty")
        for entry in bundle.infolist():
            raw_name = entry.filename.replace("\\", "/")
            path = PurePosixPath(raw_name)
            if raw_name.startswith("/") or ".." in path.parts or not path.parts:
                raise ValueError(f"unsafe ZIP path: {entry.filename}")
            normalized = str(path)
            if normalized in seen:
                raise ValueError(f"duplicate ZIP path: {entry.filename}")
            seen.add(normalized)

            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                target = bundle.read(entry).decode("utf-8", errors="strict")
                resolved = path.parent.joinpath(target)
                if target.startswith("/") or ".." in resolved.parts:
                    raise ValueError(f"unsafe ZIP symlink: {entry.filename} -> {target}")


def parse_codesign_details(output: str) -> dict[str, object]:
    authorities: list[str] = []
    values: dict[str, object] = {"authorities": authorities}
    for line in output.splitlines():
        if line.startswith("Authority="):
            authorities.append(line.removeprefix("Authority="))
        elif line.startswith("CodeDirectory ") and " flags=" in line:
            match = re.search(r"\bflags=([^ ]+)", line)
            if match:
                values["flags"] = match.group(1)
        elif "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def plist_from_codesign_output(data: bytes) -> dict[str, object]:
    xml_index = data.find(b"<?xml")
    binary_index = data.find(b"bplist")
    starts = [value for value in (xml_index, binary_index) if value >= 0]
    if not starts:
        return {}
    payload = data[min(starts) :]
    if payload.startswith(b"<?xml"):
        end = payload.find(b"</plist>")
        if end >= 0:
            payload = payload[: end + len(b"</plist>")]
    return plistlib.loads(payload)


def validate_notarization_log(path: Path) -> None:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("status") != "Accepted":
        raise ValueError(f"notarization log status is {data.get('status')!r}, expected 'Accepted'")
    issues = data.get("issues")
    if issues is None:
        issues = []
    if not isinstance(issues, list):
        raise ValueError("notarization log issues must be a list")
    errors = [issue for issue in issues if str(issue.get("severity", "")).lower() == "error"]
    if errors:
        raise ValueError(f"notarization log contains {len(errors)} error issue(s)")


def validate_checksum(archive: Path, checksum_path: Path) -> None:
    line = checksum_path.read_text(encoding="utf-8").strip()
    match = re.fullmatch(r"([0-9a-fA-F]{64})  (.+)", line)
    if match is None or match.group(2) != archive.name:
        raise ValueError(f"invalid checksum file format: {checksum_path}")
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual.lower() != match.group(1).lower():
        raise ValueError(f"checksum mismatch for {archive}")


def validate_sparkle_contract(app: Path, info: dict[str, object]) -> None:
    plist_expectations = {
        "SUPublicEDKey": SPARKLE_PUBLIC_ED_KEY,
        "SUVerifyUpdateBeforeExtraction": True,
        "SUAutomaticallyUpdate": False,
        "SUEnableAutomaticChecks": False,
        "SUEnableInstallerLauncherService": False,
    }
    for key, expected in plist_expectations.items():
        actual = info.get(key, False) if expected is False else info.get(key)
        if actual != expected:
            raise ValueError(f"{key} is {info.get(key)!r}, expected {expected!r}")
    missing = [relative for relative in REQUIRED_SPARKLE_PATHS if not (app / relative).exists()]
    if missing:
        raise ValueError(f"required Sparkle helpers are missing: {missing}")


def validate_icon_contract(
    app: Path, info: dict[str, object], expected_icon_name: str
) -> None:
    actual_icon_name = str(info.get("CFBundleIconName", ""))
    if actual_icon_name != expected_icon_name:
        raise ValueError(
            f"CFBundleIconName is {actual_icon_name!r}, expected {expected_icon_name!r}"
        )
    asset_catalog = app / "Contents/Resources/Assets.car"
    if not asset_catalog.is_file():
        raise ValueError("packaged app is missing Contents/Resources/Assets.car")
    try:
        assets = json.loads(
            run(["xcrun", "assetutil", "--info", str(asset_catalog)]).stdout
        )
    except json.JSONDecodeError as exc:
        raise ValueError("assetutil returned invalid JSON for packaged Assets.car") from exc
    if not isinstance(assets, list):
        raise ValueError("assetutil did not return an asset list")
    matching_assets = [
        asset
        for asset in assets
        if isinstance(asset, dict) and asset.get("Name") == expected_icon_name
    ]
    if not matching_assets:
        raise ValueError(
            f"packaged Assets.car does not contain icon asset {expected_icon_name!r}"
        )


def is_mach_o(path: Path) -> bool:
    return MACH_O_MARKER in run(["file", "-b", str(path)]).stdout.decode("utf-8", errors="replace")


def code_targets(app: Path) -> list[Path]:
    targets: set[Path] = {app}
    for path in app.rglob("*"):
        if path.is_dir() and path.suffix in SIGNED_BUNDLE_SUFFIXES:
            targets.add(path)
        elif path.is_file() and is_mach_o(path):
            targets.add(path)
    return sorted(targets, key=lambda item: (len(item.parts), str(item)))


def extract_certificate_fingerprint(target: Path, directory: Path, index: int) -> str:
    prefix = directory / f"certificate-{index}-"
    run(["codesign", "-d", f"--extract-certificates={prefix}", str(target)])
    leaf = Path(f"{prefix}0")
    if not leaf.exists():
        raise ValueError(f"codesign did not extract a leaf certificate for {target}")
    return hashlib.sha256(leaf.read_bytes()).hexdigest().upper()


def verify_code_target(
    target: Path,
    *,
    identity: str,
    team_id: str,
    fingerprint: str,
    certificate_dir: Path,
    certificate_index: int,
) -> None:
    run(["codesign", "--verify", "--strict", "--verbose=2", str(target)])
    details_result = run(["codesign", "-dvvv", "--verbose=4", str(target)])
    details_text = (details_result.stdout + details_result.stderr).decode("utf-8", errors="replace")
    details = parse_codesign_details(details_text)
    authorities = details["authorities"]
    if not authorities or authorities[0] != identity:
        raise ValueError(f"{target} signer is {authorities!r}, expected {identity!r}")
    if details.get("TeamIdentifier") != team_id:
        raise ValueError(f"{target} TeamIdentifier is {details.get('TeamIdentifier')!r}")
    flags = str(details.get("flags", ""))
    if "runtime" not in flags:
        raise ValueError(f"{target} is missing hardened runtime")
    timestamp = str(details.get("Timestamp", ""))
    if not timestamp or timestamp.lower() in {"none", "n/a"}:
        raise ValueError(f"{target} is missing a secure signing timestamp")
    actual_fingerprint = extract_certificate_fingerprint(
        target, certificate_dir, certificate_index
    )
    if actual_fingerprint != fingerprint:
        raise ValueError(
            f"{target} certificate is {actual_fingerprint}, expected {fingerprint}"
        )

    entitlement_result = run(
        ["codesign", "-d", "--entitlements", ":-", str(target)], check=False
    )
    entitlement_data = entitlement_result.stdout + entitlement_result.stderr
    entitlements = plist_from_codesign_output(entitlement_data)
    if entitlements.get("com.apple.security.get-task-allow") is True:
        raise ValueError(f"{target} enables com.apple.security.get-task-allow")
    unexpected_entitlements = {
        key
        for key, value in entitlements.items()
        if key not in ALLOWED_ENTITLEMENTS or ALLOWED_ENTITLEMENTS[key] != value
    }
    if unexpected_entitlements:
        raise ValueError(
            f"{target} has unexpected entitlements: {sorted(unexpected_entitlements)}"
        )


def verify_certificate_chain(app: Path, directory: Path) -> None:
    prefix = directory / "chain-"
    run(["codesign", "-d", f"--extract-certificates={prefix}", str(app)])
    leaf = Path(f"{prefix}0")
    intermediate = Path(f"{prefix}1")
    root = Path(f"{prefix}2")
    if not all(path.exists() for path in (leaf, intermediate, root)):
        raise ValueError("app signature does not include a complete certificate chain")
    run(
        [
            "security",
            "verify-cert",
            "-N",
            "-L",
            "-p",
            "codeSign",
            "-c",
            str(leaf),
            "-c",
            str(intermediate),
            "-r",
            str(root),
        ]
    )


def launch_smoke(app: Path, temp_dir: Path) -> None:
    executable_name = plistlib.loads((app / "Contents/Info.plist").read_bytes())[
        "CFBundleExecutable"
    ]
    executable = app / "Contents/MacOS" / str(executable_name)
    smoke_home = temp_dir / "smoke-home"
    smoke_home.mkdir(mode=0o700)
    smoke_tmp = temp_dir / "smoke-tmp"
    smoke_tmp.mkdir(mode=0o700)
    environment = {
        "HOME": str(smoke_home),
        "TMPDIR": f"{smoke_tmp}/",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "USER": "dockmint-release-smoke",
        "LOGNAME": "dockmint-release-smoke",
        "DOCKMINT_TEST_SUITE": "1",
        "DOCKMINT_DEBUG_LOG": "0",
    }
    process = subprocess.Popen(
        [str(executable), "-ApplePersistenceIgnoreState", "YES"],
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(3)
        if process.poll() is not None:
            raise ValueError(f"packaged app exited during launch smoke with {process.returncode}")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def verify(args: argparse.Namespace) -> None:
    contract = package_contract(args.channel, args.arch)
    archive = args.zip.resolve()
    if archive.name != contract.artifact_name(args.version):
        raise ValueError(
            f"artifact is {archive.name}, expected {contract.artifact_name(args.version)}"
        )
    if not archive.is_file():
        raise ValueError(f"release ZIP does not exist: {archive}")
    validate_zip_entries(archive)
    run(["unzip", "-tq", str(archive)])
    validate_checksum(archive, args.checksum.resolve())
    validate_notarization_log(args.notarization_log.resolve())
    fingerprint = normalize_fingerprint(args.certificate_sha256)

    with tempfile.TemporaryDirectory(prefix="dockmint-package-verifier-") as raw_temp:
        temp_dir = Path(raw_temp)
        extracted = temp_dir / "extracted"
        extracted.mkdir()
        run(["ditto", "-x", "-k", str(archive), str(extracted)])
        apps = [path for path in extracted.iterdir() if path.suffix == ".app" and path.is_dir()]
        if [path.name for path in apps] != [contract.app_name]:
            raise ValueError(f"archive apps are {[path.name for path in apps]!r}, expected {contract.app_name!r}")
        app = apps[0]
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        validate_sparkle_contract(app, info)
        validate_icon_contract(app, info, contract.icon_name)
        expectations = {
            "CFBundleIdentifier": contract.bundle_id,
            "CFBundleDisplayName": contract.product_name,
            "CFBundleShortVersionString": args.version,
            "CFBundleVersion": args.build_number,
            "SUFeedURL": contract.feed_url,
            "SUPublicEDKey": SPARKLE_PUBLIC_ED_KEY,
        }
        for key, expected in expectations.items():
            if str(info.get(key, "")) != expected:
                raise ValueError(f"{key} is {info.get(key)!r}, expected {expected!r}")

        expected_arch = contract.xcode_arch
        main_executable = app / "Contents/MacOS" / str(info["CFBundleExecutable"])
        targets = code_targets(app)
        mach_o_targets = [target for target in targets if target.is_file() and is_mach_o(target)]
        if not mach_o_targets:
            raise ValueError("archive contains no Mach-O files")
        for target in mach_o_targets:
            architectures = run(["lipo", "-archs", str(target)]).stdout.decode().split()
            if target == main_executable:
                if architectures != [expected_arch]:
                    raise ValueError(
                        f"main executable architectures are {architectures}, expected {[expected_arch]}"
                    )
            elif expected_arch not in architectures or not set(architectures) <= {"arm64", "x86_64"}:
                raise ValueError(
                    f"{target} architectures are {architectures}, expected support for {expected_arch}"
                )

        certificate_dir = temp_dir / "certificates"
        certificate_dir.mkdir(mode=0o700)
        run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
        for index, target in enumerate(targets):
            verify_code_target(
                target,
                identity=args.identity,
                team_id=args.team_id,
                fingerprint=fingerprint,
                certificate_dir=certificate_dir,
                certificate_index=index,
            )
        verify_certificate_chain(app, certificate_dir)
        run(["xcrun", "stapler", "validate", str(app)])
        run(["spctl", "-a", "-vv", "--type", "execute", str(app)])
        if not args.skip_launch:
            launch_smoke(app, temp_dir)

    print(
        f"Verified {contract.channel}/{contract.arch} Dockmint package: "
        f"{archive.name} (minimum macOS {MINIMUM_SYSTEM_VERSION})"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip", type=Path, required=True)
    parser.add_argument("--checksum", type=Path, required=True)
    parser.add_argument("--notarization-log", type=Path, required=True)
    parser.add_argument("--channel", choices=("stable", "beta"), required=True)
    parser.add_argument("--arch", choices=("arm64", "x64"), required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--certificate-sha256", required=True)
    parser.add_argument("--skip-launch", action="store_true")
    args = parser.parse_args()
    try:
        verify(args)
    except (OSError, RuntimeError, ValueError, KeyError, plistlib.InvalidFileException) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
