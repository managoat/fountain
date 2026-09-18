# Node startup investigation (#2402)

`probe.py` compares an actual Node executable with a sandbox image's Node
launcher. It runs three single-process controls and at most ten six-process
batches per path by default, stopping after the first abnormal batch. Each
process gets a fresh home, working directory and temporary directory, and only
`PATH`, `HOME`, `TMPDIR` and `LANG` in its environment. It makes no Fountain or
model requests.

Run inside a disposable Linux sandbox:

```sh
python3 probe.py \
  --node /.sprite/languages/node/nvm/versions/node/v24.18.0/bin/node \
  --shim /.sprite/bin/node \
  --output /tmp/node-startup-evidence \
  --capture-core
```

Use the actual installed Node path. The default payload only prints Node's
version. To test ACP startup, add `--adapter /absolute/path/to/dist/index.js`;
that payload uses `--version`, never a prompt. `--rounds` is bounded to 1–20
and `--workers` to 2–8. The output directory must not already exist.

Exit 1 means a child failed, timed out, or left a core; exit 0 means no failure
was observed in this sample. Read `metadata.json` and `results.jsonl`, including
each child's native return code, signal, stdout, stderr and core paths. A
successful wrapper can conceal a crashing helper, so outer exit codes alone
are insufficient. With core capture disabled, the probe cannot detect a helper
crash whose output and exit are swallowed by the launcher.

Core capture requires the existing Linux `core_pattern` to be `core` or
`core.%p` and a nonzero hard core limit. The probe changes its own inherited
core limit, not system settings. Cores can consume hundreds of MB each. Keep
them with the private investigation artifacts; commit the reproducer and
symbolized findings, not memory dumps. Retrieve files with the provider's
filesystem API before terminating the sandbox.

Local checks:

```sh
python3 -m unittest discover -s scripts/runtime-startup -p 'test_*.py' -v
python3 scripts/conflict-markers.py
python3 scripts/changelog.py check
git diff --check
```

## Findings from September 18, 2026

[Fountain #2402](https://github.com/managoat/fountain/issues/2402) reported one
exit 139 among six shared-sandbox Claude turns. The original sandbox was
already deleted, so the original crashing executable remains unproven.

The follow-up reproduced a related failure on Fountain image
`361c5c6bd9f3abfed07809f626b6b2b365bbb670`, using a fresh, empty Sprites
sandbox, owner API access, the account's existing brokered OAuth credential,
runtime `claude` and model `anthropic/claude-haiku-4-5`:

| Exercise | Result |
| --- | --- |
| Single inference control | 1 completed |
| Six concurrent conversation creates | All returned 201; 5 turns completed, 1 failed before inference |
| Standalone ACP `--version`, through the image launcher | 3/3 serial passed; 1/30 concurrent children received SIGSEGV, with empty stdout and stderr |
| Final checked-in Node-only probe, direct executable | 3/3 serial and 60/60 concurrent passed |
| Same Node-only probe, image launcher | 3/3 serial passed; first six-process batch left one SIGSEGV core from an npm helper, although all six outer commands returned 0 |

These are bounded observations, not a population failure rate. The final probe
stops on its first abnormal batch. Passing direct launches do not establish
that bypassing the image launcher fixes every Node crash.

The failed follow-up conversation was
`6fd6c640-8b3f-4de0-bdce-aaef90f0cd5c`, turn
`02f9ba34-1998-4461-ad38-95ad1dc98672`, on sandbox
`674675ce-8365-4f35-916e-cb62a3b35749`
(`fountain-50e06232-0e8b00e1`). Its broker completed at
`03:59:47.471921Z`; reattachment completed at `04:00:21.610849Z`; the turn
started at `04:00:21.718366Z` and failed at `04:00:23.613149Z` with
`{:acp_adapter_install_exit, 139, ""}`. The stored turn's `exit_code` is null:
this failure was in the adapter preparation command, whereas the original
incident's turn recorded exit 139 from its running command. Do not conflate
those two reporting paths.

Installed versions and platform:

| Component | Version |
| --- | --- |
| Sprites guest | Ubuntu 26.04.1, x86_64, Linux 6.12.105-fly |
| Node / V8 | 24.18.0 / 13.6.233.17-node.50 |
| npm | 12.0.2 |
| Claude ACP adapter / Agent SDK | 0.75.1 / 0.3.257 |
| SDK-bundled Claude / standalone Claude | 2.1.257 / 2.1.251 |

The Node executable's SHA-256 was
`41a74efb34cbde5c7632cdac0cf8bd1a14d0b8d73dc1e82755014d9a9ce70f5c`.
The image's `/.sprite/bin/node` is a Bash/NVM launcher, which starts npm helpers
before execing the actual Node executable. Core metadata identified one helper
as `node .../bin/npm --version`; others had already changed their title to
`npm`. The failing minimal probe imports neither ACP nor Claude and uses no
shared home or inference credentials.

An earlier credential-free launcher probe captured a SIGSEGV core whose
symbolized stack begins:

```text
v8::internal::ClearStaleLeftTrimmedPointerVisitor::VisitRootPointers(...)
v8::internal::JavaScriptFrame::Iterate(...)
v8::internal::Isolate::Iterate(...)
v8::internal::Heap::IterateRoots(...)
v8::internal::ScavengerCollector::CollectGarbage()
v8::internal::Heap::Scavenge()
```

Further Node-only cores terminated with SIGSEGV in unsymbolized generated code.
This establishes native Node crashes independently of Fountain's transport
exit-code interpretation. It does not establish where memory first became
invalid. Kernel logs also contained separate Node `int3` traps at
`v8::base::OS::Abort()`; those are not themselves evidence of SIGSEGV.
The guest had 8 GiB RAM, with no increments to cgroup `oom` or `oom_kill` during
the exercise. The process monitor observed roughly 2.4 GiB of charged memory
during the concurrent wake/setup period. There is no captured OOM-killer
evidence explaining these crashes.

[nodejs/node#62393](https://github.com/nodejs/node/issues/62393) reports the
same V8 visitor crash site on another platform/version. It is a relevant
upstream comparison, **not a confirmed duplicate or an established root fix**.
[nodejs/node#64841](https://github.com/nodejs/node/issues/64841) was also
examined; its later discussion attributes its workload to HTTP/2 teardown,
so its initial Maglev hypothesis is not a basis for applying `--no-maglev`
here. No broker-lock change, automatic prompt retry, concurrency restriction
or Node flag workaround is justified by this evidence alone.

## Remaining work and evidence

Share the standalone reproduction and symbolized stack with the Node/Sprites
maintainers, then test a proposed runtime/image fix with both this probe and
the original bounded Fountain wave. #2402 should remain open until the
original failure is sufficiently attributed and the remediation is verified.
No upstream report has been posted by this investigation.

[The prepared upstream report](upstream-report.md) contains a sanitized
reproduction, exact native stack, missing environment details and candidate
validation plan. It is ready for review and submission to Node/Sprites
maintainers; preparing the draft did not submit it. A local offline Linux
smoke run verifies the diagnostic CLI, but does not validate a remedy for the
affected Sprites guest.

Private artifacts are under `work/2402-investigation/` in the issue worktree:
the fixture manifest, deployment snapshot, per-conversation events/turns,
version and resource snapshots, process samples, individual probe JSONL files,
`final-repro-results.jsonl`, symbolized backtraces and a compressed core from
the credential-free run. The scripts there record the seven inference prompt
submissions and ownership-checked fixture cleanup. One premature control
attach received HTTP 409 while the sandbox was starting; it created no
conversation and submitted no inference. No inference prompt was retried.
Cleanup completed: the eight temporary conversations, agent and environment
were deleted, and Fountain confirmed the sandbox was terminated. The retained
core was decompressed and its SHA-256 matched the sandbox's original file
before termination.
