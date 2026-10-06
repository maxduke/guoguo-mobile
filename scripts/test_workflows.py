from pathlib import Path
import re
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

    def test_release_reuses_checks_and_builds_with_one_day_retention(self):
        self.assertIn('  workflow_call:\n    inputs:\n      artifact-retention-days:\n'
                      '        type: number\n        default: 7\n', self.ci)
        build = job(self.release, 'build')
        self.assertIn('uses: ./.github/workflows/ci.yml', build)
        self.assertIn('artifact-retention-days: 1', build)
        self.assertIn('needs: checks', job(self.ci, 'ios'))
        self.assertIn('python3 -m unittest discover', job(self.ci, 'checks'))
        self.assertIn('flutter build ios --release --no-codesign', job(self.ci, 'ios'))

    def test_pr_builds_but_does_not_upload_ipa(self):
        ios = job(self.ci, 'ios')
        before_upload, upload = ios.split('      - uses: actions/upload-artifact@v4\n')
        self.assertIn('python3 scripts/release.py package', before_upload)
        self.assertNotIn("if: github.event_name != 'pull_request'", before_upload)
        self.assertIn("        if: github.event_name != 'pull_request'\n", upload)
        self.assertIn('retention-days: ${{ inputs.artifact-retention-days || 7 }}', upload)

    def test_release_downloads_only_the_current_run_package(self):
        publish = job(self.release, 'release')
        self.assertIn("if: startsWith(github.ref, 'refs/tags/v')\n    needs: build\n", publish)
        self.assertIn('uses: actions/download-artifact@v4', publish)
        self.assertIn('name: Guoguo-iOS-unsigned', publish)
        self.assertIn('path: release-assets', publish)
        self.assertNotIn('gh run ', self.release)
        self.assertNotIn('run-id:', self.release)
        self.assertNotIn('always()', publish)
        self.assertNotIn('continue-on-error:', self.release)
        verify = publish.index('python3 scripts/release.py verify --artifacts release-assets')
        self.assertLess(verify, publish.index('gh release upload'))

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
        self.assertNotIn('contents: write', job(self.release, 'build'))
        self.assertNotIn('gh release ', self.ci)


if __name__ == '__main__':
    unittest.main()
