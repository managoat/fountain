# Environment layer measurements, 2026-10-16

Evidence for [ADR 0090](../decisions/0090-portable-environment-layers.md) and
[#2530](https://github.com/managoat/managoat/issues/2530). This is a repository
setup experiment, not production conversation provisioning. No cache feature
was enabled or deployed by this experiment.

## Workload and method

Managoat commit `20c30a3565e5bd0176ed76174f2cc9cbda327388`, cloned from the public
repository, on new Sprites in the `managoat-tenants` organization. The base was
Ubuntu 26.04.1 LTS, x86_64, reporting eight CPUs. Tools: mise 2026.9.12, OTP
28.3, Elixir 1.19.2-otp-28, PostgreSQL 18.6 and zstd 1.5.7. PostgreSQL differs
from the setup guide's version 16; both cold and restored machines used 18.6.

The lean run installed `build-essential libncurses-dev libssl-dev unzip zstd
postgresql`, then cloned and checked out the commit above. A mise binary was
uploaded beforehand; its workstation-to-Sprite transfer is outside the timers.
Commands in the repository were:

```bash
mise install
mise exec -- mix local.hex --force
mise exec -- mix local.rebar --force
# Start the fresh local PostgreSQL cluster and set the documented dev password.
mise exec -- mix deps.get
mise exec -- mix setup
mise exec -- mix compile
```

Shell phase timers used `$EPOCHREALTIME`. Cold totals are sums of these timed
phases, not uninterrupted end-to-end wall clocks. Machine creation, CLI file
upload and orchestration are excluded. No private repository credentials,
production environment values, inference keys or user data were supplied.

An earlier run installed additional Erlang source-build prerequisites (autoconf,
m4, wx/GL, SSH/ODBC and documentation libraries). Its checkout of local commit
`2ecc4f806` failed because that commit was not available remotely. It continued
at the public commit above, retaining the package/clone timings. It is recorded
separately; the lean run was uninterrupted. This is not two repetitions of an
identical cold workload.

## Cold setup

| Phase | Lean prerequisites | Broad prerequisites, interrupted |
|---|---:|---:|
| Packages | 39.023 s | 83.273 s |
| Clone | 3.173 s | 3.667 s |
| Pinned toolchain | 123.674 s | 107.191 s |
| Hex | 0.904 s | 0.730 s |
| Rebar | 0.910 s | 0.650 s |
| Database startup/configuration | 5.151 s | 2.533 s |
| Dependency fetch | 3.403 s | 5.574 s |
| Setup: compile, migrate, seeds | 86.787 s | 68.979 s |
| Verification compile | 6.390 s | 5.068 s |

Lean setup totaled **263.025 s**, or **269.415 s** including verification.
The broad run's phase sum including verification was **277.665 s**. Both had
206 migration records after setup.

## Export and artifact contents

A marker was created before package installation. After setup and verification,
PostgreSQL was stopped, and a ctime-based changed-file list was archived with
GNU tar (`--no-recursion --null --numeric-owner --xattrs`) and zstd `-T0`.
Exclusions included `/proc`, `/sys`, `/dev`, `/run`, temporary directories,
apt caches/lists, provider checkpoint/control sockets, SSH files and the env
file. A second variant omitted the users' `.cache` directories.

This method does not capture deletions and is not a safe general-purpose
production layer format. Removing `.cache` worked for this workload; do not
assume all projects can lose it. No memory or running processes were captured.

| Export measurement | Result |
|---|---:|
| `enumerate_ms` | 5,168 |
| `archive_with_cache_ms` | 14,066 |
| `compressed_with_cache_bytes` | 580,843,076 |
| `tar_ms` | 1,402 |
| `raw_bytes` | 650,055,680 |
| `compress_1_ms` | 589 |
| `compressed_1_bytes` | 268,666,042 |
| `compress_3_ms` | 7,644 |
| `compressed_3_bytes` | 245,415,810 |
| `compress_9_ms` | 2,245 |
| `compressed_9_bytes` | 228,226,153 |

Sizes above are bytes; `_ms` values are milliseconds. Level 3 had an anomalously
long single compression sample; these runs are not enough to rank compression
levels by speed. At level 3, removing caches saved **57.7%** of compressed bytes.

Before upload, inspection found a generated PostgreSQL snakeoil TLS private
key, which was excluded and regenerated separately on each destination. A
query counted every nonempty public database table: only `schema_migrations`
(206 rows) and a generated `oban_peers` record (one row) were present. Restarting
and stopping the database for this audit removed `pg_internal.init`; a repack
using the old file list failed, so the changed-file list was regenerated while
the database was stopped. No failed archive was uploaded.

The final sanitized archive was **666,849,280 bytes raw**, **245,469,651 bytes
compressed**, SHA-256
`5b68e295ef681848ad10ea780717b89fbfc33dbc25976934134a8d4fdb8fc801`.
Its size differs slightly from the compression comparison because of the audit
and repack. Upload to the private temporary Tigris bucket took **3.525 s**
(69.6 MB/s). A short-lived presigned PUT was used; bucket credentials stayed
on the workstation. No application-layer encryption was measured.

## Restore onto three fresh machines

Each machine installed zstd, streamed the presigned GET through `zstd -d` and
`sudo tar -xpf - -C /`, regenerated its TLS key, fetched Git, started PostgreSQL,
verified tool versions, ran `mise exec -- mix compile`, and checked the commit
and migration count. All three succeeded with the same commit and 206
migrations. The second machine's compile log was empty, confirming no rebuild.

| Phase | Machine 1 | Machine 2 | Machine 3 |
|---|---:|---:|---:|
| Install zstd | 8.485 s | 6.540 s | 4.685 s |
| Stream download + extraction | 4.566 s | 4.905 s | 3.820 s |
| Git fetch | 0.598 s | 0.473 s | 0.504 s |
| Start database | 2.757 s | 2.494 s | 2.306 s |
| Verify compile | 1.750 s | 1.269 s | 1.146 s |

Only machine 3 had a single timer covering the whole restore script through
verification: **12.982 s**, including TLS regeneration and the intermediate
checks. Do not substitute phase sums for total times on machines 1 and 2;
those sums omit TLS regeneration and checks. Creation times were roughly
0.1–0.4 s and excluded. The first two restore commands ran concurrently;
provider and storage cache state were not controlled.

After restoration, each machine downloaded the same archive to a local file
and checked its SHA-256. Machine 3 also downloaded to `/dev/null` three times:

| Measurement | Sample 1 | Sample 2 | Sample 3 |
|---|---:|---:|---:|
| Download to local file | 48.690 s | 3.069 s | 41.014 s |
| Download to `/dev/null` | 3.259 s | 3.076 s | 54.045 s |
| `/dev/null` time to first byte | 0.476 s | 0.479 s | 0.045 s |

All samples completed with 245,469,651 downloaded bytes. Local decompression
without extraction took 0.498–0.721 s. The slow `/dev/null` sample establishes
that destination archive-file writes are not the sole cause of variability;
it does not identify the network/provider cause. This is not a p95 estimate.

## Earlier transfer calibration

Before the workload was chosen, a separate probe archived base-image Erlang,
Elixir, Node and Bun files: 442,040,320 raw bytes, 174,233,108 compressed at
level 3. Upload took 3.837 s; six download-to-file samples took 1.381–2.677 s.
Local extraction took 1.642 and 1.675 s; streamed extraction took 32.880 and
2.080 s. Both extractions matched. These files already exist in the base;
this was transfer calibration, not a useful environment cache or a cold-build
comparison. Keep its slow sample rather than pooling it into the workload data.

## Interpretation and next measurement

The experiment supports pursuing a cache: the lean run spent 123.674 s on the
pinned toolchain and 86.787 s on application setup. A compressed result avoids
repeating that work. It does not eliminate transfer costs or stalls.

It did not measure broker policy, adapters, model startup, encryption, artifact
authentication, build isolation, version invalidation or failure fallback. The
production ordering in ADR 0090 stages ciphertext, narrows the network floor,
authenticates, then extracts. It cannot claim the streaming probe's latency.
Repeat with that path, including slow/corrupt downloads and a fresh cold
fallback, before enabling cache reuse.

All eight temporary Sprites were destroyed. Both stored objects were deleted
(HTTP 204), the temporary bucket was destroyed, and local storage credentials
and presigned URLs were deleted. No production data or configuration changed.

## Launch-path validation, 2026-10-16

The follow-up uses disposable machines through the deployed server's Sprites
connection (`jake-gaylor` in the provider response), its broker CA and broker-only
network floor. Production is an older release without the cache helper, so the
trusted helper is uploaded through the server's existing sandbox API. No provider
credential is copied out of the server. Helper upload and RPC orchestration are
outside the inventory timer. These are live helper/protocol measurements, not a
claim that the newly implemented launch path is deployed.

The complete fresh image contains approximately **7,091,634,221 regular-file
bytes** and **109,194 metadata entries** in a separate filesystem census. The
helper inventories 109,193 entries. These are filesystem bytes inspected, **not
measured network traffic**. A content-derived base check has a real I/O cost:

| Probe | Result | Time |
|---|---|---:|
| Original scanner | Refused the provider's xattr response at `/.sprite` | 0.675 s |
| Corrected xattr reader, old inventory limits | Hit the 4 GiB/100,000-entry ceiling | 33.104 s |
| Separate 16 GiB/200,000-entry inventory budget | Completed | 46.331 s |
| Another fresh machine, before marker exclusion | Completed, but different base hash | 45.461 s |
| Fresh machine after marker exclusion | Completed, shared base hash | 44.835 s |
| Second fresh machine after marker exclusion | Completed, same base hash | 47.669 s |

The provider's xattr size query returned 23 bytes while the subsequent list
returned zero bytes. Reading the allocation instead of the actual returned length
invented an empty attribute name and refused the inventory. The fix preserves
attribute validation and uses the actual byte count; it does not ignore xattrs.

A repeat scan on one machine returned exactly the same base and full-inventory
hash. Across machines, sudo's `.sudo_as_admin_successful` marker had a new
creation timestamp. That marker is now excluded only from base compatibility,
with the existing machine-identity/platform-trust exclusions. Its metadata still
participates in the authenticated export baseline. Two fresh machines then
returned the same base:
`sha256:f55cfdda76962674c08763d5ca35461d3f5d371e245dc52166c7c36691eb43d7`.

The inventory budget is separate from the unchanged artifact limits: 1 GiB
ciphertext, 4 GiB tar, 100,000 artifact entries and 1 GiB per file. A larger image
inventory does not authorize a larger artifact. Regression tests cover both
failures found live, the independent limits, and key/ciphertext cleanup after a
real encrypted helper restore.

The encrypted Managoat workload validation is in progress. The earlier 12.982 s
experimental restore does not include the roughly 45-second base inventory and
must not be presented as the current integrated launch latency.
