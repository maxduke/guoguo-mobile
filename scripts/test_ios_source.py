import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import ios_source
import publish_ios_source as publisher


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
        self.release = {"tag_name": "v0.20.9", "draft": False, "prerelease": False,
                        "published_at": "2026-11-06T04:11:37Z", "body": "修复与改进。"}
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
        self.release["assets"] = []
        lines = []
        for filename in (self.filename, "build-info.json"):
            path = self.directory / filename
            checksum = hashlib.sha256(path.read_bytes()).hexdigest()
            lines.append(f"{checksum}  {filename}\n")
            self.release["assets"].append({"name": filename, "size": path.stat().st_size,
                                           "digest": f"sha256:{checksum}"})
        (self.directory / "SHA256SUMS").write_text("".join(lines))

    def generate(self, previous=None):
        filename = f"Guoguo-{self.app['CFBundleShortVersionString']}+{self.app['CFBundleVersion']}-ios-unsigned.ipa"
        return ios_source.generate("example/guoguo-releases", self.release, self.app,
                                   filename, 123456, previous)

    def test_store_release_notes_show_changes_without_internal_footnotes(self):
        release = {**self.release, "body": "# 果果 v0.20.9\n\n- 改善搜索。\n\n- 改善大字体。\n\n工程验证和内部文档。"}
        self.assertEqual(ios_source.release_notes(release), "- 改善搜索。\n\n- 改善大字体。")

    def test_verified_ipa_identity_and_real_permissions(self):
        app, filename = ios_source.verify_package(self.directory, self.release, "a" * 40)
        self.assertEqual((app, filename), (self.app, self.filename))
        source = self.generate()
        entry = source["apps"][0]
        version = entry["versions"][0]
        self.assertEqual(entry["appPermissions"]["privacy"], {
            "NSLocalNetworkUsageDescription": "查找同一 Wi-Fi 下的电视。"})
        self.assertEqual(entry["appPermissions"]["entitlements"], [])
        self.assertEqual(version["buildVersion"], "63")
        self.assertEqual(version["buildNumber"], "63")
        self.assertEqual(version["minOSVersion"], "15.0")
        self.assertEqual(version["size"], 123456)
        self.assertTrue(version["downloadURL"].endswith("/v0.20.9/Guoguo-0.20.9%2B63-ios-unsigned.ipa"))
        for key in ("version", "size", "minOSVersion", "downloadURL"):
            self.assertEqual(entry[key], version[key])
        self.assertEqual(entry["versionDate"], version["date"])
        self.assertEqual(entry["versionDescription"], version["localizedDescription"])

    def test_rejects_unpublished_unstable_or_wrong_source_identity(self):
        for key, value in (("draft", True), ("prerelease", True), ("tag_name", "v0.20.8"), ("published_at", None)):
            with self.subTest(key=key):
                release = {**self.release, key: value}
                with self.assertRaises(ValueError):
                    ios_source.verify_package(self.directory, release, "a" * 40)
        with self.assertRaisesRegex(ValueError, "metadata"):
            ios_source.verify_package(self.directory, self.release, "b" * 40)

    def test_rejects_corrupt_bytes_and_forged_asset_metadata(self):
        self.release["assets"][0]["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ValueError, "Published asset"):
            ios_source.verify_package(self.directory, self.release, "a" * 40)
        self.checksums()
        with (self.directory / self.filename).open("ab") as output:
            output.write(b"corruption")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            ios_source.verify_package(self.directory, self.release, "a" * 40)

    def test_ipa_contents_must_match_and_permissions_must_be_reviewed(self):
        for key, value in (("CFBundleIdentifier", "com.other.app"), ("CFBundleVersion", "62"),
                           ("CFBundleShortVersionString", "0.20.8"), ("MinimumOSVersion", "")):
            with self.subTest(key=key):
                original = self.app[key]
                self.app[key] = value
                self.write_ipa()
                with self.assertRaises(ValueError):
                    ios_source.verify_package(self.directory, self.release, "a" * 40)
                self.app[key] = original
        for path in ("embedded.mobileprovision", "_CodeSignature/CodeResources", "PlugIns/Test.appex/Info.plist"):
            with self.subTest(path=path):
                self.write_ipa(path)
                with self.assertRaises(ValueError):
                    ios_source.verify_package(self.directory, self.release, "a" * 40)

    def test_checksum_paths_duplicates_and_missing_entries_are_rejected(self):
        manifest = self.directory / "SHA256SUMS"
        original = manifest.read_text()
        for value in ("a" * 64 + "  ../outside\n", original + original, original.splitlines()[0]):
            with self.subTest(value=value):
                manifest.write_text(value)
                with self.assertRaises(ValueError):
                    ios_source.verify_package(self.directory, self.release, "a" * 40)

    def test_new_versions_sort_numerically_and_old_backfills_do_not_roll_back(self):
        old = self.generate()
        self.app.update(CFBundleShortVersionString="0.20.10", CFBundleVersion="64",
                        NSCameraUsageDescription="扫描投屏码。")
        self.release.update(tag_name="v0.20.10", published_at="2026-11-07T01:00:00Z")
        newer = self.generate(old)
        self.assertEqual(newer["apps"][0]["version"], "0.20.10")
        snapshot = copy.deepcopy(newer)
        self.app.pop("NSCameraUsageDescription")
        self.app.update(CFBundleShortVersionString="0.20.8", CFBundleVersion="62")
        self.release.update(tag_name="v0.20.8", published_at="2026-11-02T01:00:00Z")
        backfill = self.generate(newer)
        entry = backfill["apps"][0]
        self.assertEqual([item["version"] for item in entry["versions"]], ["0.20.10", "0.20.9", "0.20.8"])
        self.assertEqual(entry["version"], "0.20.10")
        self.assertIn("NSCameraUsageDescription", entry["appPermissions"]["privacy"])
        self.assertEqual(newer, snapshot)
        self.assertEqual(old["apps"][0]["version"], "0.20.9")

    def test_retries_are_idempotent_but_cannot_rewrite_existing_version(self):
        source = self.generate()
        self.assertEqual(self.generate(source), source)
        self.release["body"] = "Different release bytes or identity must be reviewed."
        with self.assertRaisesRegex(ValueError, "already present"):
            self.generate(source)
        for key, value in (("identifier", "other"), ("sourceURL", "https://other.example/source.json")):
            modified = {**source, key: value}
            with self.assertRaisesRegex(ValueError, "identity or URL"):
                self.generate(modified)

    @patch.dict(os.environ, {"GH_TOKEN": "private-fixture-token", "IOS_SOURCE_TOKEN": "public-fixture-token"})
    @patch("publish_ios_source.subprocess.run")
    def test_public_token_is_used_only_as_environment_not_an_argument(self, execute):
        execute.return_value.returncode = 0
        execute.return_value.stdout = "{}"
        publisher.api("repos/example/public", os.environ["IOS_SOURCE_TOKEN"])
        self.assertEqual(execute.call_args.kwargs["env"]["GH_TOKEN"], "public-fixture-token")
        self.assertNotIn("public-fixture-token", " ".join(execute.call_args.args[0]))
        publisher.api("repos/example/private")
        self.assertEqual(execute.call_args.kwargs["env"]["GH_TOKEN"], "private-fixture-token")

    @patch("publish_ios_source.api")
    def test_published_source_update_uses_compare_and_swap(self, request):
        request.return_value = {"sha": "existing-file-sha", "content": base64.b64encode(b"old").decode()}
        publisher.put_file("example/public", "icon.png", b"new", "fixture-token", "Update icon")
        payload = request.call_args.args[2]
        self.assertEqual(payload["sha"], "existing-file-sha")
        self.assertEqual(base64.b64decode(payload["content"]), b"new")

    @patch("publish_ios_source.api")
    def test_refuses_to_use_private_or_source_repository_as_distribution(self, request):
        with self.assertRaisesRegex(ValueError, "separate public"):
            publisher.publish("example/private", "example/private")
        request.return_value = {"private": True, "default_branch": "main"}
        with self.assertRaisesRegex(ValueError, "must be public"):
            publisher.publish("example/private", "example/distribution")
        self.assertEqual(request.call_count, 1)

    def publication_fixture(self, bad_upload=False, existing=False):
        events = []
        expected = [{"name": filename, "digest": "sha256:" + ios_source.digest(self.directory / filename)}
                    for filename in (self.filename, "build-info.json", "SHA256SUMS")]
        mirror = {"draft": False, "assets": expected} if existing else None

        def request(path, token=None, payload=None, missing=False):
            nonlocal mirror
            if path == "repos/example/distribution":
                return {"private": False, "default_branch": "main"}
            if path == "repos/example/private/releases/tags/v0.20.9":
                return self.release
            if path == "repos/example/private/git/ref/tags/v0.20.9":
                return {"object": {"type": "commit", "sha": "a" * 40}}
            if path == "repos/example/distribution/contents/apps.json?ref=main":
                return None
            if path == "repos/example/distribution/releases/tags/v0.20.9":
                return mirror
            if path == "repos/example/distribution/contents/apps.json":
                self.assertIsNotNone(mirror)
                self.assertFalse(mirror["draft"], "The feed must not point at draft downloads")
                feed = json.loads(base64.b64decode(payload["content"]))
                self.assertEqual(feed["apps"][0]["version"], "0.20.9")
                events.append("feed")
                return {}
            raise AssertionError(f"Unexpected request: {path}")

        def command(arguments, token=None, payload=None, missing=False):
            nonlocal mirror
            if arguments[:2] == ["release", "download"]:
                directory = Path(arguments[arguments.index("--dir") + 1])
                for index, value in enumerate(arguments):
                    if value == "--pattern":
                        shutil.copyfile(self.directory / arguments[index + 1], directory / arguments[index + 1])
            elif arguments[:2] == ["release", "create"]:
                self.assertIn("--draft", arguments)
                mirror = {"draft": True, "assets": []}
                events.append("draft")
            elif arguments[:2] == ["release", "upload"]:
                mirror["assets"] = copy.deepcopy(expected)
                if bad_upload:
                    mirror["assets"][0]["digest"] = "sha256:" + "0" * 64
                events.append("upload")
            elif arguments[:2] == ["release", "edit"]:
                self.assertIn("--draft=false", arguments)
                mirror["draft"] = False
                events.append("publish")
            else:
                raise AssertionError(f"Unexpected command: {arguments}")
            return ""

        self.enterContext(patch("publish_ios_source.api", side_effect=request))
        self.enterContext(patch("publish_ios_source.gh", side_effect=command))
        write = self.enterContext(patch("publish_ios_source.put_file"))
        return events, write

    def test_mirror_is_verified_and_published_before_the_feed_advances(self):
        events, _ = self.publication_fixture()
        publisher.publish("example/private", "example/distribution", "v0.20.9", output=self.directory / "preview")
        self.assertEqual(events, ["draft", "upload", "publish", "feed"])

    def test_bad_uploaded_asset_leaves_draft_and_source_untouched(self):
        events, _ = self.publication_fixture(bad_upload=True)
        with self.assertRaisesRegex(ValueError, "remains a draft"):
            publisher.publish("example/private", "example/distribution", "v0.20.9", output=self.directory / "preview")
        self.assertEqual(events, ["draft", "upload"])

    def test_dry_run_and_corrupt_source_never_write_public_data(self):
        events, write = self.publication_fixture()
        publisher.publish("example/private", "example/distribution", "v0.20.9", dry_run=True, output=self.directory / "preview")
        self.assertEqual(events, [])
        write.assert_not_called()
        self.release["assets"][0]["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ValueError, "Published asset"):
            publisher.publish("example/private", "example/distribution", "v0.20.9", output=self.directory / "preview")
        self.assertEqual(events, [])
        write.assert_not_called()

    def test_retry_recovers_source_without_reuploading_published_ipa(self):
        events, _ = self.publication_fixture(existing=True)
        publisher.publish("example/private", "example/distribution", "v0.20.9", output=self.directory / "preview")
        self.assertEqual(events, ["feed"])


if __name__ == "__main__":
    unittest.main()
