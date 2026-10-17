# ACP adapter bundles

A pinned ACP adapter reaches a sandbox only as its verified transport bundle
([ADR 0092](../decisions/0092-verified-acp-transport-bundles.md)). The TSV
files in `apps/fountain/priv/runtimes/acp/` remain the dependency locks. The
adjacent `<pin>.bundle.json` binds a transport artifact to the TSV's SHA-256
and records SHA-512 for its gzip and zstd encodings. Every pinned adapter needs
one: `Managoat.Runtimes.ACP` refuses to compile without it, or when it no
longer matches the TSV.

The `linux-x64-glibc-image` profile contains the selected package tree except
the native CLI packages that the image's own `claude` or `codex` replaces.
Packages, executables, and upstream notices are preserved; timestamps and
ownership are normalized.

## Bumping a pin

1. Move the version in `Managoat.Runtimes.ACP`'s adapter table and regenerate
   the lock with `scripts/acp-lock.exs`.
2. Build the bundle (below) and commit its `.bundle.json` beside the TSV.
3. After merge, publish the release assets (below).
4. Cut the server release only once the assets download. A release whose pin
   has no published bundle fails every provision of that runtime.

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

The current artifacts are at the public `acp-bundle-claude-0.81.2` and
`acp-bundle-codex-2.2.2` release tags.

## Delivery and install

The host fetches the gzip artifact from its release tag once per node,
abandons a body that runs past the recorded size as it arrives, verifies its
SHA-512 before keeping it (`Managoat.Runtimes.BundleCache`), and uploads it
through the provider file API. The installer receives its path through
`MANAGOAT_ACP_BUNDLE_FILE`.
Nothing in the sandbox downloads it.

On a fresh provision the upload and install run beside the CA install
(`Managoat.Runtimes.ACP.preload/2`), with `MANAGOAT_ACP_OFFLINE=1`: any
failure there clears staging and exits 75 without a message, and the provision
waits up to two seconds for it after the network policy. If it did not
install, `install/3` checks the pin, uploads again and installs; that run's
failure is the provision's. A reattach or a repair before spawn takes the
`install/3` path whenever its pin check misses.

The installer takes the install lock, waiting at most 30 seconds for it, and
requires Linux x64 glibc. It probes the image CLI, verifies the uploaded file
against the compiled SHA-512, then unpacks into a new directory of its own,
`<name>@<version>.<random>`. It publishes only after verification, successful
extraction and finding an image CLI at the pinned floor, by moving the PATH
link onto that directory's launcher: no directory an adapter may be running
from is rewritten or deleted, and a staging directory that was never linked is
cleared by the next install. The installer stops itself, and everything it
started, five seconds before the host's exec timeout, since that timeout does
not stop the command in the sandbox. Every failure exits nonzero with a line
naming the step and no URL or credential. The image CLI's version is the first `X.Y.Z` on the first line
its `--version` prints, so a suffix or an extra word is accepted; a probe that
fails or prints no version runs once more with a 15-second limit. A CLI that
is still missing, failing, unparseable or below the floor fails the install as
`{:acp_adapter_image_probe, runtime, status, first_line}` rather than as a
generic exit, so an image whose CLI changed its output is one recognisable
reason. There is no manifest, npm or download fallback. Zstd is
published but not used: the sandbox images carry no `zstd`.

Timing reports `lock_wait`, `image_probe`, `bundle_extract`, `finalize` (with its child `node_wait`) and `link`; the span
itself carries the total and the outcome, and `cache_hit` says whether the pin
was already installed.
