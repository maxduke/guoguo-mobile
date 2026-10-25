import struct
import unittest

from android_package import build_origin, check_identity, elf_16k


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
        data = bytearray(120)
        data[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<Q', data, 32, 64)
        struct.pack_into('<HH', data, 54, 56, 1)
        struct.pack_into('<I', data, 64, 1)
        struct.pack_into('<Q', data, 112, 16384)
        elf_16k(data)
        struct.pack_into('<Q', data, 112, 4096)
        with self.assertRaises(ValueError):
            elf_16k(data)


if __name__ == '__main__':
    unittest.main()
