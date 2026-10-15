# Maintaining the SDK

The SDK is TypeScript, `@managoat/sdk`, in `sdk/typescript/`. Its
`package.json` owns its version and runtime requirement. It is the only SDK;
[ADR 0059](../decisions/0059-independent-sdk-maintenance.md) records the ones
that were removed. `.github/CODEOWNERS` names its owner.

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
4. Commit and open a PR. The release gate (`sdk-release-gate.yml`) runs on the
   PR; it merges like any other PR once CI is green.

Merging the bump publishes the SDK from CI. To hold a shipped change for a
later release, add the `release:skip-sdk` label (legacy spelling
`sdk-no-release`) and say why in the PR. The label skips only the version-bump
gate, not the SDK tests. It does not stop a bumped version from publishing, so
do not bump a version you intend to hold.

Each release is tagged `sdk-typescript-v<version>`. Never move or delete a
published tag, older spellings included.

## Publishing and credentials

`sdk-publish.yml` is the only publisher. It runs on `main` and serializes with
`queue: max`, so pending versions are kept instead of an intermediate release
being canceled. npm trusts it through GitHub OIDC (trusted publishing): keep
the workflow filename, since it is part of the registry's trust configuration.
Nothing is published from a laptop.

The publisher checks the exact version first and skips one already published.
After a successful upload, `scripts/sdk-release-tag.py` records the tag. If
the upload succeeded but recording the tag failed, rerun the workflow run that
uploaded it. After the registry check skips an upload, recovery reads that
run's earlier attempts through the Actions API, verifies the repository,
workflow, source SHA and completed publisher job, and requires a successful
`Publish` step; the job token has `actions: read` for this.

A version bump or retry count alone never proves provenance. A skipped or
failed upload, an unavailable API or expired run history leaves the tag absent
and fails recovery: investigate the registry instead of guessing. Never move a
published tag or delete a registry version to make a retry work. A missing tag
is a release incident; the registry remains authoritative for availability.
