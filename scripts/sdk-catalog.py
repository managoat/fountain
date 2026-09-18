#!/usr/bin/env python3
"""Validate SDK ownership/support hooks and render SDKs.md. Python 3.11+, stdlib only."""
import argparse
import json
from pathlib import Path
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def capture(pattern, text):
    match = re.search(pattern, text, re.M)
    if not match:
        raise ValueError(f"missing manifest value: {pattern}")
    return match[1]


def facts(language, root=ROOT):
    directory = root / 'sdk' / language
    if language == 'typescript':
        pkg = json.loads((directory / 'package.json').read_text())
        return pkg['name'], pkg['version'], f"Node {pkg['engines']['node']}; browsers with fetch"
    if language == 'python':
        pkg = tomllib.loads((directory / 'pyproject.toml').read_text())['project']
        return pkg['name'], pkg['version'], f"Python {pkg['requires-python']}"
    if language == 'elixir':
        pkg = (directory / 'mix.exs').read_text()
        minimum = capture(r'elixir: "([^"]+)"', pkg)
        return (capture(r'app: :(\w+)', pkg), capture(r'@version "([^"]+)"', pkg),
                f"Elixir {minimum} / OTP 26+")
    if language == 'swift':
        pkg = json.loads((directory / 'version.json').read_text())
        tools = capture(r'swift-tools-version: ([\d.]+)', (root / 'Package.swift').read_text())
        return 'Fountain + FountainKit', pkg['version'], f'Swift {tools}+; macOS 12, iOS/tvOS 15, watchOS 8, Linux'
    raise ValueError(f'{language}: add a native manifest reader to scripts/sdk-catalog.py')


def version_errors(language, root=ROOT):
    _, version, _ = facts(language, root)
    expected = {
        'typescript': [('sdk/typescript/src/http.ts', r'USER_AGENT = "([^"]+)"', f'fountain-sdk-js/{version}')],
        'python': [('sdk/python/src/fountain/http.py', r'USER_AGENT = "([^"]+)"', f'fountain-sdk-python/{version}'),
                   ('sdk/python/src/fountain/__init__.py', r'__version__ = "([^"]+)"', version)],
        'elixir': [('sdk/elixir/lib/fountain/http.ex', r'@user_agent "([^"]+)"', f'fountain-sdk-elixir/{version}')],
        'swift': [('sdk/swift/Sources/Fountain/Fountain.swift', r'public let fountainSDKVersion = "([^"]+)"', version),
                  ('sdk/swift/Sources/FountainKit/Version.swift', r'public let fountainKitVersion = "([^"]+)"', version)],
    }
    errors = []
    for path, pattern, value in expected[language]:
        if capture(pattern, (root / path).read_text()) != value:
            errors.append(f'{path}: identifying version must be {value}')
    return errors


def load(root=ROOT):
    return json.loads((root / 'sdk/catalog.json').read_text())


def validate(root=ROOT):
    catalog = load(root)
    errors = []
    sdks = catalog['sdks']
    directories = {p.name for p in (root / 'sdk').iterdir() if p.is_dir() and not p.name.startswith('.')}
    if directories != set(sdks) | {'contract', 'conformance'}:
        errors.append('Every SDK directory must be registered in sdk/catalog.json (only contract and conformance are infrastructure)')
    owners = (root / '.github/CODEOWNERS').read_text().splitlines()
    if f"/sdk/ {catalog['fallback_owner']}" not in owners:
        errors.append('CODEOWNERS must name the catalog fallback for /sdk/')
    matrix = json.loads((root / 'sdk/conformance/matrix.json').read_text())
    claimed = []
    ci = (root / '.github/workflows/ci.yml').read_text()
    for language, sdk in sdks.items():
        try:
            name, version, runtime = facts(language, root)
            if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[\w.-]+)?', version):
                errors.append(f'{language}: invalid version {version}')
            if not sdk['stability'] or not sdk['install'] or not sdk['registry']:
                errors.append(f'{language}: stability, install and registry are required')
            if f"/sdk/{language}/ {sdk['owner']}" not in owners:
                errors.append(f'{language}: missing explicit CODEOWNERS entry')
            for path in (sdk['manifest'], f'sdk/{language}/README.md', f'sdk/{language}/CHANGELOG.md',
                         sdk['release_gate'], sdk['publish_workflow'], sdk['contract_check']):
                if not (root / path).is_file():
                    errors.append(f'{language}: missing required file {path}')
            license_text = (root / f'sdk/{language}/LICENSE').read_text()
            if 'Apache License' not in license_text or 'Version 2.0' not in license_text:
                errors.append(f'{language}: expected Apache-2.0 license')
            job_marker = f"\n  {sdk['ci_job']}:\n"
            if job_marker not in ci:
                errors.append(f'{language}: CI job {sdk["ci_job"]} is missing')
            else:
                job = re.split(r'\n  [\w-]+:\n', ci.split(job_marker, 1)[1], maxsplit=1)[0]
                for hook in sdk['ci_hooks']:
                    if hook not in job:
                        errors.append(f'{language}: CI job lacks {hook}')
            gate = (root / sdk['release_gate']).read_text()
            publisher = (root / sdk['publish_workflow']).read_text()
            for text, hook, kind in ((gate, sdk['guard_command'], 'release guard'),
                                     (publisher, sdk['publish_command'], 'publisher')):
                if hook not in text:
                    errors.append(f'{language}: missing {kind}: {hook}')
            if 'pull_request:' not in gate or f'"sdk/{language}/**"' not in gate:
                errors.append(f'{language}: release gate does not watch SDK PRs')
            if language != 'swift' and f'scripts/sdk-release-tag.py {language}' not in publisher:
                errors.append(f'{language}: missing idempotent release-tag hook')
            if 'branches: [main]' not in publisher or 'concurrency:' not in publisher:
                errors.append(f'{language}: publishing must serialize main pushes')
            errors.extend(version_errors(language, root))
            for client in sdk['conformance']:
                claimed.append(client)
                if client not in matrix['sdks'] or any(client not in v for v in matrix['scenarios'].values()):
                    errors.append(f'{language}: incomplete conformance matrix for {client}')
        except (KeyError, ValueError, OSError) as error:
            errors.append(f'{language}: {error}')
    if sorted(claimed) != sorted(matrix['sdks']):
        errors.append('Catalog clients must cover each conformance adapter exactly once')
    return errors


def render(root=ROOT):
    catalog = load(root)
    matrix = json.loads((root / 'sdk/conformance/matrix.json').read_text())
    lines = ['# Fountain SDKs', '',
             '<!-- Generated by python3 scripts/sdk-catalog.py --write. Edit sdk/catalog.json or the native manifests. -->', '',
             'Versions below describe this checkout; registry links show what is published. SDKs release independently.', '',
             '| Language | Package / install | Version | Minimum runtime | Stability | Conformance |',
             '|---|---|---|---|---|---|']
    for language, sdk in catalog['sdks'].items():
        _, version, runtime = facts(language, root)
        display = {'typescript': 'TypeScript'}.get(language, language.title())
        coverage = []
        for client in sdk['conformance']:
            yes = sum(v[client] == 'yes' for v in matrix['scenarios'].values())
            coverage.append(f'{client}: {yes}/{len(matrix["scenarios"])}')
        lines.append(f'| [{display}](sdk/{language}/README.md) | [{sdk["install"].replace("{version}", version)}]({sdk["registry"]}) | {version} | {runtime} | {sdk["stability"]} | {"; ".join(coverage)} |')
    lines += ['', 'Conformance counts are declared coverage of the [shared scenarios](sdk/conformance/README.md),',
              'not a claim that every server feature exists in every client. [The matrix](sdk/conformance/matrix.json)',
              'records unsupported scenarios and their tracking issues. CI runs every registered adapter.', '',
              '## Maintenance', '',
              f'Fallback owner: {catalog["fallback_owner"]}. Explicit per-language ownership is enforced in',
              '[CODEOWNERS](.github/CODEOWNERS); it may be delegated without changing package versions.', '',
              '| SDK | Owner | Version manifest | Release gate | Publisher | New tags |',
              '|---|---|---|---|---|---|']
    for language, sdk in catalog['sdks'].items():
        lines.append(f'| {language} | {sdk["owner"]} | [{sdk["manifest"]}]({sdk["manifest"]}) | [gate]({sdk["release_gate"]}) | [publish]({sdk["publish_workflow"]}) | `sdk-{language}-v<version>` |')
    lines += ['', 'See [SDK maintenance](contributing/sdk-maintenance.md) for version bumps, authentication,',
              'tag recovery, Swift installation, and the checklist for adding an SDK.', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    errors = validate()
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    rendered = render()
    if args.write:
        (ROOT / 'SDKs.md').write_text(rendered)
    elif not (ROOT / 'SDKs.md').exists() or (ROOT / 'SDKs.md').read_text() != rendered:
        print('SDKs.md is stale: run python3 scripts/sdk-catalog.py --write', file=sys.stderr)
        return 1
    print('SDK catalog, ownership, version identities and CI hooks agree.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
