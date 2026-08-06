from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "build_homebrew_publication.py"
SPEC = importlib.util.spec_from_file_location("dockmint_publication", MODULE_PATH)
assert SPEC and SPEC.loader
publication = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publication)


class HomebrewPublicationTests(unittest.TestCase):
    def test_stable_bundle_seals_both_identities_and_architectures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); casks = root / "casks"; output = root / "output"; casks.mkdir()
            assets = []
            for channel, filename, prefix in (("stable", "dockmint.rb", "Dockmint"), ("beta", "dockmint@beta.rb", "Dockmint-Beta")):
                lines = ['cask "x" do', '  version "1.2.3"']
                for architecture, scope in (("arm64", "arm"), ("x64", "intel")):
                    digest = ("a" if channel == "stable" else "b") * 64
                    name = f"{prefix}-v1.2.3-macos-{architecture}.zip"
                    lines.extend([f"  on_{scope} do", f'    url "https://github.com/apotenza92/dockmint/releases/download/v#{{version}}/{name}"', f'    sha256 "{digest}"', "  end"])
                    assets.append({"name": name, "size": 42, "digest": f"sha256:{digest}"})
                lines.append("end")
                (casks / filename).write_text("\n".join(lines) + "\n")
            manifest = publication.build("stable", "v1.2.3", "c" * 40, 12, 2, casks, {"assets": assets}, output)
            self.assertEqual(["dockmint.rb", "dockmint@beta.rb"], manifest["casks"])
            self.assertEqual(4, len(manifest["artifacts"]))
            self.assertEqual(["arm64", "x64"], manifest["architectures"])
            self.assertEqual(12, json.loads((output / "manifest.json").read_text())["native_validation"]["workflow_run_id"])

    def test_rejects_public_digest_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); casks = root / "casks"; casks.mkdir()
            (casks / "dockmint@beta.rb").write_text('cask "x" do\n version "1.2.3-beta.1"\n on_arm do\n url "https://github.com/apotenza92/dockmint/releases/download/v#{version}/Dockmint-Beta-v1.2.3-beta.1-macos-arm64.zip"\n sha256 "' + "a" * 64 + '"\n end\n on_intel do\n url "https://github.com/apotenza92/dockmint/releases/download/v#{version}/Dockmint-Beta-v1.2.3-beta.1-macos-x64.zip"\n sha256 "' + "b" * 64 + '"\n end\nend\n')
            with self.assertRaisesRegex(ValueError, "asset mismatch"):
                publication.build("beta", "v1.2.3-beta.1", "c" * 40, 1, 1, casks, {"assets": []}, root / "out")


if __name__ == "__main__":
    unittest.main()
