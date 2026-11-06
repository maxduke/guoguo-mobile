import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

import ios_source


class IOSSourceTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.filename = "Guoguo-0.20.9+63-ios-unsigned.ipa"
        self.app = {
            "CFBundleIdentifier": ios_source.BUNDLE_ID,
            "CFBundleShortVersionString": "0.20.9",
            "CFBundleVersion": "63",
            "MinimumOSVersion": "15.0",
            "NSLocalNetworkUsageDescription": "查找同一 Wi-Fi 下的电视。",
        }
        self.info = {"version": "0.20.9", "build": "63", "commit": "a" * 40,
                     "platform": "ios", "signed": False}
        self.release = {"tag_name": "v0.20.9", "published_at": "2026-11-06T04:11:37Z",
                        "body": "# 果果 v0.20.9\n\n- 改善搜索。\n\n工程验证及内部文档。"}
        self.write_ipa()

    def write_ipa(self, extra=None):
        with zipfile.ZipFile(self.directory / self.filename, "w") as archive:
            archive.writestr("Payload/Runner.app/Info.plist", plistlib.dumps(self.app))
            archive.writestr("Payload/Runner.app/Runner", b"fixture executable")
            if extra:
                archive.writestr("Payload/Runner.app/" + extra, b"fixture")
        self.checksums()

    def checksums(self):
        (self.directory / "build-info.json").write_text(json.dumps(self.info))
        lines = []
        for filename in (self.filename, "build-info.json"):
            checksum = hashlib.sha256((self.directory / filename).read_bytes()).hexdigest()
            lines.append(f"{checksum}  {filename}\n")
        (self.directory / "SHA256SUMS").write_text("".join(lines))

    def verify(self, tag="v0.20.9", commit="a" * 40):
        return ios_source.verify_package(self.directory, tag, commit)

    def test_verified_ipa_has_one_shared_source_and_pinned_downloads(self):
        app, filename = self.verify()
        source = ios_source.generate("maxduke/guoguo-mobile", self.release, app, filename, 123456)
        self.assertEqual(source["sourceURL"], "https://github.com/maxduke/guoguo-mobile/releases/latest/download/apps.json")
        entry = source["apps"][0]
        version = entry["versions"][0]
        self.assertEqual(entry["bundleIdentifier"], "com.maxduke.guoguoMobile")
        self.assertEqual(entry["appPermissions"], {
            "entitlements": [], "privacy": {"NSLocalNetworkUsageDescription": "查找同一 Wi-Fi 下的电视。"}})
        self.assertEqual(version["buildVersion"], "63")
        self.assertEqual(version["buildNumber"], "63")
        self.assertEqual(version["minOSVersion"], "15.0")
        self.assertEqual(version["size"], 123456)
        self.assertEqual(version["localizedDescription"], "- 改善搜索。")
        self.assertEqual(version["downloadURL"], "https://github.com/maxduke/guoguo-mobile/releases/download/v0.20.9/Guoguo-0.20.9%2B63-ios-unsigned.ipa")
        self.assertEqual(entry["iconURL"], "https://github.com/maxduke/guoguo-mobile/releases/download/v0.20.9/icon.png")
        for key in ("version", "size", "minOSVersion", "downloadURL"):
            self.assertEqual(entry[key], version[key])
        self.assertEqual(entry["versionDate"], version["date"])
        self.assertEqual(entry["versionDescription"], version["localizedDescription"])

    def test_rejects_non_release_tags_and_stale_source_commit(self):
        for tag in ("main", "v0.20.9-beta", "v0.20.8"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.verify(tag=tag)
        with self.assertRaisesRegex(ValueError, "metadata"):
            self.verify(commit="b" * 40)

    def test_corrupt_bytes_are_rejected(self):
        with (self.directory / self.filename).open("ab") as output:
            output.write(b"corruption")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            self.verify()

    def test_ipa_contents_must_match_and_permissions_must_be_reviewed(self):
        for key, value in (("CFBundleIdentifier", "com.other.app"), ("CFBundleVersion", "62"),
                           ("CFBundleShortVersionString", "0.20.8"), ("MinimumOSVersion", "")):
            with self.subTest(key=key):
                original = self.app[key]
                self.app[key] = value
                self.write_ipa()
                with self.assertRaises(ValueError):
                    self.verify()
                self.app[key] = original
        for path in ("embedded.mobileprovision", "_CodeSignature/CodeResources", "PlugIns/Test.appex/Info.plist"):
            with self.subTest(path=path):
                self.write_ipa(path)
                with self.assertRaises(ValueError):
                    self.verify()

    def test_checksum_paths_duplicates_and_missing_entries_are_rejected(self):
        manifest = self.directory / "SHA256SUMS"
        original = manifest.read_text()
        for value in ("a" * 64 + "  ../outside\n", original + original, original.splitlines()[0]):
            with self.subTest(value=value):
                manifest.write_text(value)
                with self.assertRaises(ValueError):
                    self.verify()

    def test_generation_only_adds_source_assets_and_preserves_original_bytes(self):
        before = {item.name: item.read_bytes() for item in self.directory.iterdir()}
        (self.directory / "releases").mkdir()
        (self.directory / "releases/v0.20.9.md").write_text(self.release["body"])
        icon = self.directory / "ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png"
        icon.parent.mkdir(parents=True)
        icon.write_bytes(b"fixture icon")
        # Android assets can share build/release without entering the iOS source.
        (self.directory / "Guoguo-android-arm64.apk").write_bytes(b"fixture Android package")
        ios_source.write_source(self.directory, "maxduke/guoguo-mobile", "v0.20.9", "a" * 40,
                                self.release["published_at"], root=self.directory)
        for name, content in before.items():
            self.assertEqual((self.directory / name).read_bytes(), content)
        source = json.loads((self.directory / "apps.json").read_text())
        self.assertEqual(source["apps"][0]["versions"][0]["size"], len(before[self.filename]))
        self.assertEqual((self.directory / "icon.png").read_bytes(), b"fixture icon")
        self.assertNotIn("android", json.dumps(source).lower())

    def test_invalid_source_repository_or_date_is_rejected(self):
        for repo, date in (("https://github.com/example/repo", "2026-11-06T00:00:00Z"),
                           ("example/repo", "2026-11-06"), ("example/repo", "invalid")):
            with self.subTest(repo=repo, date=date), self.assertRaises(ValueError):
                ios_source.generate(repo, {**self.release, "published_at": date}, self.app, self.filename, 123)


if __name__ == "__main__":
    unittest.main()
