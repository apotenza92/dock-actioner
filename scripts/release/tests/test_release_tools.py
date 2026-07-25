from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import tempfile
import unittest
import warnings
import zipfile
from unittest import mock
from pathlib import Path


RELEASE_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RELEASE_DIR))

from release_contract import (  # noqa: E402
    MINIMUM_SYSTEM_VERSION,
    beta_asset_names,
    package_contract,
    parse_tag,
    stable_asset_names,
    version_key,
)
from verify_macos_package import (  # noqa: E402
    launch_smoke,
    normalize_fingerprint,
    parse_codesign_details,
    validate_notarization_log,
    validate_icon_contract,
    validate_sparkle_contract,
    validate_zip_entries,
)


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, RELEASE_DIR / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


sparkle = load_module("dockmint_sparkle", "update_sparkle_appcasts.py")
homebrew = load_module("dockmint_homebrew", "update_homebrew_tap_casks.py")
update_gate = load_module("dockmint_update_gate", "run_sparkle_update_gate.py")
release_metadata = load_module("dockmint_release_metadata", "release_metadata.py")
appcast_verifier = load_module(
    "dockmint_appcast_verifier", "verify_sparkle_appcasts.py"
)


class ReleaseContractTests(unittest.TestCase):
    def test_untrusted_events_cannot_reach_release_credentials(self):
        repository_root = RELEASE_DIR.parent.parent
        ci = (repository_root / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )
        release = (repository_root / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        release_triggers = release.split("permissions:", 1)[0]

        ci_triggers = ci.split("permissions:", 1)[0]
        self.assertIn("  workflow_dispatch:", ci_triggers)
        self.assertNotIn("  push:", ci_triggers)
        self.assertNotIn("  pull_request:", ci_triggers)
        self.assertNotIn("environment:", ci)
        self.assertNotIn("secrets.", ci)
        self.assertNotIn("contents: write", ci)
        self.assertIn('pathlib.Path("CHANGELOG.md").read_text()', ci)
        self.assertIn('--tag "$current_tag"', ci)
        self.assertNotIn(
            'MARKETING_VERSION = ([0-9.]+)',
            ci,
            "pull-request CI must validate the current prerelease tag, not invent a stable tag",
        )
        self.assertIn('      - "v*"', release_triggers)
        for untrusted_trigger in (
            "pull_request:",
            "pull_request_target:",
            "workflow_dispatch:",
            "workflow_run:",
        ):
            self.assertNotIn(untrusted_trigger, release_triggers)

    def test_release_source_and_immutable_policy_precede_publication(self):
        workflow = (RELEASE_DIR.parent.parent / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        policy = workflow.split("  verify-release-policy:", 1)[1].split(
            "  stage-draft-release:", 1
        )[0]
        draft = workflow.split("  stage-draft-release:", 1)[1].split(
            "  generate-signed-appcasts:", 1
        )[0]
        publish = workflow.split("  publish-release:", 1)[1].split(
            "  prepare-sparkle-publication:", 1
        )[0]

        self.assertIn("fetch-depth: 0", workflow.split("  release-gate:", 1)[0])
        self.assertIn("Prove tag commit belongs to the approved release source", workflow)
        self.assertIn(
            "DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}", workflow
        )
        self.assertIn("git merge-base --is-ancestor", workflow)
        self.assertIn("environment: release-policy", policy)
        self.assertIn("permissions:\n      contents: read", policy)
        self.assertIn("repos/$GH_REPO/immutable-releases", policy)
        self.assertIn("secrets.IMMUTABLE_RELEASES_READ_TOKEN", policy)
        self.assertEqual(policy.count("secrets."), 1)
        self.assertEqual(workflow.count("secrets.IMMUTABLE_RELEASES_READ_TOKEN"), 1)
        self.assertIn("needs:\n      - prepare\n    runs-on:", policy)
        self.assertNotIn("stage-draft-release", policy)
        self.assertNotIn("sparkle-update-gate", policy)
        self.assertIn("- verify-release-policy", draft)
        self.assertLess(
            workflow.index("  verify-release-policy:"),
            workflow.index("  stage-draft-release:"),
        )
        self.assertIn("- verify-release-policy", publish)
        self.assertNotIn("IMMUTABLE_RELEASES_READ_TOKEN", publish)

    def test_release_environments_expose_only_required_credentials(self):
        workflow = (RELEASE_DIR.parent.parent / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "APPLE_NOTARYTOOL_KEY_ID: ${{ vars.APPLE_NOTARYTOOL_KEY_ID }}",
            workflow,
        )
        self.assertIn(
            "APPLE_NOTARYTOOL_ISSUER_ID: ${{ vars.APPLE_NOTARYTOOL_ISSUER_ID }}",
            workflow,
        )
        self.assertNotIn("secrets.APPLE_NOTARYTOOL_KEY_ID", workflow)
        self.assertNotIn("secrets.APPLE_NOTARYTOOL_ISSUER_ID", workflow)
        self.assertEqual(workflow.count("environment: sparkle-signing"), 1)

        signing = workflow.split("  generate-signed-appcasts:", 1)[1].split(
            "  sparkle-update-gate:", 1
        )[0]
        self.assertIn("environment: sparkle-signing", signing)
        self.assertIn("secrets.SPARKLE_PRIVATE_ED_KEY", signing)

        draft = workflow.split("  stage-draft-release:", 1)[1].split(
            "  generate-signed-appcasts:", 1
        )[0]
        publication = workflow.split("  publish-release:", 1)[1].split(
            "  prepare-sparkle-publication:", 1
        )[0]
        appcast = workflow.split("  prepare-sparkle-publication:", 1)[1].split(
            "  generate-homebrew-casks:", 1
        )[0]
        self.assertNotIn("environment:", draft + appcast)
        self.assertRegex(publication, r"environment: .*beta-release.*stable-release")
        self.assertEqual(
            workflow.count(
                "environment: ${{ needs.prepare.outputs.prerelease == 'true' && 'beta-release' || 'stable-release' }}"
            ),
            1,
        )
        self.assertEqual(workflow.count("stable-release"), 1)
        self.assertEqual(workflow.count("beta-release"), 1)
        self.assertNotIn("SPARKLE_PRIVATE_ED_KEY", draft + publication + appcast)

    def test_updater_matrix_is_channel_aware(self):
        beta_rows = release_metadata.metadata("v0.4.2-beta.1")["release_matrix"][
            "include"
        ]
        stable_rows = release_metadata.metadata("v0.4.2")["release_matrix"][
            "include"
        ]
        self.assertEqual(
            [(row["channel"], row["arch"]) for row in beta_rows],
            [("beta", "arm64"), ("beta", "x64")],
        )
        self.assertEqual(
            [(row["channel"], row["arch"]) for row in stable_rows],
            [
                ("stable", "arm64"),
                ("stable", "x64"),
                ("beta", "arm64"),
                ("beta", "x64"),
            ],
        )
        workflow = (RELEASE_DIR.parent.parent / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "release_matrix: ${{ steps.meta.outputs.release_matrix }}",
            workflow,
        )
        build = workflow.split("  build-macos:", 1)[1].split(
            "  stage-draft-release:", 1
        )[0]
        gate = workflow.split("  sparkle-update-gate:", 1)[1].split(
            "  publish-release:", 1
        )[0]
        self.assertIn(
            "matrix: ${{ fromJSON(needs.prepare.outputs.release_matrix) }}",
            build,
        )
        self.assertIn(
            "matrix: ${{ fromJSON(needs.prepare.outputs.release_matrix) }}",
            gate,
        )
        self.assertNotIn("channel: stable", build + gate)
        self.assertEqual(
            [package["channel"] for package in release_metadata.metadata("v0.4.2-beta.1")["packages"]],
            ["beta", "beta"],
        )
        self.assertEqual(
            {row["app_icon"] for row in beta_rows}, {"AppIconBeta"}
        )
        draft = workflow.split("  stage-draft-release:", 1)[1].split(
            "  generate-signed-appcasts:", 1
        )[0]
        self.assertIn("prefixes=(Dockmint-Beta)", draft)
        self.assertIn('if [[ "$PRERELEASE" != "true" ]]', draft)
        self.assertIn("prefixes=(Dockmint \"${prefixes[@]}\")", draft)
        self.assertIn("--draft --prerelease", draft)

    def test_publication_jobs_never_commit_or_push(self):
        workflow = (RELEASE_DIR.parent.parent / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        appcast = workflow.split("  prepare-sparkle-publication:", 1)[1].split(
            "  generate-homebrew-casks:", 1
        )[0]
        homebrew = workflow.split("  prepare-homebrew-publication:", 1)[1]
        for publication in (appcast, homebrew):
            self.assertIn("actions/upload-artifact", publication)
            self.assertIn("SHA256SUMS", publication)
            self.assertIn("Apply these exact", publication)
            self.assertNotIn("git commit", publication)
            self.assertNotIn("git push", publication)
            self.assertNotIn("contents: write", publication)
        self.assertNotIn("HOMEBREW_TAP_TOKEN", workflow)
        self.assertNotIn("secrets.HOMEBREW_TAP_TOKEN", workflow)

    def test_homebrew_publishes_the_exact_native_validated_artifact(self):
        workflow = (RELEASE_DIR.parent.parent / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("  generate-homebrew-casks:", workflow)
        validation = workflow.split("  validate-homebrew-casks:", 1)[1].split(
            "  prepare-homebrew-publication:", 1
        )[0]
        publication = workflow.split("  prepare-homebrew-publication:", 1)[1]
        self.assertIn("name: reviewed-homebrew-casks", validation)
        self.assertIn("brew tap apotenza92/tap", validation)
        self.assertIn("apotenza92/tap/dockmint@beta", validation)
        self.assertIn("name: reviewed-homebrew-casks", publication)
        self.assertNotIn("update_homebrew_tap_casks.py", publication)
        self.assertIn("generate-homebrew-casks", publication)
        self.assertIn("validate-homebrew-casks", publication)
        self.assertIn("dockmint-homebrew-publication-", publication)

    def test_update_channels_require_an_immutable_public_release(self):
        workflow = (RELEASE_DIR.parent.parent / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        publish_release = workflow.split("  publish-release:", 1)[1].split(
            "  prepare-sparkle-publication:", 1
        )[0]
        appcast = workflow.split("  prepare-sparkle-publication:", 1)[1].split(
            "  generate-homebrew-casks:", 1
        )[0]
        homebrew = workflow.split("  generate-homebrew-casks:", 1)[1].split(
            "  validate-homebrew-casks:", 1
        )[0]
        self.assertIn("--jq .immutable", publish_release)
        self.assertIn("Published release is not immutable", publish_release)
        self.assertIn("- publish-release", appcast)
        self.assertIn("- publish-release", homebrew)
        self.assertIn("- prepare-sparkle-publication", homebrew)

    def test_sparkle_n_minus_one_uses_a_separate_non_secret_certificate_pin(self):
        workflow = (RELEASE_DIR.parent.parent / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        build = workflow.split("  build-macos:", 1)[1].split(
            "  stage-draft-release:", 1
        )[0]
        gate = workflow.split("  sparkle-update-gate:", 1)[1].split(
            "  publish-release:", 1
        )[0]

        self.assertIn(
            "APPLE_SIGNING_CERTIFICATE_SHA256: ${{ vars.APPLE_SIGNING_CERTIFICATE_SHA256 }}",
            build,
        )
        self.assertIn(
            '--certificate-sha256 "$APPLE_SIGNING_CERTIFICATE_SHA256"', build
        )
        self.assertNotIn("APPLE_PRIOR_SIGNING_CERTIFICATE_SHA256", build)
        self.assertNotIn("environment:", gate)
        self.assertNotIn("secrets.", gate)
        self.assertIn(
            "APPLE_SIGNING_CERTIFICATE_SHA256: ${{ vars.APPLE_SIGNING_CERTIFICATE_SHA256 }}",
            gate,
        )
        self.assertIn(
            '--candidate-certificate-sha256 "$APPLE_SIGNING_CERTIFICATE_SHA256"',
            gate,
        )
        self.assertIn(
            "APPLE_PRIOR_SIGNING_CERTIFICATE_SHA256: ${{ vars.APPLE_PRIOR_SIGNING_CERTIFICATE_SHA256 }}",
            gate,
        )
        self.assertIn(
            '--prior-certificate-sha256 "$APPLE_PRIOR_SIGNING_CERTIFICATE_SHA256"',
            gate,
        )
        self.assertNotIn("secrets.APPLE_PRIOR_SIGNING_CERTIFICATE_SHA256", workflow)
        self.assertEqual(
            (RELEASE_DIR / "run_sparkle_update_gate.py")
            .read_text(encoding="utf-8")
            .count('"expiresAt"'),
            1,
        )

    def test_sparkle_bootstrap_is_explicit_for_every_channel_architecture(self):
        contract = json.loads(
            (RELEASE_DIR / "sparkle-update-bootstrap.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            contract,
            {
                "stable-arm64": {
                    "previousVersion": "0.4.1",
                    "candidateVersions": ["0.4.2"],
                },
                "stable-x64": {
                    "previousVersion": "0.4.1",
                    "candidateVersions": ["0.4.2"],
                },
                "beta-arm64": {
                    "previousVersion": "0.4.1",
                    "candidateVersions": ["0.4.2-beta.1", "0.4.2"],
                },
                "beta-x64": {
                    "previousVersion": "0.4.1",
                    "candidateVersions": ["0.4.2-beta.1", "0.4.2"],
                },
            },
        )

    def test_only_stable_and_beta_tags_are_accepted(self):
        self.assertIsNotNone(parse_tag("v1.2.3"))
        self.assertIsNotNone(parse_tag("v1.2.3-beta.4"))
        for tag in (
            "1.2.3",
            "v1.2.3-rc.1",
            "v1.2.3-beta.0",
            "v1.2.3-beta.01",
            "v1.2",
        ):
            self.assertIsNone(parse_tag(tag), tag)

    def test_build_numbers_preserve_beta_to_stable_ordering(self):
        beta = parse_tag("v2.3.4-beta.7")
        stable = parse_tag("v2.3.4")
        assert beta is not None and stable is not None
        self.assertEqual(beta.build_number, "200300400007")
        self.assertEqual(stable.build_number, "200300490000")
        self.assertLess(version_key(beta), version_key(stable))

    def test_exact_package_contract(self):
        stable = package_contract("stable", "arm64")
        beta = package_contract("beta", "x64")
        self.assertEqual(stable.bundle_id, "pzc.Dockmint")
        self.assertEqual(stable.artifact_name("1.2.3"), "Dockmint-v1.2.3-macos-arm64.zip")
        self.assertEqual(beta.bundle_id, "pzc.Dockmint.beta")
        self.assertEqual(beta.xcode_arch, "x86_64")
        self.assertEqual(beta.artifact_name("1.2.3-beta.1"), "Dockmint-Beta-v1.2.3-beta.1-macos-x64.zip")
        self.assertEqual(MINIMUM_SYSTEM_VERSION, "14.0")

    def test_no_legacy_asset_fallbacks(self):
        self.assertEqual(stable_asset_names("1.0.0", "arm64"), ("Dockmint-v1.0.0-macos-arm64.zip",))
        self.assertEqual(beta_asset_names("1.0.0", "x64"), ("Dockmint-Beta-v1.0.0-macos-x64.zip",))


class GeneratorTests(unittest.TestCase):
    def test_beta_two_supersedes_beta_one_for_the_beta_feed(self):
        previous = parse_tag("v0.4.2-beta.1")
        candidate = parse_tag("v0.4.2-beta.2")
        assert previous is not None and candidate is not None
        releases = [
            sparkle.Release(
                tag_name=parsed.tag,
                html_url=f"https://example.test/{parsed.tag}",
                draft=parsed == candidate,
                prerelease_flag=True,
                published_at="2026-07-23T00:00:00Z",
                assets=(),
                parsed=parsed,
            )
            for parsed in (previous, candidate)
        ]
        self.assertEqual(sparkle.pick_latest(releases).tag_name, "v0.4.2-beta.2")

    def test_beta_channel_tracks_newer_stable(self):
        stable_tag = parse_tag("v1.1.0")
        beta_tag = parse_tag("v1.0.0-beta.9")
        assert stable_tag is not None and beta_tag is not None
        self.assertGreater(version_key(stable_tag), version_key(beta_tag))

    def test_sparkle_appcast_uses_deployment_target_and_escapes_cdata(self):
        parsed = parse_tag("v1.2.3")
        assert parsed is not None
        release = sparkle.Release(
            tag_name=parsed.tag,
            html_url="https://example.test/release",
            draft=False,
            prerelease_flag=False,
            published_at="2026-01-01T00:00:00Z",
            assets=(),
            parsed=parsed,
        )
        asset = sparkle.ReleaseAsset("a.zip", 12, "", "https://example.test/a.zip")
        xml = sparkle.render_appcast(
            channel_name="Stable",
            repo="apotenza92/dockmint",
            release=release,
            asset=asset,
            notes="before ]]> after",
            signature="signature",
        )
        self.assertIn("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>", xml)
        self.assertIn("]] ]]>", xml.replace("]]><![CDATA[>", "]] ]]>"))
        self.assertIn('sparkle:edSignature="signature"', xml)

    def test_homebrew_render_preserves_legacy_zap_paths(self):
        rendered = homebrew.render_stable_cask(
            "dockmint",
            "Dockmint",
            "desc",
            "apotenza92/dockmint",
            "1.0.0",
            "https://github.com/apotenza92/dockmint/releases/download/v1.0.0/Dockmint-v1.0.0-macos-arm64.zip",
            "a" * 64,
            "https://github.com/apotenza92/dockmint/releases/download/v1.0.0/Dockmint-v1.0.0-macos-x64.zip",
            "b" * 64,
        )
        self.assertIn('app "Dockmint.app"', rendered)
        self.assertIn("depends_on macos: :sonoma", rendered)
        self.assertNotIn('desc "Dock gesture actions for macOS"', rendered)
        self.assertIn("Dockmint-v#{version}-macos-arm64.zip", rendered)
        self.assertIn("~/Library/Preferences/pzc.Dockter.plist", rendered)
        self.assertLess(
            rendered.index('sha256 "' + "a" * 64),
            rendered.index("Dockmint-v#{version}-macos-arm64.zip"),
        )
        self.assertLess(rendered.index("~/Code/Dockmint/logs"), rendered.index("~/Library/Application Support/Dockmint"))

    def test_homebrew_urls_interpolate_the_cask_version(self):
        url = "https://github.com/apotenza92/dockmint/releases/download/v1.2.3/Dockmint-v1.2.3-macos-arm64.zip"
        self.assertEqual(
            homebrew.versioned_cask_url(url, "1.2.3"),
            "https://github.com/apotenza92/dockmint/releases/download/v#{version}/Dockmint-v#{version}-macos-arm64.zip",
        )
        with self.assertRaises(ValueError):
            homebrew.versioned_cask_url("https://example.test/download.zip", "1.2.3")


class VerifierTests(unittest.TestCase):
    def test_appcast_filename_maps_to_exact_channel_architecture_asset(self):
        self.assertEqual(
            appcast_verifier.expected_asset_for_feed("stable-arm64.xml", "1.2.3"),
            "Dockmint-v1.2.3-macos-arm64.zip",
        )
        self.assertEqual(
            appcast_verifier.expected_asset_for_feed(
                "beta-x64.xml", "1.2.4-beta.1"
            ),
            "Dockmint-Beta-v1.2.4-beta.1-macos-x64.zip",
        )
        with self.assertRaisesRegex(ValueError, "stable appcast"):
            appcast_verifier.expected_asset_for_feed(
                "stable-x64.xml", "1.2.4-beta.1"
            )
        with self.assertRaisesRegex(ValueError, "unexpected appcast filename"):
            appcast_verifier.expected_asset_for_feed("beta-universal.xml", "1.2.3")

    def test_icon_contract_requires_expected_named_packaged_asset(self):
        with tempfile.TemporaryDirectory() as raw:
            app = Path(raw) / "Dockmint Beta.app"
            asset_catalog = app / "Contents/Resources/Assets.car"
            asset_catalog.parent.mkdir(parents=True)
            asset_catalog.write_bytes(b"compiled assets")
            result = __import__("subprocess").CompletedProcess(
                [], 0, b'[{"Name":"AppIconBeta","AssetType":"Icon Image"}]', b""
            )
            with mock.patch("verify_macos_package.run", return_value=result):
                validate_icon_contract(
                    app, {"CFBundleIconName": "AppIconBeta"}, "AppIconBeta"
                )
                with self.assertRaisesRegex(ValueError, "CFBundleIconName"):
                    validate_icon_contract(
                        app, {"CFBundleIconName": "AppIcon"}, "AppIconBeta"
                    )
                with self.assertRaisesRegex(ValueError, "does not contain icon asset"):
                    validate_icon_contract(
                        app, {"CFBundleIconName": "OtherIcon"}, "OtherIcon"
                    )

    def test_local_update_feed_rewrite_preserves_signature(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "source.xml"
            destination = root / "candidate.xml"
            source.write_text(
                '<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="https://example.test/old.zip" sparkle:edSignature="signed" /></item></channel></rss>',
                encoding="utf-8",
            )
            update_gate.prepare_local_feed(source, destination, root / "candidate.zip", 1234)
            rendered = destination.read_text(encoding="utf-8")
            self.assertIn("http://127.0.0.1:1234/candidate.zip", rendered)
            self.assertIn('edSignature="signed"', rendered)

    def test_previous_update_package_is_strictly_verified_with_prior_certificate(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            archive = root / "previous.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("Dockmint.app/placeholder", "x")

            app = root / "Dockmint.app"
            executable = app / "Contents/MacOS/Dockmint"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"mach-o")
            (app / "Contents/Info.plist").write_bytes(
                __import__("plistlib").dumps(
                    {
                        "CFBundleIdentifier": "pzc.Dockmint",
                        "CFBundleDisplayName": "Dockmint",
                        "CFBundleExecutable": "Dockmint",
                        "CFBundleShortVersionString": "0.4.1",
                    }
                )
            )

            commands = []

            def fake_run(*command):
                commands.append(command)
                if command[:2] == ("lipo", "-archs"):
                    return b"arm64\n"
                return b""

            with mock.patch.object(update_gate, "run", side_effect=fake_run), mock.patch.object(
                update_gate, "extract_app", return_value=app
            ), mock.patch.object(
                update_gate, "code_targets", return_value=[app, executable]
            ), mock.patch.object(
                update_gate, "is_mach_o", return_value=True
            ), mock.patch.object(
                update_gate, "verify_code_target"
            ) as verify_target, mock.patch.object(
                update_gate, "verify_certificate_chain"
            ) as verify_chain:
                version = update_gate.verify_previous_package(
                    archive,
                    channel="stable",
                    arch="arm64",
                    identity="Developer ID Application: Example (TEAM123)",
                    team_id="TEAM123",
                    certificate_sha256="ab:" * 31 + "ab",
                )

            self.assertEqual(version, "0.4.1")
            self.assertEqual(verify_target.call_count, 2)
            for call in verify_target.call_args_list:
                self.assertEqual(
                    call.kwargs["identity"],
                    "Developer ID Application: Example (TEAM123)",
                )
                self.assertEqual(call.kwargs["team_id"], "TEAM123")
                self.assertEqual(call.kwargs["fingerprint"], "AB" * 32)
            verify_chain.assert_called_once()
            self.assertIn(
                ("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)),
                commands,
            )
            self.assertIn(("xcrun", "stapler", "validate", str(app)), commands)
            self.assertIn(
                ("spctl", "-a", "-vv", "--type", "execute", str(app)), commands
            )

    def test_previous_update_package_rejects_wrong_bundle_before_signature_use(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            archive = root / "previous.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("Dockmint.app/placeholder", "x")
            app = root / "Dockmint.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(
                __import__("plistlib").dumps(
                    {
                        "CFBundleIdentifier": "attacker.example",
                        "CFBundleDisplayName": "Dockmint",
                    }
                )
            )

            with mock.patch.object(update_gate, "run", return_value=b""), mock.patch.object(
                update_gate, "extract_app", return_value=app
            ), mock.patch.object(update_gate, "verify_code_target") as verify_target:
                with self.assertRaisesRegex(ValueError, "CFBundleIdentifier"):
                    update_gate.verify_previous_package(
                        archive,
                        channel="stable",
                        arch="arm64",
                        identity="Developer ID Application: Example (TEAM123)",
                        team_id="TEAM123",
                        certificate_sha256="ab" * 32,
                    )
            verify_target.assert_not_called()

    def test_gate_verifies_candidate_then_prior_with_separate_pins(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bootstrap = root / "bootstrap.json"
            bootstrap.write_text("{}", encoding="utf-8")
            args = argparse.Namespace(
                previous_zip=root / "previous.zip",
                candidate_zip=root / "candidate.zip",
                candidate_appcast=root / "candidate.xml",
                channel="stable",
                arch="arm64",
                expected_version="0.5.0",
                identity="Developer ID Application: Example (TEAM123)",
                team_id="TEAM123",
                candidate_certificate_sha256="11" * 32,
                prior_certificate_sha256="22" * 32,
                bootstrap_contract=bootstrap,
            )
            order = []

            def verify_candidate(*_args, **kwargs):
                order.append(("candidate", kwargs["certificate_sha256"]))
                return "0.5.0"

            def verify_previous(*_args, **kwargs):
                order.append(("previous", kwargs["certificate_sha256"]))
                return "0.4.2"

            with mock.patch.object(
                update_gate, "verify_release_package", side_effect=verify_candidate
            ), mock.patch.object(
                update_gate, "verify_previous_package", side_effect=verify_previous
            ), mock.patch.object(update_gate, "run_real_gate") as real_gate:
                update_gate.execute_gate(args)

            self.assertEqual(order, [("candidate", "11" * 32), ("previous", "22" * 32)])
            self.assertEqual(real_gate.call_args.args[-1], "11" * 32)

    def test_beta_two_runs_real_gate_from_beta_one(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            args = argparse.Namespace(
                previous_zip=root / "previous.zip",
                candidate_zip=root / "candidate.zip",
                candidate_appcast=root / "candidate.xml",
                channel="beta",
                arch="arm64",
                expected_version="0.4.2-beta.2",
                identity="Developer ID Application: Example (TEAM123)",
                team_id="TEAM123",
                candidate_certificate_sha256="11" * 32,
                prior_certificate_sha256="22" * 32,
                bootstrap_contract=RELEASE_DIR / "sparkle-update-bootstrap.json",
            )
            with mock.patch.object(
                update_gate, "verify_release_package", return_value="0.4.2-beta.2"
            ), mock.patch.object(
                update_gate, "verify_previous_package", return_value="0.4.2-beta.1"
            ), mock.patch.object(
                update_gate, "verify_bootstrap_candidate"
            ) as bootstrap_candidate, mock.patch.object(
                update_gate, "run_real_gate"
            ) as real_gate:
                update_gate.execute_gate(args)

            bootstrap_candidate.assert_not_called()
            real_gate.assert_called_once()

    def test_first_beta_migration_accepts_prerelease_or_stable_candidate(self):
        for candidate_version in ("0.4.2-beta.1", "0.4.2"):
            with self.subTest(candidate_version=candidate_version), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                args = argparse.Namespace(
                    previous_zip=root / "previous.zip",
                    candidate_zip=root / "candidate.zip",
                    candidate_appcast=root / "candidate.xml",
                    channel="beta",
                    arch="arm64",
                    expected_version=candidate_version,
                    identity="Developer ID Application: Example (TEAM123)",
                    team_id="TEAM123",
                    candidate_certificate_sha256="11" * 32,
                    prior_certificate_sha256="22" * 32,
                    bootstrap_contract=RELEASE_DIR / "sparkle-update-bootstrap.json",
                )
                with mock.patch.object(
                    update_gate, "verify_release_package", return_value=candidate_version
                ), mock.patch.object(
                    update_gate, "verify_previous_package", return_value="0.4.1"
                ), mock.patch.object(
                    update_gate, "verify_bootstrap_candidate"
                ) as bootstrap_candidate, mock.patch.object(
                    update_gate, "run_real_gate"
                ) as real_gate:
                    update_gate.execute_gate(args)

                bootstrap_candidate.assert_called_once_with(
                    args.candidate_zip, "Dockmint Beta.app"
                )
                real_gate.assert_not_called()

    def test_bootstrap_boundary_cannot_be_reused_by_beta_two(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            args = argparse.Namespace(
                previous_zip=root / "previous.zip",
                candidate_zip=root / "candidate.zip",
                candidate_appcast=root / "candidate.xml",
                channel="beta",
                arch="arm64",
                expected_version="0.4.2-beta.2",
                identity="Developer ID Application: Example (TEAM123)",
                team_id="TEAM123",
                candidate_certificate_sha256="11" * 32,
                prior_certificate_sha256="22" * 32,
                bootstrap_contract=RELEASE_DIR / "sparkle-update-bootstrap.json",
            )
            with mock.patch.object(
                update_gate, "verify_release_package", return_value="0.4.2-beta.2"
            ), mock.patch.object(
                update_gate, "verify_previous_package", return_value="0.4.1"
            ), mock.patch.object(
                update_gate, "verify_bootstrap_candidate"
            ) as bootstrap_candidate, mock.patch.object(
                update_gate, "run_real_gate"
            ) as real_gate:
                update_gate.execute_gate(args)

            bootstrap_candidate.assert_not_called()
            real_gate.assert_called_once()
            self.assertEqual(real_gate.call_args.args[4], "0.4.2-beta.2")

    def test_installed_update_uses_candidate_pin_and_rejects_wrong_version(self):
        app = Path("/tmp/Dockmint.app")
        with mock.patch.object(
            update_gate, "verify_trusted_app", return_value="0.5.0"
        ) as verify_app:
            update_gate.verify_installed_update(
                app,
                channel="stable",
                arch="arm64",
                expected_version="0.5.0",
                identity="Developer ID Application: Example (TEAM123)",
                team_id="TEAM123",
                candidate_certificate_sha256="11" * 32,
            )
        self.assertEqual(verify_app.call_args.kwargs["certificate_sha256"], "11" * 32)
        self.assertEqual(verify_app.call_args.kwargs["label"], "installed update")

        with mock.patch.object(
            update_gate, "verify_trusted_app", return_value="0.4.2"
        ):
            with self.assertRaisesRegex(RuntimeError, "version did not change"):
                update_gate.verify_installed_update(
                    app,
                    channel="stable",
                    arch="arm64",
                    expected_version="0.5.0",
                    identity="Developer ID Application: Example (TEAM123)",
                    team_id="TEAM123",
                    candidate_certificate_sha256="11" * 32,
                )

    def test_sparkle_contract_requires_helpers_and_security_plist_keys(self):
        with tempfile.TemporaryDirectory() as raw:
            app = Path(raw) / "Dockmint.app"
            info = {
                "SUPublicEDKey": "zM3fwyZrb6uCBvOIv8Smh91DRMyrKVQPbWBGpkCcgDI=",
                "SUVerifyUpdateBeforeExtraction": True,
                "SUAutomaticallyUpdate": False,
                "SUEnableAutomaticChecks": False,
                "SUEnableInstallerLauncherService": False,
            }
            for relative in __import__("verify_macos_package").REQUIRED_SPARKLE_PATHS:
                path = app / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            validate_sparkle_contract(app, info)
            (app / __import__("verify_macos_package").REQUIRED_SPARKLE_PATHS[0]).unlink()
            with self.assertRaisesRegex(ValueError, "required Sparkle helpers"):
                validate_sparkle_contract(app, info)

    def test_launch_smoke_does_not_inherit_release_secrets(self):
        class Process:
            returncode = None

            def poll(self):
                return self.returncode

            def terminate(self):
                self.returncode = 0

            def wait(self, timeout=None):
                return self.returncode

        captured = {}

        def fake_popen(command, *, env, stdout, stderr):
            captured.update(env)
            return Process()

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            app = root / "Dockmint.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(
                __import__("plistlib").dumps({"CFBundleExecutable": "Dockmint"})
            )
            work = root / "work"
            work.mkdir()
            with mock.patch.dict(
                "os.environ", {"APPLE_NOTARYTOOL_KEY_P8_BASE64": "secret"}
            ), mock.patch(
                "verify_macos_package.subprocess.Popen", side_effect=fake_popen
            ), mock.patch("verify_macos_package.time.sleep"):
                launch_smoke(app, work)

        self.assertNotIn("APPLE_NOTARYTOOL_KEY_P8_BASE64", captured)
        self.assertEqual(captured["DOCKMINT_TEST_SUITE"], "1")
        self.assertEqual(
            set(captured),
            {
                "HOME", "TMPDIR", "PATH", "LANG", "LC_ALL", "USER", "LOGNAME",
                "DOCKMINT_TEST_SUITE", "DOCKMINT_DEBUG_LOG",
            },
        )

    def test_fingerprint_normalization(self):
        value = "aa:" * 31 + "aa"
        self.assertEqual(normalize_fingerprint(value), "AA" * 32)
        with self.assertRaises(ValueError):
            normalize_fingerprint("bad")

    def test_codesign_metadata_parsing(self):
        details = parse_codesign_details(
            "CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=4+7 location=embedded\n"
            "Authority=Developer ID Application: Example (TEAM)\n"
            "Authority=Developer ID Certification Authority\n"
            "TeamIdentifier=TEAM\nTimestamp=Jul 1, 2026\n"
        )
        self.assertEqual(details["authorities"][0], "Developer ID Application: Example (TEAM)")
        self.assertEqual(details["TeamIdentifier"], "TEAM")
        self.assertEqual(details["flags"], "0x10000(runtime)")

    def test_unsafe_and_duplicate_zip_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            unsafe = Path(raw) / "unsafe.zip"
            with zipfile.ZipFile(unsafe, "w") as archive:
                archive.writestr("../escape", "x")
            with self.assertRaises(ValueError):
                validate_zip_entries(unsafe)

            duplicate = Path(raw) / "duplicate.zip"
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(duplicate, "w") as archive:
                    archive.writestr("Dockmint.app/file", "one")
                    archive.writestr("Dockmint.app/file", "two")
            with self.assertRaises(ValueError):
                validate_zip_entries(duplicate)

    def test_notarization_log_requires_accepted_without_errors(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "log.json"
            path.write_text(json.dumps({"status": "Accepted", "issues": []}), encoding="utf-8")
            validate_notarization_log(path)
            path.write_text(json.dumps({"status": "Accepted", "issues": None}), encoding="utf-8")
            validate_notarization_log(path)
            path.write_text(json.dumps({"status": "Accepted", "issues": {}}), encoding="utf-8")
            with self.assertRaises(ValueError):
                validate_notarization_log(path)
            path.write_text(
                json.dumps({"status": "Accepted", "issues": [{"severity": "error"}]}),
                encoding="utf-8",
            )
            with self.assertRaises(ValueError):
                validate_notarization_log(path)


if __name__ == "__main__":
    unittest.main()
