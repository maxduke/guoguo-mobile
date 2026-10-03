import difflib
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import prepare_ios_player


class IOSPlayerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.package = self.root / "package"
        self.patches = self.root / "patches"
        self.output = self.root / "build/player"
        self.package.mkdir()
        self.patches.mkdir()
        (self.package / "pubspec.yaml").write_text("version: 1.4.1\n")
        (self.package / "LICENSE").write_text("original license\n")
        self.name = "ios/better_player_plus/Sources/better_player_plus/Player.swift"
        self.source = self.package / self.name
        self.source.parent.mkdir(parents=True)
        self.before = "class Player {\n    let composition = true\n}\n"
        self.after = "class Player {\n    let composition = false\n}\n"
        self.source.write_text(self.before)
        self.manifest = {
            "version": "1.4.1",
            "files": {self.name: {
                "original": hashlib.sha256(self.before.encode()).hexdigest(),
                "patched": hashlib.sha256(self.after.encode()).hexdigest(),
            }},
            "extraFiles": ["Policy.swift"],
        }
        (self.patches / "Policy.swift").write_text("enum Policy {}\n")
        (self.patches / "ios-hls.patch").write_text("".join(difflib.unified_diff(
            self.before.splitlines(True), self.after.splitlines(True),
            fromfile=f"a/{self.name}", tofile=f"b/{self.name}",
        )))
        self.save_manifest()

    def save_manifest(self):
        (self.patches / "manifest.json").write_text(json.dumps(self.manifest))

    def prepare(self):
        return prepare_ios_player.prepare(self.package, self.output, self.patches)

    def test_isolated_copy_is_repeatable_and_keeps_original_source(self):
        for _ in range(2):
            self.prepare()
            self.assertEqual(self.source.read_text(), self.before)
            self.assertEqual((self.output / self.name).read_text(), self.after)
            self.assertEqual((self.output / "LICENSE").read_text(), "original license\n")
            policy = self.output / self.name
            self.assertEqual((policy.parent / "Policy.swift").read_text(), "enum Policy {}\n")

    def test_changed_dependency_version_is_rejected(self):
        (self.package / "pubspec.yaml").write_text("version: 1.4.2\n")
        with self.assertRaisesRegex(ValueError, "version"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_changed_source_is_rejected_without_replacing_previous_build(self):
        self.prepare()
        self.source.write_text(self.before + "// changed\n")
        with self.assertRaisesRegex(ValueError, "Unexpected BetterPlayer source"):
            self.prepare()
        self.assertEqual((self.output / self.name).read_text(), self.after)

    def test_invalid_patch_cannot_produce_a_build_copy(self):
        (self.patches / "ios-hls.patch").write_text("invalid patch\n")
        with self.assertRaisesRegex(ValueError, "Cannot apply"):
            self.prepare()
        self.assertEqual(self.source.read_text(), self.before)
        self.assertFalse(self.output.exists())

    def test_wrong_result_hash_cannot_produce_a_build_copy(self):
        self.manifest["files"][self.name]["patched"] = "0" * 64
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "Unexpected patched"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_package_uri_resolution_and_missing_package(self):
        config = self.root / ".dart_tool/package_config.json"
        config.parent.mkdir()
        config.write_text(json.dumps({"packages": [{"name": "better_player_plus", "rootUri": "../package/"}]}))
        self.assertEqual(prepare_ios_player.find_package(self.root).resolve(), self.package)
        config.write_text('{"packages": []}')
        with self.assertRaisesRegex(ValueError, "missing"):
            prepare_ios_player.find_package(self.root)

    def test_output_symlink_does_not_delete_another_directory(self):
        other = self.root / "other"
        other.mkdir()
        (other / "keep").write_text("keep")
        self.output.parent.mkdir()
        self.output.symlink_to(other, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.prepare()
        self.assertEqual((other / "keep").read_text(), "keep")
