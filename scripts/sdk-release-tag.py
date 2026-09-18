#!/usr/bin/env python3
"""Record a successful registry release; retry an interrupted tag write at its original commit."""
import argparse
import json
import os
import re
import subprocess
import urllib.request

PUBLISHERS = {
    'typescript': ('.github/workflows/sdk-publish.yml', 'Publish to npm'),
    'python': ('.github/workflows/python-sdk-publish.yml', 'Publish to PyPI'),
    'elixir': ('.github/workflows/elixir-sdk-publish.yml', 'Publish to Hex'),
}

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


def api(path):
    request = urllib.request.Request('https://api.github.com' + path, headers={
        'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def uploaded_by_this_run(language, sha, current_attempt):
    """A version bump is not provenance; read the actual upload's completed step."""
    repository = os.environ['GITHUB_REPOSITORY']
    run_id = int(os.environ['GITHUB_RUN_ID'])
    workflow, job_name = PUBLISHERS[language]
    for attempt in range(current_attempt - 1, 0, -1):
        path = f'/repos/{repository}/actions/runs/{run_id}/attempts/{attempt}'
        run = api(path)
        if (run['id'] != run_id or run['run_attempt'] != attempt
                or run['repository']['full_name'] != repository
                or run['head_sha'] != sha or run['head_branch'] != 'main'
                or run['path'].split('@', 1)[0] != workflow
                or run['event'] not in ('push', 'workflow_dispatch')
                or run['status'] != 'completed'):
            raise ValueError('Upload evidence does not match this completed publishing run; tag left absent')
        page, seen = 1, 0
        while True:
            result = api(f'{path}/jobs?per_page=100&page={page}')
            for job in result['jobs']:
                if (job['name'] == job_name and job['run_id'] == run_id
                        and job['head_sha'] == sha and job['status'] == 'completed'
                        and any(step['name'] == 'Publish' and step['status'] == 'completed'
                                and step['conclusion'] == 'success' for step in job['steps'])):
                    print(f'Upload verified: run {run_id}, attempt {attempt}, source {sha}')
                    return True
            seen += len(result['jobs'])
            if seen >= result['total_count']:
                break
            if not result['jobs']:
                raise ValueError('Incomplete publishing-job evidence; tag left absent')
            page += 1
    return False


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
        # A later docs/source commit can upload a version whose bump run
        # failed. Only a successful Publish step from this same source/run is
        # evidence for recovery, including when this commit did not bump it.
        attempt = int(os.environ.get('GITHUB_RUN_ATTEMPT', '1'))
        if attempt <= 1:
            print(f'Existing registry version has no new-convention tag; no backfill: {tag}')
            return
        if not uploaded_by_this_run(language, sha, attempt):
            raise ValueError(
                f'No successful Publish step for this run/source; {tag} left absent. '
                'Rerun the actual publishing run or investigate registry provenance.')
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
