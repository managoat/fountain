# Maintaining an SDK

[SDKs.md](../SDKs.md) is the checked catalog. `sdk/catalog.json` records ownership,
install coordinates, stability and CI hooks; each package's own manifest owns its
version and runtime requirement. `python3 scripts/sdk-catalog.py --write` refreshes
the catalog. CI rejects stale output, unregistered SDK directories, missing owners,
missing release/contract hooks and version identities that disagree with manifests.
The tool needs Python 3.11 or newer.

TypeScript is the one maintained SDK. The Python, Elixir and Swift SDKs were
removed on 2026-10-12 ([ADR 0059](../decisions/0059-independent-sdk-maintenance.md));
their published releases on PyPI, Hex and the `sdk-swift-v*` tags stay where they
are, unmaintained. Their release tags are history: never move or delete them.

## Ownership and support

`@BinaryBourbon` owns the TypeScript SDK and is the fallback for shared SDK
tooling. Delegate ownership by changing both `sdk/catalog.json` and
`.github/CODEOWNERS`. Owners must have repository write access. Register a
real GitHub user or team, not a placeholder. The catalog's conformance counts are
computed from `sdk/conformance/matrix.json`; supported scenarios still run in the
SDK's CI job, and a skip needs its existing reason and tracking issue.

## Releasing a change

A shipped source, runtime dependency or public packaging change needs a new
version and an entry in the SDK's changelog. Tests, examples and documentation
alone need neither. README corrections appear on GitHub immediately and enter the
registry artifact with its next release. The SDK versions independently of the
server; changing the contract does not demand a no-op release.

1. Bump the version in `sdk/typescript/package.json` and its lockfile.
2. Update `USER_AGENT` in `sdk/typescript/src/http.ts` to match.
3. Add the versioned SDK changelog entry and run the SDK's checks from
   [CI maintenance](../scripts/ci/README.md#sdk-jobs).
4. Run `python3 scripts/sdk-catalog.py --write`, commit, and open a PR. The release
   gate runs on the PR; the normal review and merge queue still apply.

Merging the bump publishes the SDK from CI. The deliberate existing exception
is `release:skip-sdk` (legacy spelling `sdk-no-release`): explain in the PR why a
shipped change is being held for a later release. This skips the version-bump gate,
not version-identity checks or SDK tests. It does not prevent publishing a new
version, so do not bump a version you intend to hold.

Every new tag is `sdk-typescript-v<version>`. Historical `sdk-v*`,
`sdk-python-v*`, `sdk-elixir-v*`, `elixir-sdk-v*`, `sdk-swift-v*` and `v*` tags
remain unchanged. Existing registry versions are not
republished or retroactively relabeled just because the convention changed.

## Publishing and credentials

The publisher runs only on `main` and serializes with `queue: max`. The queue
preserves pending versions instead of canceling intermediate releases. npm trusts
the publisher through GitHub OIDC; keep the workflow filename, since it is part of
the registry trust configuration. Local release commands are not the supported
publication path.

The publisher checks the exact version first and skip an already published
version. After a successful upload they record its language-qualified source tag.
If uploading succeeds but recording the tag fails, rerun the workflow run that
actually uploaded it. This may be a later docs/source commit if the version-bump
run failed before upload. After the registry check skips upload, recovery reads
that run's earlier attempts through the Actions API, verifies the repository,
workflow, source SHA and completed publisher job, and requires a successful
`Publish` step. The job token has `actions: read` for this check.

A version bump or retry count alone never proves artifact provenance. A skipped
or failed upload, unavailable API or expired run history leaves the tag absent
and fails recovery; investigate the registry provenance instead of guessing. A
fresh dispatch does not backfill older artifacts. Never move a published tag or
delete a registry version to make a retry work. A missing tag is a release
incident; the registry remains authoritative for availability.

## Adding an SDK

Add its own manifest/version, Apache-2.0 license, README, changelog and actual
registry/install coordinate. Register its owner and fallback, stability,
conformance adapters, contract-check file, CI job and commands, PR release gate
and main publisher in `sdk/catalog.json`. Add the CODEOWNERS entry and a native
manifest reader/version-identity check in `scripts/sdk-catalog.py`. Do not migrate
other SDK manifests to a shared build system.

Wire the contract and conformance checks into CI, implement an idempotent CI
publisher and source/version/changelog gate, add relevant coverage to the shared
matrix, and regenerate the catalog. Extend the release-policy regression tests
when introducing a new manifest format or release rule.
