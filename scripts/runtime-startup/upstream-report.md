# Draft: native Node SIGSEGV during Sprites Node launcher startup

Prepared for Node.js and Sprites maintainers from the September 18, 2026
investigation of [Fountain #2402](https://github.com/managoat/fountain/issues/2402).
This report has **not been submitted upstream**. The accompanying
[probe.py](probe.py) is the exact standalone diagnostic run in the affected
guest. No Fountain installation, model request, account credential or shared
home directory is required to run it.

## Observed behavior

Concurrent launches of the Sprites image's `/.sprite/bin/node` can produce a
native Node SIGSEGV in an npm helper even when the outer launcher returns 0
and prints the expected Node version. A prior launcher probe captured a
symbolized V8 garbage-collection stack; the final Node-only probe captured a
SIGSEGV in unsymbolized generated code. These are separate cores.

The payload is only `console.log(process.version)`. The image's launcher is a
Bash script that sources NVM, runs `nvm use default`, resolves the selected
binary and execs it. NVM activation starts npm helpers before the requested
Node payload runs. One captured core identified the process as
`node .../bin/npm --version`; others had the process title `npm`.

## Environment

| Component | Observed value |
| --- | --- |
| Guest distribution | Ubuntu 26.04.1 |
| Architecture | x86_64 |
| Kernel | `6.12.105-fly`, `#1 SMP PREEMPT_DYNAMIC Thu Aug 27 01:16:44 UTC 2026` |
| Node | 24.18.0 |
| V8 | 13.6.233.17-node.50 |
| npm | 12.0.2 |
| libuv | 1.52.1 |
| Node executable | `/.sprite/languages/node/nvm/versions/node/v24.18.0/bin/node` |
| Node executable SHA-256 | `41a74efb34cbde5c7632cdac0cf8bd1a14d0b8d73dc1e82755014d9a9ce70f5c` |
| Launcher | `/.sprite/bin/node` (Bash/NVM script) |
| Guest RAM | 8 GiB |

The Fountain server image was built from
`361c5c6bd9f3abfed07809f626b6b2b365bbb670`. That identifies the application
deployment, **not a pinned Sprites guest image**. The guest image identifier,
NVM version, glibc version and CPU model were not captured; maintainers should
record these in a fresh reproduction. The installed binary's provenance has
not been checked against the official Node release checksum manifest.

## Reproduction

Use a disposable affected Sprites guest with Python 3 and the existing Node
installation. Copy `probe.py` from this directory into the guest, then run:

```sh
python3 probe.py \
  --node /.sprite/languages/node/nvm/versions/node/v24.18.0/bin/node \
  --shim /.sprite/bin/node \
  --output /tmp/node-startup-evidence \
  --capture-core
```

Use a new output directory and the actual installed executable path. Core
capture requires the guest's existing `core_pattern` to be `core` or
`core.%p` and a nonzero hard core limit. The probe changes its own inherited
core limit only. It does not change sysctls or install packages. Cores can be
hundreds of MB each; retain them privately and retrieve artifacts before
deleting the guest.

Each child has a fresh home, working directory and temporary directory. Its
environment contains only `HOME`, `TMPDIR`, `LANG=C.UTF-8` and
`PATH=<actual-node-directory>:/usr/bin:/bin`. Stdin is closed. Direct launches
and launcher launches each get three serial controls, followed by up to ten
rounds of six simultaneous children. Each command has a 20-second timeout.
The entire probe stops after its first abnormal batch, preserving that batch.
It returns 1 for a nonzero native exit, timeout or discovered helper core.

The final affected-guest run began at `2026-09-18T04:07:58.452675Z`:

| Path | Serial controls | Concurrent sample |
| --- | --- | --- |
| Actual Node executable | 3/3 passed | 60/60 passed |
| Image launcher | 3/3 passed | First batch: 6/6 outer exits were 0; one child directory contained an npm SIGSEGV core |

The affected child's sanitized result was:

```json
{
  "case": "shim",
  "phase": "concurrent",
  "round": 0,
  "argv": ["/.sprite/bin/node", "-e", "console.log(process.version)"],
  "returncode": 0,
  "signal": null,
  "timed_out": false,
  "stdout": "v24.18.0\n",
  "stderr": "",
  "cores": ["<output>/shim-concurrent-0-4/core"],
  "elapsed_seconds": 0.993,
  "failed": true
}
```

`signal: null` describes the outer command. GDB independently confirmed
SIGSEGV in the helper core. Without core capture, a successful launcher can
conceal this failure. These samples do not establish a population failure
rate or prove direct launches are immune.

## Native stack

An earlier credential-free launcher probe retained a 594,132,992-byte core
with SHA-256
`78c2becb59492575c5e84961f6d1d0f50ef92ffa3263af1288ff56460e144c3c`.
GDB reported `Program terminated with signal SIGSEGV, Segmentation fault.`
The main-thread stack, symbolized against the installed Node executable:

```text
#0  0x0000000000ed5267 v8::internal::ClearStaleLeftTrimmedPointerVisitor::VisitRootPointers(v8::internal::Root, char const*, v8::internal::FullObjectSlot, v8::internal::FullObjectSlot)
#1  0x0000000000dfc5cf v8::internal::JavaScriptFrame::Iterate(v8::internal::RootVisitor*) const
#2  0x0000000000e0c8b9 v8::internal::Isolate::Iterate(v8::internal::RootVisitor*, v8::internal::ThreadLocalTop*)
#3  0x0000000000ee1b25 v8::internal::Heap::IterateRoots(v8::internal::RootVisitor*, v8::base::EnumSet<v8::internal::SkipRoot, int>, v8::internal::Heap::IterateRootsMode)
#4  0x0000000000fb7f4d v8::internal::ScavengerCollector::CollectGarbage()
#5  0x0000000000edd1cb v8::internal::Heap::Scavenge()
#6  0x0000000000ef5dc5 v8::internal::Heap::PerformGarbageCollection(v8::internal::GarbageCollector, v8::internal::GarbageCollectionReason, char const*)
```

The final Node-only probe's different helper core terminated at
`0x00007fce8be14909 in ?? ()`, in generated code. Do not attribute the
symbolized visitor stack to that final core. The crash site does not establish
where memory first became invalid.

Captured cgroup `oom` and `oom_kill` counters were zero before and after the
concurrent Fountain exercise; no OOM-killer evidence was captured. Kernel
logs also contained separate Node `int3` traps that resolved to
`v8::base::OS::Abort()`. Those traps are distinct from the SIGSEGV cores.

## Questions for maintainers and candidate validation

Sprites: can this be reproduced on an identified guest image, and does a
launcher that resolves and execs the selected Node binary without invoking
npm avoid the helper crash? Does the same binary and npm workload reproduce
on an equivalent Linux host outside Sprites? Compare one variable at a time;
the current direct-node payload exercises less code than npm startup does.

Node: is the visitor stack actionable with the retained core and matching
binary, or is a debug build/additional V8 logging needed? The similarly named
crash site in [nodejs/node#62393](https://github.com/nodejs/node/issues/62393)
is a comparison, not a confirmed duplicate. No fixed version or effective
Node flag has been established for this reproducer.

A cached local `node:24` image provides Node 24.20.0 / V8
13.6.233.17-node.53, making that version a candidate for an affected-platform
comparison, **not an identified remedy**. A local offline smoke test passed
on aarch64 Linux under OrbStack: three serial commands and one two-command
batch for each probe path, both pointing directly at `/usr/local/bin/node`.
That verifies the diagnostic's Linux CLI; it contains neither the Sprites
launcher nor the affected x86_64 environment and does not validate a fix.
The local image digest was
`sha256:be23f54a88d34e8824c741b19b91064094f92c1c97b194144bfc8b50d67258e2`.

For a proposed remedy, retain baseline and candidate artifacts on the same
affected platform, including Node/npm/NVM versions, binary checksum, image
identity, and the probe's metadata/results. Run the same bounded Node-only
comparison with core capture, followed by the optional ACP `--version`
payload. A clean bounded sample is evidence for that sample, not proof of
elimination. Then verify one serial Fountain turn and the original bounded
six-turn shared-sandbox wave, with no automatic inference retry. Preserve the
crashing executable identity and command phase if either exercise fails.

## Relationship to Fountain #2402 and retained evidence

The original report recorded exit 139 from a running Claude command; its
guest was already deleted. A follow-up six-turn wave completed five turns
and failed one during adapter preparation with
`{:acp_adapter_install_exit, 139, ""}`. That preparation failure stored a null
turn exit code. These are different reporting paths; the standalone Node
crash does not yet identify the executable responsible for the original one.
The minimal reproducer does not load Claude, ACP or Fountain.

The private investigation retains raw JSONL, full symbolized backtraces,
version/resource captures, the observed launcher source and the verified
compressed credential-free core. This draft excludes account identifiers,
conversation IDs, tokens, request bodies, hostnames and memory dumps.
Share `probe.py` and this report first; arrange private core transfer only if
maintainers need it. No new provider resources were created for this draft,
and the original investigation's temporary resources were cleaned up.

Fountain #2402 remains open until original-failure attribution and remediation
are sufficient. This evidence does not justify a broker-lock change,
automatic prompt retries or a production concurrency restriction.
