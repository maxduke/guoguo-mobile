from pathlib import Path
import base64
import os
import re
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest


WORKFLOWS = Path(__file__).resolve().parents[1] / '.github/workflows'


def job(workflow, name):
    match = re.search(rf'^  {name}:\n(.*?)(?=^  \S|\Z)', workflow, re.M | re.S)
    if match is None:
        raise AssertionError(f'Missing job: {name}')
    return match.group(1)


class WorkflowTest(unittest.TestCase):
    def setUp(self):
        self.ci = (WORKFLOWS / 'ci.yml').read_text()
        self.release = (WORKFLOWS / 'release.yml').read_text()
        self.ios_build = (WORKFLOWS.parent / 'actions/build-ios/action.yml').read_text()

    def test_release_reuses_required_checks_and_shared_ios_build(self):
        self.assertIn('  workflow_call:\n    inputs:\n      checks-only:\n'
                      '        type: boolean\n        default: false\n', self.ci)
        checks = job(self.release, 'checks')
        self.assertIn('uses: ./.github/workflows/ci.yml', checks)
        self.assertIn('checks-only: true', checks)
        self.assertIn('if: ${{ !inputs.checks-only }}', job(self.ci, 'ios'))
        self.assertIn('needs: checks', job(self.ci, 'ios'))
        self.assertIn('python3 -m unittest discover', job(self.ci, 'checks'))
        for workflow in (self.ci, self.release):
            self.assertIn('uses: ./.github/actions/build-ios', workflow)
        self.assertIn('flutter build ios --release --no-codesign', self.ios_build)
        self.assertNotIn('continue-on-error:', self.ios_build)

    def test_only_development_download_is_optional_after_verified_build(self):
        ios = job(self.ci, 'ios')
        before_upload, upload = ios.split('      - uses: actions/upload-artifact@v4\n')
        self.assertIn('uses: ./.github/actions/build-ios', before_upload)
        self.assertNotIn('continue-on-error:', before_upload)
        self.assertNotIn("if: github.event_name != 'pull_request'", before_upload)
        self.assertIn("        if: github.event_name != 'pull_request'\n", upload)
        self.assertIn('continue-on-error: true', upload)
        self.assertIn('retention-days: 7', upload)
        self.assertIn("if: steps.development-artifact.outcome == 'failure'", upload)
        package = self.ios_build.index('python3 scripts/release.py package')
        verify = self.ios_build.index('python3 scripts/release.py verify --artifacts build/release')
        self.assertLess(package, verify)

    def test_release_builds_verifies_and_uploads_in_the_same_job(self):
        publish = job(self.release, 'release')
        self.assertIn("if: startsWith(github.ref, 'refs/tags/v')\n    needs: checks\n", publish)
        self.assertIn('runs-on: macos-15', publish)
        build = publish.index('uses: ./.github/actions/build-ios')
        self.assertLess(build, publish.index('gh release upload'))
        self.assertIn('gh release upload "$RELEASE_TAG" build/release/*', publish)
        self.assertNotIn('actions/download-artifact', self.release)
        self.assertNotIn('actions/upload-artifact', self.release)
        self.assertNotIn('gh run ', self.release)
        self.assertNotIn('run-id:', self.release)
        self.assertIn("if: always() && vars.ANDROID_RELEASE_ENABLED == 'true'", publish)
        self.assertNotIn('continue-on-error:', self.release)

    def test_tag_builds_are_not_cancelled_by_regular_ci(self):
        ci_header = self.ci.split('jobs:\n', 1)[0]
        release_header = self.release.split('jobs:\n', 1)[0]
        self.assertIn('group: ci-${{ github.workflow }}-${{ github.ref }}', ci_header)
        self.assertIn("cancel-in-progress: ${{ !startsWith(github.ref, 'refs/tags/') }}", ci_header)
        self.assertIn('group: release-${{ github.ref }}', release_header)
        self.assertIn('cancel-in-progress: false', release_header)

    def test_publication_retains_draft_and_immutable_release_guards(self):
        publish = job(self.release, 'release')
        self.assertIn('Refusing to overwrite a published release', publish)
        self.assertIn('--verify-tag --draft', publish)
        self.assertLess(publish.index('gh release upload'), publish.index('--draft=false'))
        self.assertNotIn('contents: write', self.ci)
        self.assertNotIn('contents: write', job(self.release, 'checks'))
        self.assertNotIn('gh release ', self.ci)

    def test_android_builds_are_required_and_only_download_storage_is_optional(self):
        android = job(self.ci, 'android')
        self.assertIn('needs: checks', android)
        build, upload = android.split('      - uses: actions/upload-artifact@v4\n')
        self.assertIn('uses: ./.github/actions/build-android', build)
        self.assertNotIn('continue-on-error:', build)
        self.assertIn('continue-on-error: true', upload)
        release = job(self.release, 'release')
        self.assertLess(release.index('uses: ./.github/actions/build-android'), release.index('gh release upload'))
        self.assertIn('mode: release', release)
        self.assertIn('secrets.ANDROID_KEYSTORE_BASE64', release)
        self.assertIn('vars.ANDROID_CERTIFICATE_SHA256', release)

    def test_android_signing_helper_restores_private_file_without_overwriting(self):
        match = re.search(r"^          python3 - <<'PY'\n(.*?)^          PY\n", self.release, re.M | re.S)
        self.assertIsNotNone(match)
        code = textwrap.dedent(match.group(1))
        fixture = b'fixture-keystore-bytes'
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            keystore = directory / 'guoguo-release.jks'
            environment_file = directory / 'environment'

            def restore(payload):
                return subprocess.run([sys.executable, '-c', code], capture_output=True, text=True, env={
                    **os.environ,
                    'ANDROID_KEYSTORE_BASE64': payload,
                    'RUNNER_TEMP': temporary,
                    'GITHUB_ENV': str(environment_file),
                })

            invalid = restore('invalid base64!')
            self.assertNotEqual(invalid.returncode, 0)
            self.assertFalse(keystore.exists())
            payload = base64.b64encode(fixture).decode()
            restored = restore(payload)
            self.assertEqual(restored.returncode, 0, restored.stderr)
            self.assertEqual(keystore.read_bytes(), fixture)
            self.assertEqual(stat.S_IMODE(keystore.stat().st_mode), 0o600)
            self.assertEqual(environment_file.read_text(), f'GUOGUO_ANDROID_KEYSTORE={keystore}\n')
            keystore.write_bytes(b'keep-existing-file')
            self.assertNotEqual(restore(payload).returncode, 0)
            self.assertEqual(keystore.read_bytes(), b'keep-existing-file')


if __name__ == '__main__':
    unittest.main()
