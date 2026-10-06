# Self-hosted runners

A **runner** is a machine you own that runs the `fountain runner` daemon. It
can be a Mac mini under the desk, a home server or a GPU box.

It is the fourth [sandbox provider](sandbox-contract.md), and the one whose
control plane sits on *your* side of the network. The daemon dials out to
Fountain, holds one connection, and serves sandboxes for an agent whose
`sandbox_provider` is `runner`. There is no inbound port, it works behind NAT,
and nothing bills you by the minute.

A backend decides the substance of a sandbox. The default backend makes it a
directory, and the agent's processes belong to the machine. On Linux with KVM,
`--backend firecracker` makes it a microVM instead. Read
[a microVM for each sandbox](#a-microvm-for-each-sandbox) for that one.

Three reasons to want one.

- **Hardware Fountain cannot rent.** A Mac, for Xcode, a macOS-only toolchain
  or a local model on Apple silicon. A GPU. A machine on your LAN that holds
  something the agent needs.
- **State that stays.** The sandbox is the agent's memory. A machine that
  never shuts down has nothing to park and nothing to pay for.
- **A setup you own outright.** A self-hosted Fountain and your own machines
  need no vendor account at all.

[ADR 0022](https://github.com/managoat/fountain/blob/main/decisions/0022-self-hosted-runner-provider.md)
holds the design.

## Summary

| | |
|---|---|
| Role | Sandbox provider, on a machine **you** own. |
| Turned on by | Nothing. It is on unless you set `SANDBOX_RUNNERS_ENABLED=false`. |
| Credential | None on the platform side. Each daemon uses the user's own full-scope API key. |
| Suspend | The process backend stops the sandbox's processes. The firecracker backend pauses the microVM. The disk stays either way. |
| Capabilities advertised | `:suspend`, `:attach` |
| Not advertised | Network policy, TTY, checkpoints, public URL. |
| Isolation | **None on the process backend.** Trusted mode, and the agent's processes run as you. The firecracker backend gives each sandbox a microVM. |

## Read this first: trusted mode

This section is about the default backend, which is `--backend process`.

A runner sandbox is a **directory** on the machine. The agent's processes run
**as you**, with your network, your `PATH` and your tools. There is no VM, no
container, no `sandbox-exec`, and no egress policy between the agent and the
machine.

Fountain points `HOME` at the sandbox directory. Dotfiles, skills and `.env`
land there and stay with that one conversation. That is the whole of the
isolation.

Run it on a machine where you would hand a capable colleague a shell. If that
is more trust than you want to give, put the sandboxes in microVMs instead.

## Start one

```bash
fountain auth login                       # once; a full-scope API key
fountain runner                           # name = this machine's hostname
fountain runner --name mini --root ~/work/fountain-sandboxes
```

The daemon logs `runner: connected`, then stays in the foreground. Run it
under `launchd`, `systemd`, tmux, or whatever keeps a process up on that
machine. Ctrl-C stops it, and stops its sessions, because a runner's
processes belong to the daemon. It reconnects with backoff on any drop. It
gives up only when Fountain refuses the key, rejects the name, or has runners
switched off.

Then pin an agent to it. Use **Agents**, then **edit**, then **Sandbox provider**, then **runner**,
or send `sandbox_provider: "runner"` to `POST /api/agents`.

Fountain places a new conversation for that agent on your **most recently
connected online runner**. Start one while no runner is online and it fails
plainly, with `no_runner_online` and HTTP 409. It does not queue.

Account, then Runners, or `GET /api/runners`, lists each machine that has
connected, with live online status. `DELETE /api/runners/:id` forgets one. A
daemon that you left up reconnects and registers itself again.

## What the machine needs

It needs what the Sprites base image has, on the `PATH` of whoever starts the
daemon. That is `bash`, `git`, `node`, `npm`, `npx`, and `bun` for opencode.

The machine does not need the agent CLIs. Fountain brings what each runtime
needs at provision:

| Runtime | On a runner |
|---|---|
| claude | The pinned ACP adapter, which carries Claude Code. |
| codex | The pinned ACP adapter. Fountain writes the API key to `~/.codex/auth.json`, so no `codex` binary is needed. |
| gemini | `@google/gemini-cli`, pinned, when `gemini` is not already on `PATH`. |
| opencode | `opencode-ai` through `bun`, when `opencode` is not already on `PATH`. |

npm installs go into the sandbox's own npm prefix, `<sandbox>/.npm-global`,
so Fountain writes nothing to your global node install. The npm cache is your
real `~/.npm`. The first gemini sandbox on a machine downloads about 120 MB.

Fountain adds `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` and
`~/.bun/bin` to `PATH` when they exist. So a daemon that `launchd` starts with
a minimal environment still finds Homebrew.

Two things translate, and two do not.

| Fountain assumes | On a runner |
|---|---|
| `/home/sprite` is home. | Mapped to the sandbox directory. That holds for a file path, for a work directory **and for a command argument**. A `bash -lc` script that says `/home/sprite/.local/bin/x` lands in the sandbox. |
| `~` and a relative path. | The sandbox directory. |
| `packages.apt` in an environment. | Fails. A Mac has no `apt`, and the daemon does not translate to `brew`. Leave it empty, or use `setup_script`. |
| `networking_type: limited`. | Refused at launch. The provider does not advertise an egress policy, and it will not pretend. The conversation fails before a sandbox exists, with a `network` / `failed` event whose reason is `backend_lacks_network_policy`. The agent form shows the same warning when you pair the two. |

`/tmp` is the machine's `/tmp`. The gemini and opencode workspaces live there,
and each sandbox sees the same ones, as it does inside one Linux sandbox.

## A microVM for each sandbox

`--backend firecracker` replaces the directory with a
[Firecracker](https://firecracker-microvm.github.io/) microVM. The sandbox
gets a kernel, an init and a root filesystem of its own. Its processes cannot
reach the host.

This is the VM mode that
[ADR 0022](https://github.com/managoat/fountain/blob/main/decisions/0022-self-hosted-runner-provider.md)
named and did not build.
[ADR 0036](https://github.com/managoat/fountain/blob/main/decisions/0036-firecracker-runner-backend.md)
holds the design.

```bash
fountain runner --backend firecracker \
  --bridge fcbr0 --subnet 10.61.0.0/24 \
  --fc-kernel /var/lib/fountain/vmlinux \
  --fc-rootfs /var/lib/fountain/rootfs.ext4
```

| | Process backend | Firecracker backend |
|---|---|---|
| A sandbox is | A directory under `--root`. | A microVM, on a private copy of the base image. |
| Isolation | None. The agent runs as you. | A guest, with hardware virtualization. |
| `packages.apt` | Fails on a Mac. | Works, because the guest is Linux. |
| An idle park | Stops the processes. | Pauses the microVM. The guest keeps its processes. |
| `/tmp` | The machine's own, shared. | The guest's own. |
| Host platform | macOS or Linux. | Linux, with `/dev/kvm`. |

### What the host needs

Four things.

- **Linux with KVM.** The daemon reads `/dev/kvm` at startup and refuses to
  start without it.
- **The `firecracker` executable**, on the `PATH` or at `--fc-bin`.
- **`CAP_NET_ADMIN`**, because the daemon makes a tap device for each microVM.
- **A bridge**, which you make. Give it the first host address of `--subnet`,
  which is `10.61.0.1` for the default.

The daemon writes no firewall rule and no NAT rule. Your network is yours, and
a daemon that changed it would go past its invitation. Attach the bridge to
whatever the sandboxes must reach, and put the rules you want in front of it.

### The base image

`--fc-rootfs` is an ext4 image. Each sandbox starts as a private copy of it.
That copy is the agent's memory between turns, and the daemon never replaces
it. `cp --reflink=auto` makes the copy. On XFS or Btrfs it costs almost
nothing. Elsewhere it costs a full copy.

The image must hold three things.

- The packages a sandbox needs, which are `bash`, `git`, `node`, `npm`, `npx`
  and `bun` for opencode.
- The `fountain` binary, built for the guest architecture.
- An init that starts `fountain runner-guest` at boot.

A systemd unit is enough.

```ini
[Unit]
Description=Fountain runner guest agent
After=network.target

[Service]
ExecStart=/usr/local/bin/fountain runner-guest
Restart=always

[Install]
WantedBy=multi-user.target
```

`fountain runner-guest` serves one sandbox, `/home/sprite`, over vsock. It
serves it with the same backend that a trusted-mode runner uses. A command in
a microVM therefore behaves as a command on the machine does. The isolation is
the boundary around the guest, and not a second way to run a command.

The daemon refuses a microVM that boots but never answers, and says which part
is absent. A sandbox that accepted a create and then hung on every turn would
be worse.

### How a request reaches the guest

Firecracker publishes a guest's vsock ports on the host as a unix socket. The
daemon opens it, asks for port 1024, and gets a stream to the agent. Over that
stream runs the same protocol that Fountain speaks to the daemon.

Two things the daemon must get right, and both are about order.

- A spawn's replay must not pass the spawn's own reply. The daemon holds the
  guest's frames until the reply is on the wire to Fountain.
- A microVM that dies in the middle of a turn must not read as success.
  Fountain reads a stream that stops with no exit frame as exit 0, so a
  dropped link ends each live session with exit 137.

### What is different

The [contract table](#how-the-contract-maps) below describes the process
backend. Four rows change.

| Fountain operation | Firecracker mechanics |
|---|---|
| Create or adopt by name | The sandbox directory holds the disk, the sockets and the log. A create adopts a disk that is there and boots a microVM onto it. A daemon restart therefore rebuilds the same VM, on the same address, with the agent's memory intact. |
| `get` | Firecracker reports the state, and not the daemon's memory of it. A disk with no microVM behind it is `suspended`, and never `not_found`. A control socket that will not answer is `unavailable`, which is transient. |
| Suspend and resume | A suspend pauses the microVM. The guest stops, and its processes keep their state, so a turn that an idle sweep interrupts continues where it stopped. The memory stays resident, so a park frees CPU and not RAM. A snapshot to disk would free the RAM, and nobody built one. |
| Exec, streams, stdin | The guest answers each of these, with the backend a trusted-mode runner uses. The daemon forwards and adds nothing. |

A wake is automatic. The daemon boots a microVM that is down, and resumes a
paused one, before it forwards a request. A sandbox that Fountain never
resumed still answers, as a Sprites sandbox does on its next exec.

### Limits

- **Egress policy is still not advertised.** A microVM makes one possible,
  because each sandbox has a tap device of its own. The capability is a
  property of the adapter and not of one runner, so a Fountain change must
  come first. Nobody built it.
- **A brokered tenant cannot use a runner.** With
  [credential brokerage](https://github.com/managoat/fountain/blob/main/decisions/0019-egress-credential-brokerage.md)
  on for an account, Fountain refuses a conversation on any provider that does
  not advertise an egress policy. Every runner is such a provider, microVM or
  not. The launch fails with `backend_lacks_network_policy` before a sandbox
  exists. `BROKER_ALLOW_UNENFORCED=true` lifts the refusal on a development
  instance, and the real fix is the row above.
- **A park keeps the RAM.** See the suspend row above.
- **The base image is yours to build.** Fountain ships no image.
- **One host.** The daemon puts each microVM on the machine it runs on.

## How the contract maps

| Fountain operation | Runner mechanics |
|---|---|
| Create or adopt by name | `mkdir -p <root>/<name>`. It adopts a directory that already exists. A name is `runner-<runner id>-<short>`. The runner id rides in the name, because the sandbox contract hands the adapter nothing else. |
| `get` | A directory that is there means the sandbox runs. A `.fountain-suspended` marker means suspended. Absent means `not_found`. **A runner that is offline gives `{:unavailable, :runner_offline}`**, which is transient. A parked directory on a machine somebody switched off is still the agent's memory, and Fountain never mistakes it for gone. |
| Suspend and resume | Advertised. A suspend stops the sandbox's live processes, with SIGTERM and then SIGKILL, and leaves the marker. A resume removes it. An idle park costs nothing, and 0017's never-aged-out rule holds trivially. |
| Exec | The command, to completion, with the request's env over the sandbox env. A nonzero exit is data and never a raise. That includes 127, which is "not found", and 124, which is a timeout. |
| Streams and reattach | The daemon journals each session in memory from byte zero. `attach` replays the journal, tagged for the attacher alone, then tails. The exit code is the real one. A session outlives the socket, so a Fountain deploy in the middle of a turn reattaches to the same process. |
| Stdin | A pipe. `close_stdin` is a real EOF. A write after the exit gives `{:error, :command_exited}`. |
| List | The union over the runners that are **online right now**. The sandboxes of an offline runner are not in the view. The reaper already treats that as "skip, converge later", because it destroys only the names it sees. |
| Network policy, TTY, checkpoints, public URL | Not advertised. |

## On the team page and the API

An accepted ACP turn keeps its place during a transient runner socket drop.
Fountain holds the turn busy for up to two minutes while the runner reconnects,
including when the server boots before the runner returns. It attaches to the
same process and prompt instead of submitting the prompt again. A reconnect
does not extend a pending permission's original timeout.

The runner switches both replay and live output to the new connection. Fountain
skips earlier turns in that process journal before restoring the active turn,
so an old permission request cannot replace the one currently waiting. If the
runner does not return within the recovery window, the turn fails and becomes
available for a new prompt. Interrupting the turn cancels recovery. Stopping the
runner daemon still terminates its processes.

A teammate whose sandbox lives on a runner shows where it runs. The roster
entry's `sandbox`, and that of each conversation object, carries `provider`,
one of `sprites|e2b|daytona|runner`. For a runner it also carries
`runner: {id, name, hostname, online, path}`. That names the machine and the
sandbox directory on it, so a client can say "on mac-mini · ~/…" and parse no
sandbox name.

Presence tells "asleep" apart from "the machine is off". While the runner is
not connected, the teammate is `machine_offline`, which reads as "machine
offline · wakes when the runner reconnects", and not `asleep` or `away`. A
message cannot wake it.

`POST /api/team/:agent_id/messages` and `POST /api/conversations/:id/prompts`
answer `503 runner_offline` with `Retry-After` until the daemon returns. That
is the shape `provisioning` uses.

A scheduled run on such a teammate waits the way a busy one waits.

A runner that connects or drops sends a `team` event on `/api/team/stream`. A
roster then notices that the machine came back, and polls for nothing.

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `SANDBOX_RUNNERS_ENABLED` | `true` | The operator's opt-out. `false` hides the provider from the selection, and refuses a daemon connection with HTTP 404 at `/api/runners/ws`. |
| `SANDBOX_PROVIDER=runner` | — | Allowed as the instance default. It needs no credential. |

The daemon reads the usual CLI settings, which are `FOUNTAIN_API_KEY`,
`FOUNTAIN_BASE_URL` and `--profile`. It needs a **full-scope** key. A
sandbox's own per-conversation token cannot attach a machine that would then
run the account's agents.

## The wire protocol

One WebSocket, with JSON text frames, at `GET /api/runners/ws?name=…` with the
bearer key. Fountain sends the requests. The daemon replies by `id`, and
streams frames for the sessions that somebody asked about.

```text
→ {"id":7,"op":"spawn","name":"runner-…","cmd":"claude-agent-acp","args":[],"env":[["K","v"]],"dir":"/home/sprite","stdin":true,"detachable":true}
← {"id":7,"ok":true,"result":{"session_id":"s-…"}}
← {"stream":"stdout","session_id":"s-…","data":"<base64>","replay_for":7}   replay, to the requester only
← {"stream":"stdout","session_id":"s-…","data":"<base64>"}                  live, to every subscriber
← {"stream":"exit","session_id":"s-…","code":0}
→ {"id":8,"op":"stdin","session_id":"s-…","data":"<base64>"}
← {"id":8,"ok":false,"error":"command_exited"}
```

The ops are `create get destroy list suspend resume write_file exec spawn
stdin stdin_close detach list_sessions attach`. The errors are the contract's
codes: `not_found`, `command_exited`, `not_supported`, `invalid`,
`unavailable` and `write_failed`.

`Managoat.Runner.Connection` is the server end, and `cli/internal/runner` is
the daemon. `Managoat.Runner.FakeDaemon` is a daemon inside the BEAM that the
conformance suite runs against. It is the executable description that both ends
must agree with.

## Related

- [About sandboxes](../concepts/sandboxes.md), for why honest capabilities
  change the lifecycle.
- [The sandbox contract](sandbox-contract.md).
- [Change sandbox lifetimes](../guides/operate/sandbox-lifetime.md). A
  provider without `:suspend` would destroy on idle, and a runner does
  advertise it.
