import difflib
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import prepare_player


class PlayerSetupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.patches = self.root / 'patches'
        self.patches.mkdir()
        self.output = self.root / '.dart_tool/player/better_player_plus'
        self.archive = self.output.parent / 'better_player_plus-1.4.1.tar.gz'
        self.archive.parent.mkdir(parents=True)
        self.name = 'lib/src/video_player/video_player.dart'
        self.before = 'class Player {\n  int generation = 0;\n}\n'
        self.after = 'class Player {\n  int generation = 1;\n}\n'
        self.manifest = {
            'version': '1.4.1',
            'files': {self.name: {
                'original': hashlib.sha256(self.before.encode()).hexdigest(),
                'patched': hashlib.sha256(self.after.encode()).hexdigest(),
            }},
        }
        (self.patches / 'dart-polling.patch').write_text(''.join(difflib.unified_diff(
            self.before.splitlines(True), self.after.splitlines(True),
            fromfile=f'a/{self.name}', tofile=f'b/{self.name}',
        )))
        self.write_archive()

    def write_archive(self, version='1.4.1', source=None):
        with tarfile.open(self.archive, 'w:gz') as archive:
            for name, text in {
                'pubspec.yaml': f'version: {version}\n',
                self.name: self.before if source is None else source,
                'ios/Player.swift': '// unchanged native source\n',
                'LICENSE': 'original license\n',
            }.items():
                data = text.encode()
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        self.manifest['archiveSha256'] = prepare_player.digest(self.archive)
        self.save_manifest()

    def save_manifest(self):
        (self.patches / 'polling-manifest.json').write_text(json.dumps(self.manifest))

    def prepare(self):
        return prepare_player.setup(self.root, self.patches)

    def test_repeatable_preparation_preserves_archive_native_source_and_license(self):
        for _ in range(2):
            self.prepare()
            self.assertEqual((self.output / self.name).read_text(), self.after)
            self.assertEqual((self.output / 'ios/Player.swift').read_text(), '// unchanged native source\n')
            self.assertEqual((self.output / 'LICENSE').read_text(), 'original license\n')
            self.assertEqual(prepare_player.digest(self.archive), self.manifest['archiveSha256'])

    def test_bad_archive_leaves_previous_copy_untouched(self):
        self.prepare()
        self.archive.write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'archive checksum'):
            self.prepare()
        self.assertEqual((self.output / self.name).read_text(), self.after)

    def test_changed_version_or_source_is_rejected(self):
        self.write_archive(version='1.4.2')
        with self.assertRaisesRegex(ValueError, 'version'):
            self.prepare()
        self.write_archive(source=self.before + '// unexpected\n')
        with self.assertRaisesRegex(ValueError, 'Unexpected BetterPlayer source'):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_invalid_patch_or_result_hash_is_rejected(self):
        self.manifest['files'][self.name]['patched'] = '0' * 64
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'Unexpected patched'):
            self.prepare()
        (self.patches / 'dart-polling.patch').write_text('invalid patch\n')
        with self.assertRaisesRegex(ValueError, 'Cannot apply'):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_download_is_checksum_verified_before_persisting(self):
        data = self.archive.read_bytes()
        self.archive.unlink()
        with patch('prepare_player.urlopen', return_value=io.BytesIO(b'corrupt')):
            with self.assertRaisesRegex(ValueError, 'downloaded.*checksum'):
                self.prepare()
        self.assertFalse(self.archive.exists())
        with patch('prepare_player.urlopen', return_value=io.BytesIO(data)) as download:
            self.prepare()
        download.assert_called_once_with(
            'https://pub.dev/api/archives/better_player_plus-1.4.1.tar.gz', timeout=60,
        )

    def test_personal_overrides_are_never_rewritten(self):
        override = self.root / 'pubspec_overrides.yaml'
        unrelated = 'dependency_overrides:\n  http: 1.6.0\n'
        override.write_text(unrelated)
        self.prepare()
        self.assertEqual(override.read_text(), unrelated)
        for name in ['better_player_plus', '"better_player_plus"', "'better_player_plus'"]:
            conflicting = f'dependency_overrides:\n  {name}:\n    path: /my/player\n'
            override.write_text(conflicting)
            with self.assertRaisesRegex(ValueError, 'pubspec_overrides.yaml'):
                self.prepare()
            self.assertEqual(override.read_text(), conflicting)

    def test_output_symlink_is_rejected_without_deleting_target(self):
        other = self.root / 'other'
        other.mkdir()
        (other / 'keep').write_text('keep')
        self.output.symlink_to(other, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.prepare()
        self.assertEqual((other / 'keep').read_text(), 'keep')

    def test_clean_checkout_builds_prepare_before_pub_resolution(self):
        repo = Path(__file__).resolve().parents[1]
        pubspec = (repo / 'pubspec.yaml').read_text()
        self.assertIn('  better_player_plus: 1.4.1\n', pubspec)
        self.assertIn('dependency_overrides:\n  # Generated and hash-verified by scripts/prepare_player.py before pub get.\n'
                      '  better_player_plus:\n    path: .dart_tool/player/better_player_plus\n', pubspec)
        for path in ['.github/workflows/ci.yml', '.github/actions/build-ios/action.yml']:
            workflow = (repo / path).read_text()
            self.assertLess(workflow.index('python3 scripts/prepare_player.py'), workflow.index('flutter pub get'))


if __name__ == '__main__':
    unittest.main()
