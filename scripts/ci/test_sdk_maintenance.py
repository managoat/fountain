"""Mutation tests for the maintenance contract and real release-gate entry points."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


catalog = module('sdk_catalog', 'scripts/sdk-catalog.py')
release = module('sdk_release', 'scripts/sdk-release.py')
swiftgen = module('sdk_swift_generator', 'scripts/sdk-contract/generate-swift.py')


class SDKMaintenanceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Tiny fixture tree with the real metadata and hooks; no SDK builds or deps.
        config = catalog.load()
        paths = {'sdk/catalog.json', 'sdk/conformance/matrix.json', '.github/CODEOWNERS',
                 '.github/workflows/ci.yml', 'Package.swift', 'scripts/sdk-release.mjs',
                 'scripts/elixir-sdk-release.exs', 'scripts/sdk-release-tag.py', 'SDKs.md'}
        for language, sdk in config['sdks'].items():
            paths.update([sdk['manifest'], sdk['release_gate'], sdk['publish_workflow'], sdk['contract_check']])
            paths.update(f'sdk/{language}/{file}' for file in ['README.md', 'CHANGELOG.md', 'LICENSE'])
        paths.update(['sdk/typescript/src/http.ts', 'sdk/python/src/fountain/http.py',
                      'sdk/python/src/fountain/__init__.py', 'sdk/elixir/lib/fountain/http.ex',
                      'sdk/swift/Sources/Fountain/Fountain.swift', 'sdk/swift/Sources/FountainKit/Version.swift'])
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

    def test_current_catalog_is_derived_from_native_facts(self):
        self.assertEqual(catalog.validate(self.root), [])
        self.assertEqual(catalog.render(self.root), (self.root / 'SDKs.md').read_text())

    def test_unregistered_directory_is_rejected(self):
        (self.root / 'sdk/rust').mkdir()
        self.assertTrue(any('registered' in e for e in catalog.validate(self.root)))

    def test_owner_removal_is_rejected(self):
        self.change('.github/CODEOWNERS', lambda s: s.replace('/sdk/python/ @BinaryBourbon', ''))
        self.assertTrue(any('python: missing explicit CODEOWNERS' in e for e in catalog.validate(self.root)))

    def test_contract_check_removed_from_ci_is_rejected(self):
        self.change('.github/workflows/ci.yml', lambda s: s.replace('run: python scripts/verify_contract.py', 'run: echo removed'))
        self.assertTrue(any('python: CI job lacks' in e for e in catalog.validate(self.root)))

    def test_publisher_removed_from_workflow_is_rejected(self):
        self.change('.github/workflows/python-sdk-publish.yml', lambda s: s.replace('pypa/gh-action-pypi-publish@', 'not-a-publisher@'))
        self.assertTrue(any('python: missing publisher' in e for e in catalog.validate(self.root)))

    def test_version_identities_are_checked_even_without_a_bump(self):
        for language, path, old in [
            ('typescript', 'sdk/typescript/src/http.ts', 'fountain-sdk-js/'),
            ('python', 'sdk/python/src/fountain/http.py', 'fountain-sdk-python/'),
            ('elixir', 'sdk/elixir/lib/fountain/http.ex', 'fountain-sdk-elixir/'),
            ('swift', 'sdk/swift/Sources/FountainKit/Version.swift', ' = "'),
        ]:
            with self.subTest(language=language):
                source = (self.root / path).read_text()
                (self.root / path).write_text(source.replace(old, old + 'stale'))
                self.assertTrue(catalog.version_errors(language, self.root))
                (self.root / path).write_text(source)

    def test_readme_and_tests_do_not_require_python_or_swift_releases(self):
        for language in ['python', 'swift']:
            self.append(f'sdk/{language}/README.md')
        self.commit()
        for language in ['python', 'swift']:
            self.assertEqual(release.guard(language, self.base, self.root), [])

    def test_python_runtime_change_requires_release(self):
        self.change('sdk/python/pyproject.toml', lambda s: s.replace('>=3.9', '>=3.10'))
        self.commit()
        self.assertTrue(any('without a version bump' in e for e in release.guard('python', self.base, self.root)))

    def test_swift_sources_and_root_manifest_require_release(self):
        self.append('Package.swift', '\n// A manifest edit\n')
        self.commit()
        self.assertTrue(any('without a version bump' in e for e in release.guard('swift', self.base, self.root)))

    def bump_python(self):
        old = catalog.facts('python', self.root)[1]
        new = old.rsplit('.', 1)[0] + '.' + str(int(old.rsplit('.', 1)[1]) + 1)
        for file in ['sdk/python/pyproject.toml', 'sdk/python/src/fountain/http.py', 'sdk/python/src/fountain/__init__.py']:
            self.change(file, lambda s: s.replace(old, new))
        return new

    def test_version_bump_without_changelog_is_rejected(self):
        self.bump_python()
        self.commit()
        self.assertTrue(any('CHANGELOG' in e for e in release.guard('python', self.base, self.root)))

    def test_valid_python_release_does_not_require_swift_release(self):
        version = self.bump_python()
        self.append('sdk/python/CHANGELOG.md', f'\n## {version}\n\nA change.\n')
        self.commit()
        self.assertEqual(release.guard('python', self.base, self.root), [])
        self.assertEqual(release.guard('swift', self.base, self.root), [])

    def test_existing_registry_version_is_rejected_and_outage_fails_closed(self):
        version = self.bump_python()
        self.append('sdk/python/CHANGELOG.md', f'\n## {version}\n\nA change.\n')
        self.commit()
        with mock.patch.object(release.urllib.request, 'urlopen') as request:
            self.assertTrue(any('already exists' in e for e in release.guard('python', self.base, self.root, True)))
            request.side_effect = release.urllib.error.HTTPError('https://test.invalid', 503, 'outage', {}, None)
            with self.assertRaises(release.urllib.error.HTTPError):
                release.guard('python', self.base, self.root, True)
            request.side_effect = release.urllib.error.HTTPError('https://test.invalid', 404, 'not published', {}, None)
            self.assertEqual(release.guard('python', self.base, self.root, True), [])

    def tag_fixture(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        remote = Path(temp.name) / 'origin.git'
        subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
        self.git('remote', 'add', 'origin', str(remote))
        version = self.bump_python()
        self.commit()
        return version

    def upload_evidence(self, source, conclusion='success', attempt=1):
        path = f'/repos/test/fountain/actions/runs/12345/attempts/{attempt}'
        return {
            path: {'id': 12345, 'run_attempt': attempt,
                   'repository': {'full_name': 'test/fountain'}, 'head_sha': source,
                   'head_branch': 'main', 'path': '.github/workflows/python-sdk-publish.yml@main',
                   'event': 'push', 'status': 'completed'},
            f'{path}/jobs?per_page=100&page=1': {
                'total_count': 1, 'jobs': [{
                    'name': 'Publish to PyPI', 'run_id': 12345, 'head_sha': source,
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
        command = [shutil.which('python3'), '-c', harness, 'python', version]
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
        self.append('SDKs.md')
        self.commit()
        self.record_tag(version)
        remote = self.git('ls-remote', 'origin', f'refs/tags/sdk-python-v{version}^{{}}')
        self.assertEqual(remote.split()[0], source)

    def test_original_run_can_repair_missing_tag_after_successful_upload(self):
        version = self.tag_fixture()
        self.record_tag(version)  # Already on registry; initial event cannot invent provenance.
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/*'), '')
        self.record_tag(version, attempt=2, evidence=self.upload_evidence(self.git('rev-parse', 'HEAD')))
        remote = self.git('ls-remote', 'origin', f'refs/tags/sdk-python-v{version}^{{}}')
        self.assertEqual(remote.split()[0], self.git('rev-parse', 'HEAD'))

    def test_later_rerun_cannot_backfill_tag_for_an_older_artifact(self):
        version = self.tag_fixture()
        self.append('SDKs.md')
        self.commit()
        evidence = self.upload_evidence(self.git('rev-parse', 'HEAD'), 'skipped')
        self.record_tag(version, attempt=2, evidence=evidence, success=False)
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/*'), '')

    def test_failed_bump_run_cannot_claim_later_upload_and_actual_publisher_can_recover(self):
        version = self.tag_fixture()
        bump_source = self.git('rev-parse', 'HEAD')
        # A fails before upload; B's README changes the packaged metadata and B
        # uploads the same version, then its tag write fails. Neither has a tag.
        self.append('sdk/python/README.md', '\nPublished from B.\n')
        self.commit()
        publishing_source = self.git('rev-parse', 'HEAD')
        self.git('checkout', '--detach', bump_source)
        self.record_tag(version, attempt=2,
                        evidence=self.upload_evidence(bump_source, 'failure'), success=False)
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/*'), '')
        self.git('checkout', '--detach', publishing_source)
        self.record_tag(version, attempt=2, evidence=self.upload_evidence(publishing_source))
        remote = self.git('ls-remote', 'origin', f'refs/tags/sdk-python-v{version}^{{}}')
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
        remote = self.git('ls-remote', 'origin', f'refs/tags/sdk-python-v{version}^{{}}')
        self.assertEqual(remote.split()[0], sha)

    def test_swift_baseline_follows_sdk_releases_and_ignores_later_server_tags(self):
        self.git('tag', 'v0.19.0')
        self.append('SDKs.md')
        self.commit()
        self.git('tag', 'v0.99.0')
        try:
            with mock.patch.object(swiftgen, 'ROOT', self.root):
                swiftgen.released_tag.cache_clear()
                self.assertEqual(swiftgen.released_tag(), 'v0.19.0')
                self.append('SDKs.md')
                self.commit()
                self.git('tag', 'sdk-swift-v0.20.0')
                self.append('SDKs.md')
                self.commit()
                self.git('tag', 'v1.0.0')
                swiftgen.released_tag.cache_clear()
                self.assertEqual(swiftgen.released_tag(), 'sdk-swift-v0.20.0')
        finally:
            swiftgen.released_tag.cache_clear()

    @unittest.skipUnless(shutil.which('node'), 'Node is needed for the native TypeScript gate')
    def test_native_typescript_gate_allows_docs_and_rejects_unversioned_source(self):
        self.append('sdk/typescript/README.md')
        self.commit()
        command = ['node', 'scripts/sdk-release.mjs', 'guard', self.base]
        self.assertEqual(subprocess.run(command, cwd=self.root, capture_output=True).returncode, 0)
        self.append('sdk/typescript/src/http.ts', '\n// A source edit\n')
        self.commit()
        self.assertNotEqual(subprocess.run(command, cwd=self.root, capture_output=True).returncode, 0)

    @unittest.skipUnless(shutil.which('elixir'), 'Elixir is needed for the native Elixir gate')
    def test_native_elixir_gate_allows_docs_and_rejects_unversioned_source(self):
        self.append('sdk/elixir/README.md')
        self.commit()
        command = ['elixir', 'scripts/elixir-sdk-release.exs', 'guard', self.base]
        self.assertEqual(subprocess.run(command, cwd=self.root, capture_output=True).returncode, 0)
        self.append('sdk/elixir/lib/fountain/http.ex')
        self.commit()
        self.assertNotEqual(subprocess.run(command, cwd=self.root, capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
