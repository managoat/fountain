#!/usr/bin/env python3
"""Python and Swift SDK release gates; native manifests remain the version authority."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('catalog', ROOT / 'scripts/sdk-catalog.py')
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


def git(*args, root=ROOT):
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()


def previous(base, path, root=ROOT):
    result = subprocess.run(['git', 'show', f'{base}:{path}'], cwd=root, text=True, capture_output=True)
    if result.returncode:
        # A missing file is allowed for the first independent Swift release.
        git('rev-parse', '--verify', f'{base}^{{commit}}', root=root)
        return None
    return result.stdout


def consumer_python(source):
    manifest = tomllib.loads(source)
    project = manifest['project']
    keys = ('name', 'version', 'requires-python', 'license', 'dependencies',
            'optional-dependencies', 'scripts', 'gui-scripts', 'entry-points', 'dynamic')
    return ({k: project.get(k) for k in keys}, manifest.get('build-system'),
            manifest.get('tool', {}).get('setuptools'))


def guard(language, base_ref, root=ROOT, check_registry=False):
    base = git('merge-base', base_ref, 'HEAD', root=root)
    changed = git('diff', '--no-renames', '--name-only', base, 'HEAD', root=root).splitlines()
    _, version, _ = catalog.facts(language, root)
    errors = catalog.version_errors(language, root)
    if language == 'python':
        manifest = 'sdk/python/pyproject.toml'
        old_source = previous(base, manifest, root)
        old = tomllib.loads(old_source)['project']['version'] if old_source else None
        paths = [p for p in changed if p.startswith('sdk/python/src/') or p == 'sdk/python/LICENSE']
        if manifest in changed and (not old_source or consumer_python(old_source) != consumer_python((root / manifest).read_text())):
            paths.append(manifest)
        heading = f'## {version}'
    else:
        manifest = 'sdk/swift/version.json'
        old_source = previous(base, manifest, root)
        if old_source:
            old = json.loads(old_source)['version']
        else:
            old = catalog.capture(r'public let fountainSDKVersion = "([^"]+)"',
                                  previous(base, 'sdk/swift/Sources/Fountain/Fountain.swift', root) or '')
        paths = [p for p in changed if p.startswith('sdk/swift/Sources/') or p in
                 (manifest, 'Package.swift', 'sdk/swift/LICENSE')]
        heading = f'## [{version}]'
    if paths and version == old:
        errors.append(f'{language}: shipped files changed without a version bump: {", ".join(paths)}')
    if version != old:
        # These two packages currently publish stable numeric versions only.
        if not re.fullmatch(r'\d+\.\d+\.\d+', version):
            errors.append(f'{language}: use a numeric major.minor.patch version')
        elif old and tuple(map(int, version.split('.'))) <= tuple(map(int, old.split('.'))):
            errors.append(f'{language}: version {version} must be newer than {old}')
        changelog = f'sdk/{language}/CHANGELOG.md'
        if changelog not in changed or not re.search(r'^' + re.escape(heading) + r'(?:\s+-.*)?$', (root / changelog).read_text(), re.M):
            errors.append(f'{language}: change CHANGELOG.md and add {heading}')
        if check_registry and not errors:
            if language == 'python':
                url = f'https://pypi.org/pypi/fountain-agent-sdk/{version}/json'
                try:
                    with urllib.request.urlopen(url, timeout=30):
                        errors.append(f'fountain-agent-sdk {version} already exists on PyPI')
                except urllib.error.HTTPError as error:
                    if error.code != 404:
                        raise
            elif git('ls-remote', '--tags', 'origin', f'refs/tags/sdk-swift-v{version}', root=root):
                errors.append(f'sdk-swift-v{version} already exists')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('language', choices=['python', 'swift'])
    parser.add_argument('base')
    parser.add_argument('--check-registry', action='store_true')
    args = parser.parse_args()
    errors = guard(args.language, args.base, check_registry=args.check_registry)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'{args.language}: version, changelog and identifying versions pass.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
