#!/usr/bin/env python3
"""Run an N-1 Sparkle install/relaunch gate, with one explicit channel bootstrap."""

from __future__ import annotations

import argparse
import contextlib
import http.server
import json
import os
import plistlib
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path

from release_contract import package_contract
from verify_macos_package import (
    code_targets,
    is_mach_o,
    normalize_fingerprint,
    validate_zip_entries,
    verify_certificate_chain,
    verify_code_target,
)


def run(*command: str) -> bytes:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise RuntimeError(
            f"{' '.join(command)} failed: {(result.stdout + result.stderr).decode(errors='replace')}"
        )
    return result.stdout


def extract_app(archive: Path, destination: Path, expected_name: str) -> Path:
    destination.mkdir(parents=True)
    run("ditto", "-x", "-k", str(archive), str(destination))
    apps = [path for path in destination.iterdir() if path.suffix == ".app"]
    if [path.name for path in apps] != [expected_name]:
        raise ValueError(f"Expected {expected_name} in {archive}; found {[path.name for path in apps]}")
    return apps[0]


def app_version(app: Path) -> str:
    return str(plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"])


def verify_trusted_app(
    app: Path,
    *,
    channel: str,
    arch: str,
    identity: str,
    team_id: str,
    certificate_sha256: str,
    label: str,
) -> str:
    """Verify one extracted app against an explicit release trust contract."""

    contract = package_contract(channel, arch)
    fingerprint = normalize_fingerprint(certificate_sha256)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expectations = {
        "CFBundleIdentifier": contract.bundle_id,
        "CFBundleDisplayName": contract.product_name,
    }
    for key, expected in expectations.items():
        if str(info.get(key, "")) != expected:
            raise ValueError(f"{label} {key} is {info.get(key)!r}, expected {expected!r}")

    executable = app / "Contents/MacOS" / str(info["CFBundleExecutable"])
    targets = code_targets(app)
    mach_o_targets = [target for target in targets if target.is_file() and is_mach_o(target)]
    if executable not in mach_o_targets:
        raise ValueError(f"{label} main executable is missing or is not Mach-O")
    for target in mach_o_targets:
        architectures = run("lipo", "-archs", str(target)).decode().split()
        if target == executable:
            if architectures != [contract.xcode_arch]:
                raise ValueError(
                    f"{label} main executable architectures are {architectures}, "
                    f"expected {[contract.xcode_arch]}"
                )
        elif contract.xcode_arch not in architectures or not set(architectures) <= {
            "arm64",
            "x86_64",
        }:
            raise ValueError(
                f"{label} {target} architectures are {architectures}, "
                f"expected support for {contract.xcode_arch}"
            )

    with tempfile.TemporaryDirectory(prefix="dockmint-trust-verifier-") as raw:
        certificates = Path(raw) / "certificates"
        certificates.mkdir(mode=0o700)
        run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
        for index, target in enumerate(targets):
            verify_code_target(
                target,
                identity=identity,
                team_id=team_id,
                fingerprint=fingerprint,
                certificate_dir=certificates,
                certificate_index=index,
            )
        verify_certificate_chain(app, certificates)
        run("xcrun", "stapler", "validate", str(app))
        run("spctl", "-a", "-vv", "--type", "execute", str(app))
    return app_version(app)


def verify_release_package(
    archive: Path,
    *,
    channel: str,
    arch: str,
    identity: str,
    team_id: str,
    certificate_sha256: str,
    label: str,
) -> str:
    """Verify a downloaded release ZIP and its extracted app before use."""

    contract = package_contract(channel, arch)
    archive = archive.resolve()
    if not archive.is_file():
        raise ValueError(f"{label} ZIP does not exist: {archive}")
    validate_zip_entries(archive)
    run("unzip", "-tq", str(archive))
    with tempfile.TemporaryDirectory(prefix="dockmint-package-verifier-") as raw:
        app = extract_app(archive, Path(raw) / "extracted", contract.app_name)
        return verify_trusted_app(
            app,
            channel=channel,
            arch=arch,
            identity=identity,
            team_id=team_id,
            certificate_sha256=certificate_sha256,
            label=label,
        )


def verify_previous_package(
    archive: Path,
    *,
    channel: str,
    arch: str,
    identity: str,
    team_id: str,
    certificate_sha256: str,
) -> str:
    return verify_release_package(
        archive,
        channel=channel,
        arch=arch,
        identity=identity,
        team_id=team_id,
        certificate_sha256=certificate_sha256,
        label="previous package",
    )


@contextlib.contextmanager
def local_feed_server(directory: Path):
    handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(  # noqa: E731
        *args, directory=str(directory), **kwargs
    )
    server = socketserver.TCPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_address[1]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def prepare_local_feed(source: Path, destination: Path, candidate_zip: Path, port: int) -> None:
    tree = ET.parse(source)
    enclosure = tree.getroot().find("./channel/item/enclosure")
    if enclosure is None:
        raise ValueError("Candidate appcast has no enclosure")
    enclosure.set("url", f"http://127.0.0.1:{port}/{candidate_zip.name}")
    tree.write(destination, encoding="utf-8", xml_declaration=True)


def verify_bootstrap_candidate(candidate_zip: Path, expected_app: str) -> None:
    with tempfile.TemporaryDirectory(prefix="dockmint-sparkle-bootstrap-") as raw:
        candidate_app = extract_app(candidate_zip, Path(raw) / "candidate", expected_app)
        executable_name = plistlib.loads((candidate_app / "Contents/Info.plist").read_bytes())[
            "CFBundleExecutable"
        ]
        strings = run("strings", str(candidate_app / "Contents/MacOS" / str(executable_name)))
        if b"DOCKMINT_SPARKLE_UPDATE_TEST" not in strings:
            raise ValueError("Bootstrap candidate does not contain the real Sparkle update-test hook")


def matches_bootstrap_boundary(
    boundary: object, *, previous_version: str, candidate_version: str
) -> bool:
    """Match only the exact, source-controlled first migration boundary."""

    if not isinstance(boundary, dict) or set(boundary) != {
        "previousVersion",
        "candidateVersions",
    }:
        return False
    candidate_versions = boundary.get("candidateVersions")
    return (
        isinstance(boundary.get("previousVersion"), str)
        and isinstance(candidate_versions, list)
        and bool(candidate_versions)
        and all(isinstance(version, str) for version in candidate_versions)
        and len(candidate_versions) == len(set(candidate_versions))
        and previous_version == boundary["previousVersion"]
        and candidate_version in candidate_versions
    )


def verify_installed_update(
    app: Path,
    *,
    channel: str,
    arch: str,
    expected_version: str,
    identity: str,
    team_id: str,
    candidate_certificate_sha256: str,
) -> None:
    installed_version = verify_trusted_app(
        app,
        channel=channel,
        arch=arch,
        identity=identity,
        team_id=team_id,
        certificate_sha256=candidate_certificate_sha256,
        label="installed update",
    )
    if installed_version != expected_version:
        raise RuntimeError("Sparkle result marker was written but installed app version did not change")


def relaunch_test_configuration(app: Path, result: Path, version: str) -> dict:
    # Launch Services resolves /var to /private/var when Sparkle relaunches.
    # Match the real bundle location while retaining the exact-path constraint.
    return {
        "expectedVersion": version,
        "resultPath": str(result.resolve()),
        "bundlePath": str(app.resolve()),
        "expiresAt": time.time() + 300,
    }


def run_real_gate(
    previous_zip: Path,
    candidate_zip: Path,
    appcast: Path,
    expected_app: str,
    expected_version: str,
    channel: str,
    arch: str,
    identity: str,
    team_id: str,
    candidate_certificate_sha256: str,
) -> None:
    diagnostics = Path("sparkle-gate-diagnostics")
    diagnostics.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dockmint-sparkle-n-minus-one-") as raw:
        root = Path(raw).resolve()
        installed = root / "Applications"
        previous_app = extract_app(previous_zip, installed, expected_app)
        server_root = root / "server"
        server_root.mkdir()
        shutil.copy2(candidate_zip, server_root / candidate_zip.name)
        result_path = root / "update-result.txt"
        relaunch_configuration = Path("/tmp/dockmint-sparkle-update-test.json")
        home = root / "home"
        home.mkdir(mode=0o700)
        temporary = root / "tmp"
        temporary.mkdir(mode=0o700)
        relaunch_configuration.write_text(
            json.dumps(
                relaunch_test_configuration(previous_app, result_path, expected_version)
            ),
            encoding="utf-8",
        )
        relaunch_configuration.chmod(0o600)

        try:
            with local_feed_server(server_root) as port:
                feed = server_root / "candidate.xml"
                prepare_local_feed(appcast, feed, candidate_zip, port)
                info = plistlib.loads((previous_app / "Contents/Info.plist").read_bytes())
                executable = previous_app / "Contents/MacOS" / str(info["CFBundleExecutable"])
                environment = {
                    "HOME": str(home),
                    "TMPDIR": f"{temporary}/",
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "LANG": "en_US.UTF-8",
                    "LC_ALL": "en_US.UTF-8",
                    "USER": "dockmint-sparkle-gate",
                    "LOGNAME": "dockmint-sparkle-gate",
                    "DOCKMINT_SPARKLE_UPDATE_TEST": "1",
                    "DOCKMINT_SPARKLE_TEST_FEED_URL": f"http://127.0.0.1:{port}/candidate.xml",
                    "DOCKMINT_SPARKLE_TEST_EXPECTED_VERSION": expected_version,
                    "DOCKMINT_SPARKLE_TEST_RESULT": str(result_path),
                }
                app_output = (diagnostics / "app.log").open("w")
                process = subprocess.Popen(
                    (str(executable), "-ApplePersistenceIgnoreState", "YES"),
                    env=environment,
                    stdout=app_output,
                    stderr=subprocess.STDOUT,
                )
                deadline = time.monotonic() + 240
                try:
                    while time.monotonic() < deadline and not result_path.exists():
                        if process.poll() is not None and not previous_app.exists():
                            break
                        time.sleep(1)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                    app_output.close()
                    (diagnostics / "result.json").write_text(json.dumps({
                        "exitCode": process.returncode,
                        "installedVersion": app_version(previous_app) if previous_app.exists() else None,
                        "expectedVersion": expected_version,
                        "result": result_path.read_text() if result_path.exists() else None,
                    }, indent=2))
                    logs = subprocess.run(
                        ("/usr/bin/log", "show", "--last", "6m", "--style", "compact",
                         "--predicate", 'process CONTAINS "Dockmint" OR process CONTAINS "Updater" OR subsystem CONTAINS "sparkle"'),
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
                    )
                    (diagnostics / "system.log").write_bytes(logs.stdout)
                    if not result_path.exists():
                        print((diagnostics / "app.log").read_text(errors="replace")[-16000:])
                        print((diagnostics / "result.json").read_text())
        finally:
            relaunch_configuration.unlink(missing_ok=True)

        if not result_path.exists():
            raise RuntimeError("Sparkle update gate timed out before install/relaunch confirmation")
        result = result_path.read_text(encoding="utf-8").strip()
        if result != f"installed-and-relaunched:{expected_version}":
            raise RuntimeError(f"Sparkle update gate failed: {result}")
        verify_installed_update(
            previous_app,
            channel=channel,
            arch=arch,
            expected_version=expected_version,
            identity=identity,
            team_id=team_id,
            candidate_certificate_sha256=candidate_certificate_sha256,
        )


def execute_gate(args: argparse.Namespace) -> None:
    expected_app = "Dockmint.app" if args.channel == "stable" else "Dockmint Beta.app"

    candidate_version = verify_release_package(
        args.candidate_zip,
        channel=args.channel,
        arch=args.arch,
        identity=args.identity,
        team_id=args.team_id,
        certificate_sha256=args.candidate_certificate_sha256,
        label="candidate package",
    )
    if candidate_version != args.expected_version:
        raise ValueError(
            f"candidate package version is {candidate_version!r}, expected {args.expected_version!r}"
        )
    previous_version = verify_previous_package(
        args.previous_zip,
        channel=args.channel,
        arch=args.arch,
        identity=args.identity,
        team_id=args.team_id,
        certificate_sha256=args.prior_certificate_sha256,
    )

    bootstrap = json.loads(args.bootstrap_contract.read_text(encoding="utf-8"))
    key = f"{args.channel}-{args.arch}"
    bootstrap_boundary = bootstrap.get(key)
    if matches_bootstrap_boundary(
        bootstrap_boundary,
        previous_version=previous_version,
        candidate_version=candidate_version,
    ):
        verify_bootstrap_candidate(args.candidate_zip, expected_app)
        print(
            f"BOOTSTRAP {key}: exact {previous_version} -> {candidate_version} boundary "
            "predates the N-1 update-test hook; candidate contains the hook required "
            "for the following release on this channel"
        )
        return

    run_real_gate(
        args.previous_zip,
        args.candidate_zip,
        args.candidate_appcast,
        expected_app,
        args.expected_version,
        args.channel,
        args.arch,
        args.identity,
        args.team_id,
        args.candidate_certificate_sha256,
    )
    print(f"PASS {key}: Sparkle installed and relaunched {previous_version} -> {args.expected_version}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous-zip", type=Path, required=True)
    parser.add_argument("--candidate-zip", type=Path, required=True)
    parser.add_argument("--candidate-appcast", type=Path, required=True)
    parser.add_argument("--channel", choices=("stable", "beta"), required=True)
    parser.add_argument("--arch", choices=("arm64", "x64"), required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--candidate-certificate-sha256", required=True)
    parser.add_argument("--prior-certificate-sha256", required=True)
    parser.add_argument(
        "--bootstrap-contract",
        type=Path,
        default=Path("scripts/release/sparkle-update-bootstrap.json"),
    )
    args = parser.parse_args()
    execute_gate(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, ET.ParseError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
