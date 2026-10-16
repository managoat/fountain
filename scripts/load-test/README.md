# Repeatable conversation load test

Run tiny real-model turns through the public Managoat API to compare fresh
launches, warm follow-ups and later resumes. This exercises sandbox creation,
the broker, harness installation, runtime initialization and prompt delivery.
It uses Python 3.10+ and its standard library; no Kubernetes access is needed.

## Run it

Set an explicit target and an owner API key that can create agents. The runner
does not read CLI profiles or choose a production URL for you.

```bash
export MANAGOAT_BASE_URL=https://your-instance.example
read -rsp 'Managoat API key: ' MANAGOAT_API_KEY; echo
export MANAGOAT_API_KEY

python3 scripts/load-test/run.py run \
  --output tmp/load-test/before \
  --deployment v0.31.9 \
  --duration 3600 --interval 30 --keep-idle
```

`--output` must be a new directory for `run`. It is created with mode 0700.
Use a different directory for each run; `tmp/` is gitignored. The optional
deployment label is what you actually deployed, not the checkout's revision.
Keep these artifacts private: they contain resource IDs, replies, diagnostics
and token usage, but not the supplied API key or raw runtime initialization.

The default [example.json](example.json) starts three independent lanes:

| Lane | Provider | Runtime/model |
|---|---|---|
| sprite-haiku | Sprites | Claude / `anthropic/haiku` |
| e2b-haiku | E2B | Claude / `anthropic/haiku` |
| e2b-codex | E2B | Codex / `openai/gpt-6-astra` |

Configure both providers and the corresponding inference credentials on your
instance first. Edit a copy of the config and pass `--config path.json` to
choose models available in your pinned runtimes. Full Claude model IDs have
been accepted on one provider and rejected on another; keep model-selection
failures in the results rather than silently falling back. A bare alias can
resolve differently after a runtime update, so inspect `model_selection` too.

Each lane schedules one operation every 30 seconds, alternating:

1. Create a fresh conversation and send `Reply only: orange`.
2. Send the same prompt to that conversation, then terminate it.

Each lane has at most one operation in flight. If it misses slots while busy,
the journal records `skipped_busy`; it never launches a catch-up burst. The
default is up to 360 operations over an hour, about half fresh launches. The
duration starts after agent creation. Operations already running at the end
can drain until their operation deadline (default 240 seconds), followed by
cleanup. `--timeout` includes provisioning, so a provision failure with no
turn row is captured immediately from its stage event rather than mislabeled
as a turn timeout.

The runner creates dedicated agents with tool use denied. One-word replies
minimize generated text, but runtime system prompts, thinking and harness
startup still use tokens and provider compute. It does not simulate inference.

### Increase E2B to four lanes

Copy the config and set `copies` to 2 on each E2B entry, leaving Sprite at 1.
That gives two Haiku and two Codex E2B lanes: four operations per interval,
plus the Sprite operation. `copies` multiplies an entry's concurrency/rate;
setting it to 4 on **both** E2B entries would create eight E2B lanes. There is
a total limit of 32 lanes. Keep the interval and lane counts identical across
before/after comparisons.

## Stop, preserve and resume

Ctrl-C or SIGTERM stops scheduling, interrupts polling and cleans up known
non-retained conversations and their agents. An HTTP request already in flight
may take up to its network timeout to return. Normal completion does the same
cleanup. No global stop file or process-name matching is used.

With `--keep-idle`, the first successful fresh/follow-up pair in **each lane**
is retained instead of terminated. `summary.json` lists its conversation,
sandbox and agent IDs. Those agents stay available for the later resume. All
other test conversations are terminated. No suspend or administrative state
mutation is performed; leave the retained conversations idle long enough to
park naturally under the instance's configured idle bound.

```bash
# Only sends a prompt if the saved sandbox reports suspended.
python3 scripts/load-test/run.py resume --output tmp/load-test/before

# Retry cleanup after an outage or an interrupted process; retains saved IDs.
python3 scripts/load-test/run.py cleanup --output tmp/load-test/before

# Explicitly finish with the retained conversations and their agents too.
python3 scripts/load-test/run.py cleanup --output tmp/load-test/before --include-retained

# Rebuild the report offline; no API key or network required.
python3 scripts/load-test/run.py report --output tmp/load-test/before
```

`resume` skips a sandbox still reporting ready (`skipped_not_suspended`) and
leaves all retained resources intact, including after a failed resume. It
records the pre-prompt sandbox status; a suspended row proves a lifecycle wake
was requested, not that a provider's physical VM reached a particular power
state. If a normal follow-up encounters a suspended sandbox, it is classified
as `cold_resume`, not warm. A ready sandbox can still require reconnecting the
runtime after a server restart: use the trace's `response_path` to distinguish
that from true session reuse.

Run only one `run`, `resume` or `cleanup` command against a directory at a
time. Cleanup verifies each conversation's agent before terminating it. A
saved run cannot be resumed or cleaned up against a different base URL.

Writes are **never automatically retried**. `client_request_id` is correlation,
not idempotency. A lost create response can mean the server created a resource
whose ID the client never learned. The report lists `unresolved_launches` and
`unresolved_agent_creates`: reconcile these manually by the conversation title
`load-test <client_request_id>` or the saved agent name. Do not treat automatic
cleanup as proof that these ambiguous writes created nothing. Cleanup is
repeatable and lists remaining known resources after an outage. Agents with
ambiguous conversation launches are kept for manual reconciliation too.

## What to compare

`run.json` records the target, configuration, deployment label and timing
settings. `results.jsonl` is an append-only journal of resource IDs, stage
events, structured output, request IDs, errors and one result per operation.
`summary.json` groups outcomes and successful latency samples by lane and
operation kind. A run with a failed operation or pending known cleanup exits
nonzero; the report retains failures even after a successful cleanup retry.
Not-yet-suspended resumes are explicit skips, not successes. Inspect read
errors and skipped slots even when all completed operations eventually pass.

Compare reliability before latency:

| Measurement | How to interpret it |
|---|---|
| Operation outcomes, HTTP status, failed stage | Includes launch/provision errors before a turn exists. Count these in the denominator. |
| `skipped_busy` | Offered slots lost while a lane was occupied; do not call fewer samples a throughput improvement. |
| Read errors | 503s/disconnects observed while polling; a later successful turn does not erase them. Transient read failures are retried within the deadline. |
| `request_to_first_text_observed_ms` | Client monotonic time from POST until a poll sees assistant text. Includes HTTP and polling overhead; it is an upper bound, not exact server first-token timing. |
| `turn_to_first_text_server_ms` | Difference between persisted turn-start and text-event timestamps. Excludes pre-turn provisioning; independent of workstation/server clock skew. |
| First-visible-update timings | Text, thinking, plan or tool-use blocks; excludes raw startup output. Do not confuse reasoning visibility with the requested answer. |
| `request_to_terminal_observed_ms` | Client-observed completion/failure, excluding cleanup. Latency summaries include only correctly completed `orange` replies. |
| Usage and model selection | Keep actual runtime/model selection and input/output/cache usage alongside results. Missing usage is not zero usage. |
| Sample count, median, p95, max | Exact nearest-rank p95 of the recorded samples. A p95 from four probes is effectively a maximum, not a reliable tail estimate. |

Use the same configuration, interval, duration, poll interval and prompt before
and after a fix. Do not compare a warm-heavy run to a fresh-heavy one. Record
deployment times separately; run an uninterrupted baseline first, then a
separate rollout experiment. A two-minute burst is useful as a smoke test but
does not establish sustained capacity. Run the increased rate long enough to
collect useful samples for **each** provider/runtime/path.

### Correlate with traces and service health

The runner deliberately has no Grafana, Tempo, Kubernetes or database
credentials. Use the run's UTC timestamps and IDs in your own observability
tools. The [observability guide](../../docs/guides/operate/observability.md)
describes the exported signals. In Tempo, substitute a recorded conversation
ID and select the test's time range:

```text
{resource.service.name="fountain" && name="fountain.turn" && span.conv_id="CONVERSATION_ID"}
  | select(span.provider, span.runtime, span.response_path,
           span.response_first_text_ms, span.first_text_ms,
           span.response_phase_admission_queue_ms, span.response_phase_sandbox_ms,
           span.response_phase_bootstrap_ms, span.response_phase_runtime_session_ms,
           span.response_phase_prompt_text_ms, span.error)
```

These server spans separate queueing, sandbox allocation, harness bootstrap,
session initialization and model response. `response_path=cold` includes fresh
launches; it does **not** imply a successful resume of an existing suspended
conversation. Inspect wake spans separately, especially for session ownership.
Provision failures can have no `fountain.turn` span: correlate their persisted
stage events and application logs using the conversation and sandbox IDs.

Check readiness, ingress 503s, deployment events, database pool wait, CPU/run
queues, broker errors and cleanup backlog for the same window. In particular:

- **[Adapter stalls (#2846)](https://github.com/managoat/managoat/issues/2846):** count provision failures, check installer error
  details and total stall time, and correlate broker/registry failures. Confirm
  retry fixes with a controlled stalled-fetch regression as well as the soak.
- **[Codex resume ownership (#2865)](https://github.com/managoat/managoat/issues/2865):** preserve a Codex lane, wait for natural
  parking, resume it and inspect `session/resume` and any `thread_active_writer`
  error. A fresh launch or a warm follow-up alone does not verify the fix.
- **[Rollout recovery (#2866)](https://github.com/managoat/managoat/issues/2866):** during a separately labeled run, deploy through
  the normal release procedure. Compare unavailable intervals and read errors;
  check for orphaned/duplicate launches and prompts. This runner polls events,
  so it does **not** test CLI/browser SSE reconnection: also follow a real CLI
  stream through the rollout when validating that issue.

First-text histograms omit requests with no text. Successful-completion
histograms omit failures. Rolling Prometheus `increase` counts are extrapolated
and can be fractional; sparse histogram p95s can reflect bucket interpolation.
Use this journal for exact attempted-operation counts, and compare the graphs
alongside failures rather than treating a flat latency line as a health check.

## Test the runner without live traffic

```bash
python3 -m unittest discover -s scripts/ci -p test_load_test.py -v
```

The existing CI tooling suite discovers these tests. They use a fake API and
cover stage failures without a turn, paginated text, write ambiguity, transient
read errors, output verification, retained-resource cleanup and resume gating.

## Verify a Recreate rollout

Run this on a controlled deployment first. Keep one replica and `Recreate`;
never overlap two schedulers to shorten the gap. Start the external probe before
changing the image and keep it running until the replacement is ready:

```bash
python3 scripts/load-test/availability.py https://YOUR-INSTANCE/health/ready \
  --duration 300 --interval 1 --timeout 2 --output ingress.jsonl > ingress-summary.json
```

The output records proxy-generated 503s and connection failures, including
requests that never reach application metrics. The summary brackets each
cluster with the last success and next success. These are sampling bounds,
not a claim of continuous failure between samples. A success between clusters
splits them; an outage crossing the recording boundary is explicitly censored.
Request timeouts can make the effective sample interval longer than one second.

Capture these alongside the probe, using the deployment's actual namespace:

```bash
kubectl -n YOUR-NAMESPACE get pods -l app=fountain --watch --output-watch-events -o json > pods.jsonl
kubectl -n YOUR-NAMESPACE get endpointslices -l kubernetes.io/service-name=fountain --watch --output-watch-events -o json > endpoints.jsonl
kubectl -n YOUR-NAMESPACE get events --watch --output-watch-events -o json > events.jsonl
```

Retain timestamped logs from both old and replacement pods. Application logs
mark `rollout shutdown phase=begin`, `endpoint_stopped`,
`conversations_stopped`, and `machines_stopped`. Their monotonic millisecond
values measure each teardown segment within one process. Startup logs mark
`begin` and `endpoint_started`; correlate migration logs, container start,
image-pull events, readiness, EndpointSlice changes and the external probe.
Endpoint listening alone does not establish ingress restoration.

Alongside the availability probe, run the conversation load test above. Include
its failed and unresolved launches, not just successful-turn latency. Exercise
three positions: a create request during the gap; an established turn's stream;
and an accepted follow-up waiting for provisioning. A failed POST is reported
without automatic replay. For a lost response, use the saved correlation ID and
inspect the server before deciding to submit again. It is not an idempotency key.
A queued submission interrupted before turn admission emits `wake/failed` with
`reason=deployment_interrupted` and `retryable=true` on the next boot. Its text
is never replayed. A turn already admitted follows the existing reattach path.

The CLI and SDK default to a 180-second stream recovery window. Configure the
CLI with `MANAGOAT_STREAM_RECOVERY_TIMEOUT` (seconds), or SDK run/send
`recovery.recoveryTimeoutMs` and stream `recoveryTimeoutMs` (milliseconds).
The SDK's `onReconnect` reports the attempt, cursor and delay. A caller's own
cancellation or shorter overall run timeout still wins.

The 2026-10-16 investigation measured about 25 seconds from old-pod deletion to
replacement listening on two isolated rollouts. That is an observed baseline,
not an availability guarantee: old-pod grace is 120 seconds, image pulls and
migrations add time, and a failed replacement can remain unavailable. The
180-second client window is a bound on waiting, not a promised outage maximum.
Batch release and overlay changes; preserve the deployed image reference for
manifest-only promotions to avoid another Recreate restart.

Validate the probe offline with:

```bash
python3 -m unittest discover -s scripts/load-test -p 'test_*.py'
```

### Controlled local drain measurement (2026-10-16)

A production-mode release was restarted behind a local HTTP proxy, using an
isolated PostgreSQL 16 database, synthetic account and idle conversation. An
authenticated SSE connection remained open at SIGTERM. No provider or model was
called. The proxy was sampled every 250 ms; the replacement started only after
the old process exited.

| Measurement | Before graceful SSE drain | After graceful SSE drain |
|---|---:|---:|
| Shutdown begin → endpoint stopped | 15.004 s | about 0.003 s |
| SIGTERM → replacement ready | 17.132 s | 1.945 s |
| Failed proxy samples | 67 | 8 |

The application now closes both conversation and account SSE readers in
`prep_stop`, before the listener drains. A late subscriber also sees the drain
marker. Clients reconnect from their cursor; running work and ordinary HTTP
requests retain their existing shutdown behavior. The HTTP drain budget itself
is unchanged.

This reproduces an avoidable 15-second tail with an active stream. It does not
prove the cause of the historical 99-second shutdown, nor predict Kubernetes
image pull, scheduling or endpoint propagation time. Production still needs the
same external probe around its next release to establish its actual new gap.

### Bootstrap and adapter installation details

Find `fountain.fresh_provision` by `span.conv_id` for the same conversation.
Provisioning precedes the turn and can have its own trace. Its nested
`fountain.provision_step` spans identify configuration writes (`runtime_config`,
`instructions`, `env_file`, `broker_ca_install`), broker preparation and adapter
work. Parallel children overlap; use their timestamps rather than summing their
lengths to identify the critical path.

`fountain.adapter_install` carries `install_cache_hit` (0 or 1) and completed
`install_<phase>_ms` timings for `lock_wait`, `image_probe`, `manifest`, `npm`,
`finalize` and `link`. A missing phase did not complete or was not needed; it
is not a measured zero. `manifest` includes parallel fetch, verification and
extraction; `npm` identifies fallback work. The encompassing span also includes
manifest upload and sandbox exec overhead.

Download attributes include `download_attempts`, `download_bytes_max` and
`download_{dns,connect,tls,first_byte,total}_max_ms`. Each is the maximum of
that field across observed curl attempts, including retries; the maxima can
come from different packages. Curl's times are cumulative milestones, and
streaming extraction/backpressure can contribute to total transfer time.
They are not disjoint phases or pure network latency. Cached installs emit no
download measurements. An exec transport failure can lose its buffered timing
output; the enclosing span still records failure and elapsed time.

Installer attributes accept only fixed numeric fields. URLs, commands,
environment values and raw installer output are not exported as attributes.
