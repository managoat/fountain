#!/usr/bin/env python3
"""Resolve both Swift products from a Git revision, outside the source checkout."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def smoke(repository, revision, version):
    # JSON strings are valid Swift string literals for these URL/ref inputs.
    # Reject interpolation explicitly rather than letting a ref become Swift code.
    if any('\\' in value or '\n' in value for value in (repository, revision, version)):
        raise ValueError('repository, revision and version must be single-line literal values')
    identity = repository.rstrip('/').rsplit('/', 1)[-1].removesuffix('.git').lower()
    with tempfile.TemporaryDirectory(prefix='fountain-swift-consumer-') as temp:
        root = Path(temp)
        (root / 'Sources/Smoke').mkdir(parents=True)
        (root / 'Package.swift').write_text(f'''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
  name: "Smoke",
  platforms: [.macOS(.v12)],
  dependencies: [.package(url: {json.dumps(repository)}, revision: {json.dumps(revision)})],
  targets: [.executableTarget(name: "Smoke", dependencies: [
    .product(name: "Fountain", package: {json.dumps(identity)}),
    .product(name: "FountainKit", package: {json.dumps(identity)})
  ])]
)
''')
        (root / 'Sources/Smoke/main.swift').write_text('import Fountain\nimport FountainKit\nprint("\\(fountainSDKVersion) \\(fountainKitVersion)")\n')
        subprocess.run(['swift', 'package', 'resolve'], cwd=root, check=True)
        result = subprocess.check_output(['swift', 'run', 'Smoke'], cwd=root, text=True).strip()
        if result != f'{version} {version}':
            raise ValueError(f'consumer reports {result!r}, expected both products at {version}')
        print(f'Clean Swift consumer resolved {revision}: {result}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    smoke(args.repository, args.revision, args.version)
