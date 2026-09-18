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

    def record_tag(self, version, published=False, attempt=1):
        env = dict(os.environ, GITHUB_ACTIONS='true', GITHUB_REF='refs/heads/main',
                   GITHUB_SHA=self.git('rev-parse', 'HEAD'), GITHUB_RUN_ATTEMPT=str(attempt))
        command = [shutil.which('python3'), 'scripts/sdk-release-tag.py', 'python', version]
        if published:
            command.append('--published-now')
        result = subprocess.run(command, cwd=self.root, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

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
        self.record_tag(version, attempt=2)
        remote = self.git('ls-remote', 'origin', f'refs/tags/sdk-python-v{version}^{{}}')
        self.assertEqual(remote.split()[0], self.git('rev-parse', 'HEAD'))

    def test_later_rerun_cannot_backfill_tag_for_an_older_artifact(self):
        version = self.tag_fixture()
        self.append('SDKs.md')
        self.commit()
        self.record_tag(version, attempt=2)
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/*'), '')

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
