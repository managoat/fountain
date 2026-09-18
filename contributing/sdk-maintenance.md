# Maintaining an SDK

[SDKs.md](../SDKs.md) is the checked catalog. `sdk/catalog.json` records ownership,
install coordinates, stability and CI hooks; each package's own manifest owns its
version and runtime requirement. `python3 scripts/sdk-catalog.py --write` refreshes
the catalog. CI rejects stale output, unregistered SDK directories, missing owners,
missing release/contract hooks and version identities that disagree with manifests.
The tool needs Python 3.11 or newer; this is a contributor-tool requirement, not a
change to the Python SDK's supported runtime.

## Ownership and support

`@BinaryBourbon` owns all four clients initially and is the fallback for shared
SDK tooling. Delegate individual languages by changing both `sdk/catalog.json`
and `.github/CODEOWNERS`. Owners must have repository write access. Register a
real GitHub user or team, not a placeholder. The catalog's conformance counts are
computed from `sdk/conformance/matrix.json`; supported scenarios still run in each
SDK's CI job, and a skip needs its existing reason and tracking issue.

## Releasing a change

A shipped source, runtime dependency or public packaging change needs a new
version and an entry in that SDK's changelog. Tests, examples and documentation
alone need neither. README corrections appear on GitHub immediately and enter the
registry artifact with its next release. Versions are independent; changing the
contract or another SDK does not demand a no-op release.

1. Bump only the affected package's version: `package.json` and its lockfile for
   TypeScript, `pyproject.toml` for Python, `@version` in Elixir's `mix.exs`, or
   `sdk/swift/version.json` for Swift.
2. Update its identifying constants. TypeScript's `USER_AGENT`, Python's
   `USER_AGENT` and `__version__`, Elixir's `@user_agent`, and Swift's
   `fountainSDKVersion` / `fountainKitVersion` must match their own manifest.
3. Add the versioned SDK changelog entry and run that SDK's checks from
   [CI maintenance](../scripts/ci/README.md#sdk-jobs).
4. Run `python3 scripts/sdk-catalog.py --write`, commit, and open a PR. The release
   gate runs on the PR; the normal review and merge queue still apply.

Merging the bump publishes that SDK from CI. The deliberate existing exception
is `release:skip-sdk` (legacy spelling `sdk-no-release`): explain in the PR why a
shipped change is being held for a later release. This skips the version-bump gate,
not version-identity checks or SDK tests. It does not prevent publishing a new
version, so do not bump a version you intend to hold.

Every new tag is `sdk-<language>-v<version>`. Historical `sdk-v*`,
`elixir-sdk-v*` and `v*` tags remain unchanged. Existing registry versions are not
republished or retroactively relabeled just because the convention changed.

## Publishing and credentials

Publishers run only on `main` and serialize per language with `queue: max`.
The queue preserves pending versions instead of canceling intermediate releases.
TypeScript and Python use registry trusted publishing with GitHub OIDC; keep the
existing workflow filenames and Python's `pypi` environment, since those are part
of the registry trust configuration. Hex uses the existing package-scoped
`HEX_API_KEY`; its publishing interface currently uses API keys. Swift publishes
Git source using the job's short-lived `GITHUB_TOKEN`. Local release commands are
not the supported publication path.

Registry publishers check the exact version first and skip an already published
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

Swift publication itself is the immutable tag. A retry that finds the tag skips
publication and reruns a remote consumer against that same tag, so it also repairs
an interrupted verification without moving the release.

## Independent Swift releases

Fountain and FountainKit are two products of one Swift package and share one
version. Starting at 0.20.0 they release independently of the server:

```swift
.package(url: "https://github.com/managoat/fountain.git",
         revision: "sdk-swift-v0.20.0")
```

Pinning the tag's full commit SHA also works. Commit `Package.resolved` and update
the revision deliberately. SwiftPM's version-range resolver does not recognize
language-prefixed tags. A published package using version-based dependencies also
cannot transitively depend on a revision-based package; that consumer must keep
using the server-tag snapshot route or use revision-based dependencies itself.
See [SwiftPM's dependency requirements](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)
and [prefixed tag support](https://github.com/swiftlang/swift-package-manager/issues/5780).

Existing `from:` and `exact:` dependencies on `v*` tags still resolve server
snapshots. Their SDK's reported version may now differ from the server's version;
this is intentional. Server releases no longer rewrite either Swift version
constant. The server release smoke test verifies the snapshot's own SDK manifest.
The Swift publisher tests both products, builds a clean consumer before tagging,
and resolves both products remotely after tagging.

The wire-model compatibility baseline follows the latest reachable `sdk-swift-v*`
tag. Before the first independent release it stays at `v0.19.0`, the final coupled
baseline, so subsequent server snapshots cannot advance it.

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
