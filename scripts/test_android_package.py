import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from android_package import ABIS, apk_variants, build_origin, check_identity, check_libraries, elf_16k, package
from core_identity import source_digest


def elf_fixture():
    data = bytearray(120)
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, 1)
    struct.pack_into('<I', data, 64, 1)
    struct.pack_into('<Q', data, 112, 16384)
    return data


def apk_fixture(path, abis, digest='source-digest', version='0.20.3+54', aot=True):
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('classes.dex', b'Lgo/Seq; Lmobile/Mobile; Lmobile/Client;')
        for abi in abis:
            libraries = {'libflutter.so', 'libgojni.so'} | ({'libapp.so'} if aot else set())
            for library in libraries:
                data = bytes(elf_fixture())
                if library == 'libgojni.so':
                    data += digest.encode() + version.encode()
                archive.writestr(f'lib/{abi}/{library}', data)


class AndroidPackageTest(unittest.TestCase):
    def test_local_package_does_not_claim_a_validation_run_built_it(self):
        environment = {'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_RUN_ID': '123'}
        self.assertEqual(build_origin(environment), {'buildEnvironment': 'local', 'run_url': ''})
        environment['GITHUB_ACTIONS'] = 'true'
        self.assertEqual(build_origin(environment)['run_url'], 'https://github.com/owner/repo/actions/runs/123')
        environment.pop('GITHUB_RUN_ID')
        with self.assertRaises(ValueError):
            build_origin(environment)

    def test_identity_rejects_wrong_version_unsigned_or_wrong_fixed_signer(self):
        manifest = 'android.intent.category.LEANBACK_LAUNCHER android:banner'
        badging = "package: name='com.maxduke.guoguo_mobile' versionCode='51' versionName='0.20.0'\nsdkVersion:'24'"
        fingerprint = 'a' * 64
        certificate = 'Signer #1 certificate DN: CN=Guoguo\nSigner #1 certificate SHA-256 digest: ' + fingerprint
        self.assertEqual(check_identity(badging, manifest, certificate, '0.20.0', '51', 'release', fingerprint)[0], 'com.maxduke.guoguo_mobile')
        for changed in [
            (badging.replace("'51'", "'50'"), manifest, certificate, fingerprint),
            (badging, '', certificate, fingerprint),
            (badging, manifest, '', fingerprint),
            (badging, manifest, certificate.replace('CN=Guoguo', 'CN=Android Debug'), fingerprint),
            (badging, manifest, certificate, 'b' * 64),
            (badging, manifest, certificate, ''),
        ]:
            with self.assertRaises(ValueError):
                check_identity(*changed[:3], '0.20.0', '51', 'release', changed[3])

    def test_64_bit_library_requires_16k_load_alignment(self):
        data = elf_fixture()
        elf_16k(data)
        struct.pack_into('<Q', data, 112, 4096)
        with self.assertRaises(ValueError):
            elf_16k(data)

    def test_optimized_preview_is_a_distinct_non_debuggable_test_app(self):
        badging = ("package: name='com.maxduke.guoguo_mobile.dev' versionCode='54' versionName='0.20.3-dev'\n"
                   "sdkVersion:'24'\napplication-label:'果果 测试'")
        manifest = 'android.intent.category.LEANBACK_LAUNCHER android:banner'
        certificate = 'Signer #1 certificate DN: CN=Android Debug\nSigner #1 certificate SHA-256 digest: ' + 'a' * 64
        self.assertEqual(check_identity(badging, manifest, certificate, '0.20.3', '54', 'preview')[0], 'com.maxduke.guoguo_mobile.dev')
        for changed, signer in [
            (badging + '\napplication-debuggable', certificate),
            (badging.replace("versionCode='54'", "versionCode='1054'"), certificate),
            (badging.replace('.dev', ''), certificate),
            (badging.replace('果果 测试', '果果'), certificate),
            (badging, certificate.replace('Android Debug', 'Guoguo')),
        ]:
            with self.subTest(badging=changed, signer=signer), self.assertRaises(ValueError):
                check_identity(changed, manifest, signer, '0.20.3', '54', 'preview')

    def test_split_input_requires_all_supported_abis_without_duplicates(self):
        apks = [Path(f'app-{abi}-release.apk') for abi in sorted(ABIS)]
        self.assertEqual(set(apk_variants(apks, 'preview', True)), ABIS)
        self.assertEqual(apk_variants(apks[0], 'release', False), {None: apks[0]})
        for invalid in [apks[:-1], apks + apks[:1], [apks[0]] * 3,
                        apks[:-1] + [Path('app-x86-release.apk')]]:
            with self.subTest(paths=invalid), self.assertRaises(ValueError):
                apk_variants(invalid, 'preview', True)

    def test_split_library_validation_keeps_strict_core_and_aot_contracts(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / 'app.apk'
            apk_fixture(apk, {'arm64-v8a'})
            self.assertEqual(check_libraries(apk, 'preview', 'source-digest', '0.20.3+54', {'arm64-v8a'}), ['arm64-v8a'])
            for expected, digest, version in [
                (ABIS, 'source-digest', '0.20.3+54'),
                ({'armeabi-v7a'}, 'source-digest', '0.20.3+54'),
                ({'arm64-v8a'}, 'older-source', '0.20.3+54'),
                ({'arm64-v8a'}, 'source-digest', '0.20.2+53'),
            ]:
                with self.subTest(expected=expected, digest=digest, version=version), self.assertRaises(ValueError):
                    check_libraries(apk, 'preview', digest, version, expected)
            apk_fixture(apk, {'arm64-v8a'}, aot=False)
            with self.assertRaises(ValueError):
                check_libraries(apk, 'preview', 'source-digest', '0.20.3+54', {'arm64-v8a'})
            apk_fixture(apk, {'arm64-v8a'})
            with zipfile.ZipFile(apk, 'a') as archive:
                archive.writestr('assets/flutter_assets/kernel_blob.bin', b'debug-kernel')
            with self.assertRaises(ValueError):
                check_libraries(apk, 'preview', 'source-digest', '0.20.3+54', {'arm64-v8a'})
            apk_fixture(apk, ABIS)
            self.assertEqual(set(check_libraries(apk, 'release', 'source-digest', '0.20.3+54')), ABIS)

    def test_all_split_packages_are_verified_before_output_and_have_separate_receipts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'pubspec.yaml').write_text('version: 0.20.3+54\n')
            (root / 'releases').mkdir()
            (root / 'releases/v0.20.3.md').write_text('Fixture release\n')
            (root / 'native/core').mkdir(parents=True)
            digest = source_digest(root)
            apks = [root / f'app-{abi}-release.apk' for abi in sorted(ABIS)]
            for apk, abi in zip(apks, sorted(ABIS)):
                apk_fixture(apk, {abi}, digest)

            def tool(tool_path, *arguments):
                if tool_path.name == 'apksigner':
                    return 'Signer #1 certificate DN: CN=Android Debug\nSigner #1 certificate SHA-256 digest: ' + 'a' * 64
                if arguments[:2] == ('dump', 'badging'):
                    return ("package: name='com.maxduke.guoguo_mobile.dev' versionCode='54' versionName='0.20.3-dev'\n"
                            "sdkVersion:'24'\napplication-label:'果果 测试'")
                if arguments[:2] == ('dump', 'xmltree'):
                    return 'android.intent.category.LEANBACK_LAUNCHER android:banner'
                return ''

            environment = {'GITHUB_SHA': 'a' * 40}
            with patch.dict(os.environ, environment, clear=True), patch('android_package.run', side_effect=tool):
                apk_fixture(apks[-1], {sorted(ABIS)[-1]}, 'stale-source')
                with self.assertRaises(ValueError):
                    package(apks, root / 'tools', 'preview', root=root, split_per_abi=True)
                output = root / 'build/android-package'
                self.assertFalse(output.exists())
                apk_fixture(apks[-1], {sorted(ABIS)[-1]}, digest)
                package(apks, root / 'tools', 'preview', root=root, split_per_abi=True)
                self.assertEqual(len(list(output.iterdir())), 9)
                for abi in ABIS:
                    info = json.loads((output / f'build-info-android-{abi}.json').read_text())
                    self.assertEqual(info['abis'], [abi])
                    self.assertEqual(info['commit'], environment['GITHUB_SHA'])
                    self.assertEqual(info['mode'], 'preview')
                    entries = (output / f'SHA256SUMS-android-{abi}').read_text().splitlines()
                    self.assertEqual(len(entries), 2)
                    for entry in entries:
                        checksum, filename = entry.split('  ')
                        self.assertEqual(hashlib.sha256((output / filename).read_bytes()).hexdigest(), checksum)


if __name__ == '__main__':
    unittest.main()
