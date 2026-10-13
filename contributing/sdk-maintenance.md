# Maintaining an SDK

TypeScript (`@managoat/fountain-sdk`, `npm install @managoat/fountain-sdk`) is the
one maintained SDK. `sdk/typescript/package.json` owns its version and runtime
requirement. The Python, Elixir and Swift SDKs were
removed on 2026-10-12 ([ADR 0059](../decisions/0059-independent-sdk-maintenance.md));
their published releases on PyPI, Hex and the `sdk-swift-v*` tags stay where they
are, unmaintained. Their release tags are history: never move or delete them.

## Ownership and support

`@BinaryBourbon` owns the TypeScript SDK and is the fallback for shared SDK
tooling. Delegate ownership in `.github/CODEOWNERS`. Owners must have repository
write access. Register a real GitHub user or team, not a placeholder.

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
4. Commit and open a PR. The release gate runs on the PR; the normal review and
   merge queue still apply.

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

There is one SDK, and no machinery for registering another: the catalog and
the language-neutral conformance matrix were removed on 2026-10-13 (ADR 0059).
A new client would bring its own manifest, Apache-2.0 license, README,
changelog, contract manifest under `sdk/contract/manifests/`, a
`check-propagation.py` probe, a CI job, and an idempotent publisher and release
gate modelled on TypeScript's. Its wire behaviour can be checked against the
scenarios in `sdk/typescript/test/scenarios/`.
