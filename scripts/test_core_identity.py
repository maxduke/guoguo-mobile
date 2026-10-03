import json
from pathlib import Path
import tempfile
import unittest
import core_identity


class CoreIdentityTests(unittest.TestCase):
    def test_stale_source_artifact_and_platform_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            core = root / 'native/core'
            core.mkdir(parents=True)
            source = core / 'main.go'
            source.write_text('package mobile\n')
            artifact, manifest = root / 'core.aar', root / 'manifest.json'
            artifact.write_bytes(b'native core')
            core_identity.write_manifest(artifact, manifest, 'android', root)
            core_identity.verify(artifact, manifest, 'android', root)
            with self.assertRaises(ValueError):
                core_identity.verify(artifact, manifest, 'ios', root)
            artifact.write_bytes(b'stale binary')
            with self.assertRaises(ValueError):
                core_identity.verify(artifact, manifest, 'android', root)
            core_identity.write_manifest(artifact, manifest, 'android', root)
            source.write_text('package mobile\nvar Changed = true\n')
            with self.assertRaises(ValueError):
                core_identity.verify(artifact, manifest, 'android', root)

    def test_framework_members_are_all_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'native/core').mkdir(parents=True)
            artifact = root / 'core.xcframework'
            artifact.mkdir()
            (artifact / 'binary').write_bytes(b'core')
            manifest = root / 'manifest.json'
            core_identity.write_manifest(artifact, manifest, 'ios', root)
            document = json.loads(manifest.read_text())
            self.assertEqual(document['protocol'], 2)
            (artifact / 'extra').write_bytes(b'unexpected')
            with self.assertRaises(ValueError):
                core_identity.verify(artifact, manifest, 'ios', root)
