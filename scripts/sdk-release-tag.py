#!/usr/bin/env python3
"""Record a successful registry release; retry an interrupted tag write at its original commit."""
import argparse
import json
import os
import re
import subprocess

MANIFESTS = {
    'typescript': 'sdk/typescript/package.json',
    'python': 'sdk/python/pyproject.toml',
    'elixir': 'sdk/elixir/mix.exs',
}


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def version_at(language, revision):
    source = git('show', f'{revision}:{MANIFESTS[language]}')
    if language == 'typescript':
        return json.loads(source)['version']
    pattern = r'^version = "([^"]+)"' if language == 'python' else r'^\s*@version "([^"]+)"'
    return re.search(pattern, source, re.M)[1]


def record(language, version, published_now):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise ValueError('SDK release tags are written only by main-branch CI')
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
        raise ValueError('invalid package version')
    sha = os.environ['GITHUB_SHA']
    if git('rev-parse', 'HEAD') != sha or version_at(language, sha) != version:
        raise ValueError('checkout and release version must match the workflow source commit')
    tag = f'sdk-{language}-v{version}'
    existing = git('ls-remote', '--tags', 'origin', f'refs/tags/{tag}', f'refs/tags/{tag}^{{}}')
    if existing:
        target = existing.splitlines()[-1].split()[0]  # peeled commit for annotated tags
        if published_now and target != sha:
            raise ValueError(f'{tag} already points elsewhere; never move a release tag')
        print(f'{tag} already recorded; unchanged')
        return
    if not published_now:
        # Registry state cannot establish which later checkout produced an
        # artifact. Only a rerun of the original version-bump event can repair
        # its interrupted tag write, never a docs push or a fresh dispatch.
        if int(os.environ.get('GITHUB_RUN_ATTEMPT', '1')) <= 1:
            print(f'Existing registry version has no new-convention tag; no backfill: {tag}')
            return
        if version_at(language, f'{sha}^') == version:
            print('This event did not introduce the version; rerun its original publish run to repair the tag')
            return
    git('config', 'user.name', 'github-actions[bot]')
    git('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com')
    # A failed push may have left the annotated tag locally in a self-hosted
    # runner. Verify it before reusing it; never force it or the remote ref.
    local = subprocess.run(['git', 'rev-parse', '--verify', f'refs/tags/{tag}^{{commit}}'], text=True, capture_output=True)
    if local.returncode == 0:
        if local.stdout.strip() != sha:
            raise ValueError(f'local {tag} points elsewhere')
    else:
        git('tag', '-a', tag, '-m', f'Fountain {language} SDK {version}', sha)
    subprocess.run(['git', 'push', 'origin', f'refs/tags/{tag}'], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('language', choices=list(MANIFESTS))
    parser.add_argument('version')
    parser.add_argument('--published-now', action='store_true')
    args = parser.parse_args()
    record(args.language, args.version, args.published_now)
