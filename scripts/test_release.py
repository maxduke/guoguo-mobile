import hashlib
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import release


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'pubspec.yaml').write_text('name: test\nversion: 0.3.0+5\n')
        (self.root / 'releases').mkdir()
        (self.root / 'releases/v0.3.0.md').write_text('Release notes\n')
        self.app = self.root / 'build/ios/iphoneos/Runner.app'
        self.app.mkdir(parents=True)
        self.info('0.3.0', '5')
        (self.app / 'Runner').write_bytes(b'fixture executable')
        (self.app / 'Runner').chmod(0o755)

    def info(self, version, build):
        with (self.app / 'Info.plist').open('wb') as target:
            plistlib.dump({'CFBundleShortVersionString': version, 'CFBundleVersion': build, 'CFBundleExecutable': 'Runner'}, target)

    def test_tag_must_match(self):
        self.assertEqual(release.validate(self.root, 'v0.3.0'), ('0.3.0', '5'))
        with self.assertRaises(ValueError):
            release.validate(self.root, 'v0.2.1')

    def test_notes_required(self):
        (self.root / 'releases/v0.3.0.md').unlink()
        with self.assertRaises(ValueError):
            release.validate(self.root)

    def test_stale_build_rejected(self):
        self.info('0.2.1', '4')
        with self.assertRaises(ValueError):
            release.package(self.root)

    @patch.dict(os.environ, {'GITHUB_SHA': 'a' * 40})
    def test_package_metadata_checksum_and_executable_permissions(self):
        release.package(self.root, 'v0.3.0')
        output = self.root / 'build/release'
        with zipfile.ZipFile(output / 'Guoguo-0.3.0+5-ios-unsigned.ipa') as archive:
            self.assertEqual(archive.read('Payload/Runner.app/Runner'), b'fixture executable')
            self.assertEqual((archive.getinfo('Payload/Runner.app/Runner').external_attr >> 16) & 0o777, 0o755)
        manifest = json.loads((output / 'build-info.json').read_text())
        self.assertEqual(manifest['commit'], 'a' * 40)
        self.assertFalse(manifest['signed'])
        for line in (output / 'SHA256SUMS').read_text().splitlines():
            checksum, name = line.split('  ')
            self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), checksum)


if __name__ == '__main__':
    unittest.main()
