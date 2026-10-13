"""Tests for the TypeScript SDK's real release-gate and release-tag entry points."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SDKMaintenanceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Tiny fixture tree with the real metadata and hooks; no SDK builds or deps.
        paths = {'.github/CODEOWNERS', '.github/workflows/ci.yml', 'scripts/sdk-release.mjs',
                 'scripts/sdk-release-tag.py', 'sdk/typescript/package.json',
                 '.github/workflows/sdk-release-gate.yml', '.github/workflows/sdk-publish.yml',
                 'sdk/typescript/scripts/verify-contract.mjs', 'sdk/typescript/src/http.ts'}
        paths.update(f'sdk/typescript/{file}' for file in ['README.md', 'CHANGELOG.md', 'LICENSE'])
        for path in paths:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, target)
        (self.root / 'sdk/contract').mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'SDK gate test')
        self.git('config', 'user.email', 'sdk-gate@example.invalid')
        self.commit()
        self.base = self.git('rev-parse', 'HEAD')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')

    def change(self, path, transform):
        target = self.root / path
        target.write_text(transform(target.read_text()))

    def append(self, path, text='\n# changed\n'):
        self.change(path, lambda s: s + text)

    def bump_typescript(self):
        old = json.loads((self.root / 'sdk/typescript/package.json').read_text())['version']
        new = old.rsplit('.', 1)[0] + '.' + str(int(old.rsplit('.', 1)[1]) + 1)
        for file in ['sdk/typescript/package.json', 'sdk/typescript/src/http.ts']:
            self.change(file, lambda s: s.replace(old, new))
        return new

    def tag_fixture(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        remote = Path(temp.name) / 'origin.git'
        subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
        self.git('remote', 'add', 'origin', str(remote))
        version = self.bump_typescript()
        self.commit()
        return version

    def upload_evidence(self, source, conclusion='success', attempt=1):
        path = f'/repos/test/fountain/actions/runs/12345/attempts/{attempt}'
        return {
            path: {'id': 12345, 'run_attempt': attempt,
                   'repository': {'full_name': 'test/fountain'}, 'head_sha': source,
                   'head_branch': 'main', 'path': '.github/workflows/sdk-publish.yml@main',
                   'event': 'push', 'status': 'completed'},
            f'{path}/jobs?per_page=100&page=1': {
                'total_count': 1, 'jobs': [{
                    'name': 'Publish to npm', 'run_id': 12345, 'head_sha': source,
                    'status': 'completed', 'conclusion': 'failure',
                    'steps': [
                        {'name': 'Publish', 'status': 'completed', 'conclusion': conclusion},
                        {'name': 'Record the release as a tag', 'status': 'completed', 'conclusion': 'failure'},
                    ],
                }],
            },
        }

    def record_tag(self, version, published=False, attempt=1, evidence=None, success=True):
        env = dict(os.environ, GITHUB_ACTIONS='true', GITHUB_REF='refs/heads/main',
                   GITHUB_SHA=self.git('rev-parse', 'HEAD'), GITHUB_RUN_ATTEMPT=str(attempt),
                   GITHUB_REPOSITORY='test/fountain', GITHUB_RUN_ID='12345',
                   GH_TOKEN='test-only-token', SDK_TEST_API=json.dumps(evidence or {}))
        # Execute the real CLI and real Git writes; only the remote Actions API
        # transport is replaced. An unexpected request fails instead of networking.
        harness = """
import io, json, os, runpy, sys, urllib.error, urllib.request
fixtures = json.loads(os.environ.pop('SDK_TEST_API'))
def response(request, timeout):
    assert request.full_url.startswith('https://api.github.com/')
    assert request.get_header('Authorization') == 'Bearer test-only-token'
    fixture = fixtures[request.full_url.removeprefix('https://api.github.com')]
    if '_status' in fixture:
        raise urllib.error.HTTPError(request.full_url, fixture['_status'], 'Unavailable evidence', {}, None)
    return io.BytesIO(json.dumps(fixture).encode())
urllib.request.urlopen = response
sys.argv = ['scripts/sdk-release-tag.py', *sys.argv[1:]]
runpy.run_path(sys.argv[0], run_name='__main__')
"""
        command = [shutil.which('python3'), '-c', harness, 'typescript', version]
        if published:
            command.append('--published-now')
        result = subprocess.run(command, cwd=self.root, env=env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stdout + result.stderr

    def test_source_tag_is_idempotent_and_not_moved_by_docs_push(self):
        version = self.tag_fixture()
        source = self.git('rev-parse', 'HEAD')
        self.record_tag(version, published=True)
        self.record_tag(version, attempt=2)
        self.append('.github/CODEOWNERS')
        self.commit()
        self.record_tag(version)
        remote = self.git('ls-remote', 'origin', f'refs/tags/sdk-typescript-v{version}^{{}}')
        self.assertEqual(remote.split()[0], source)

    def test_original_run_can_repair_missing_tag_after_successful_upload(self):
        version = self.tag_fixture()
        self.record_tag(version)  # Already on registry; initial event cannot invent provenance.
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/*'), '')
        self.record_tag(version, attempt=2, evidence=self.upload_evidence(self.git('rev-parse', 'HEAD')))
        remote = self.git('ls-remote', 'origin', f'refs/tags/sdk-typescript-v{version}^{{}}')
        self.assertEqual(remote.split()[0], self.git('rev-parse', 'HEAD'))

    def test_later_rerun_cannot_backfill_tag_for_an_older_artifact(self):
        version = self.tag_fixture()
        self.append('.github/CODEOWNERS')
        self.commit()
        evidence = self.upload_evidence(self.git('rev-parse', 'HEAD'), 'skipped')
        self.record_tag(version, attempt=2, evidence=evidence, success=False)
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/*'), '')

    def test_failed_bump_run_cannot_claim_later_upload_and_actual_publisher_can_recover(self):
        version = self.tag_fixture()
        bump_source = self.git('rev-parse', 'HEAD')
        # A fails before upload; B's README changes the packaged metadata and B
        # uploads the same version, then its tag write fails. Neither has a tag.
        self.append('sdk/typescript/README.md', '\nPublished from B.\n')
        self.commit()
        publishing_source = self.git('rev-parse', 'HEAD')
        self.git('checkout', '--detach', bump_source)
        self.record_tag(version, attempt=2,
                        evidence=self.upload_evidence(bump_source, 'failure'), success=False)
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/*'), '')
        self.git('checkout', '--detach', publishing_source)
        self.record_tag(version, attempt=2, evidence=self.upload_evidence(publishing_source))
        remote = self.git('ls-remote', 'origin', f'refs/tags/sdk-typescript-v{version}^{{}}')
        self.assertEqual(remote.split()[0], publishing_source)
        self.assertNotEqual(remote.split()[0], bump_source)

    def test_recovery_rejects_mismatched_run_identity_and_unsuccessful_uploads(self):
        version = self.tag_fixture()
        sha = self.git('rev-parse', 'HEAD')
        path = '/repos/test/fountain/actions/runs/12345/attempts/1'
        for key, value in [('id', 999), ('run_attempt', 2), ('head_sha', '0' * 40),
                           ('head_branch', 'branch'), ('path', '.github/workflows/ci.yml'),
                           ('repository', {'full_name': 'wrong/repo'}), ('status', 'in_progress')]:
            with self.subTest(key=key):
                evidence = self.upload_evidence(sha)
                evidence[path][key] = value
                self.record_tag(version, attempt=2, evidence=evidence, success=False)
                self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/*'), '')
        for conclusion in ['skipped', 'failure', 'cancelled']:
            with self.subTest(conclusion=conclusion):
                self.record_tag(version, attempt=2, evidence=self.upload_evidence(sha, conclusion), success=False)
                self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/*'), '')

    def test_recovery_does_not_accept_a_different_or_incomplete_publisher_job(self):
        version = self.tag_fixture()
        sha = self.git('rev-parse', 'HEAD')
        path = '/repos/test/fountain/actions/runs/12345/attempts/1/jobs?per_page=100&page=1'
        for key, value in [('name', 'Different publisher'), ('run_id', 999),
                           ('head_sha', '0' * 40), ('status', 'in_progress')]:
            with self.subTest(key=key):
                evidence = self.upload_evidence(sha)
                evidence[path]['jobs'][0][key] = value
                self.record_tag(version, attempt=2, evidence=evidence, success=False)
                self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/*'), '')

    def test_expired_or_unavailable_upload_evidence_leaves_tag_absent(self):
        version = self.tag_fixture()
        path = '/repos/test/fountain/actions/runs/12345/attempts/1'
        for status in [403, 404, 503]:
            with self.subTest(status=status):
                self.record_tag(version, attempt=2, evidence={path: {'_status': status}}, success=False)
                self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/*'), '')

    def test_recovery_can_find_upload_in_an_older_attempt_and_paginated_jobs(self):
        version = self.tag_fixture()
        sha = self.git('rev-parse', 'HEAD')
        evidence = self.upload_evidence(sha, 'skipped', attempt=2)
        evidence.update(self.upload_evidence(sha, attempt=1))
        path = '/repos/test/fountain/actions/runs/12345/attempts/1/jobs?per_page=100&page='
        publishing_job = evidence[path + '1']['jobs'][0]
        evidence[path + '1'] = {'total_count': 101, 'jobs': [{'name': 'Other job'}] * 100}
        evidence[path + '2'] = {'total_count': 101, 'jobs': [publishing_job]}
        self.record_tag(version, attempt=3, evidence=evidence)
        remote = self.git('ls-remote', 'origin', f'refs/tags/sdk-typescript-v{version}^{{}}')
        self.assertEqual(remote.split()[0], sha)

    @unittest.skipUnless(shutil.which('node'), 'Node is needed for the native TypeScript gate')
    def test_native_typescript_gate_allows_docs_and_rejects_unversioned_source(self):
        self.append('sdk/typescript/README.md')
        self.commit()
        command = ['node', 'scripts/sdk-release.mjs', 'guard', self.base]
        self.assertEqual(subprocess.run(command, cwd=self.root, capture_output=True).returncode, 0)
        self.append('sdk/typescript/src/http.ts', '\n// A source edit\n')
        self.commit()
        self.assertNotEqual(subprocess.run(command, cwd=self.root, capture_output=True).returncode, 0)

if __name__ == '__main__':
    unittest.main()
