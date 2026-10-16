# ACP adapter bundles

The TSV files in `apps/fountain/priv/runtimes/acp/` remain the dependency
locks. An optional adjacent `.bundle.json` binds a transport artifact to the
TSV's SHA-256 and records SHA-512 for its gzip and zstd encodings. A new adapter
pin without this sidecar uses the existing package installer.

The `linux-x64-glibc-image` profile contains the selected package tree except
the native CLI packages replaced by an accepted image executable. The installer
uses it only after that executable passes the existing version check. Other
platforms and self-hosted Loam keep the full manifest path. Packages, executables,
and upstream notices are preserved; timestamps and ownership are normalized.

## Build and publish

The canonical publisher uses Ubuntu 24.04's Python 3.12, GNU tar, and zstd
1.5.5. Other zstd versions can produce different compressed bytes; build the
reviewed pins in that environment. Build into a fresh directory:

```bash
python3 scripts/acp-bundle.py claude \
  apps/fountain/priv/runtimes/acp/claude-agent-acp@0.81.2.tsv /tmp/claude-bundle
python3 -m unittest discover -s scripts/ci -p test_acp_bundle.py
```

The builder fetches only the manifest's registry tarballs, verifies each SHA-512
before unpacking, and refuses unsafe archive members or existing output files.
It never resolves dependencies or runs package scripts. Copy the generated JSON
to the matching `<pin>.bundle.json` beside the TSV and review it in the same PR.
The builder's output must reproduce that metadata exactly before publication.

After green CI and merge, dispatch `acp-bundles.yml` on `main` once for each
runtime. It creates `acp-bundle-<runtime>-<version>` release assets, without
changing GitHub's latest release or triggering a server deploy. Existing tags
and releases are never overwritten. If publication is interrupted, inspect the
tag and assets before deciding how to recover; do not replace an artifact that
a server may already have pinned. A corrected artifact needs a new immutable
identity and reviewed installer metadata.

Publish and verify the assets before cutting the server release. Measure the
actual public-origin installer through the broker, including the gzip path on
images without zstd; a private-origin microbenchmark does not establish
public-origin latency. The initial artifacts are available at the public
`acp-bundle-claude-0.81.2` and `acp-bundle-codex-2.2.2` release tags.
Record measurements, sample counts, errors, integrity checks, and
cleanup alongside the change.

## Install and fallback

Downloads use the ordinary sandbox proxy, with no retries, a two-second connect
limit and five-second total limit. The installer selects zstd when available,
otherwise gzip; it does not install a decompressor. It verifies the complete
compressed file against the embedded SHA-512 before extraction into staging.
Failure clears staging and runs the existing manifest, then npm fallback.
The accepted install still swaps its versioned directory and launcher atomically.

`bundle` timing includes the download, verification, extraction, and cleanup.
Its three child timings overlap that parent and must not be summed with it.
`bundle_hit` is 1 for success and 0 for an attempted bundle that fell back;
absence means the bundle was not attempted. Curl emits the same fixed numeric
timing/status markers as the package installer. Credentials and URLs are not
emitted. Cached installs retain their existing fast path.
