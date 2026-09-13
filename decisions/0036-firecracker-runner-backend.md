---
type: ADR
title: "A Firecracker microVM backend for the self-hosted runner"
description: "`fountain runner --backend firecracker` gives each sandbox its own microVM instead of a directory; the in-VM agent serves the same protocol with the same Process backend over vsock, so the isolation is the machine boundary rather than a second implementation of exec. Built and running on hardware. Egress policy is still not advertised, which currently makes every runner unusable for a broker tenant."
tags: [sandbox, architecture, self-hosting, cli, security]
status: stable
adr: "0036"
adr_status: "Accepted"
date: 2026-08-27
generated: { by: human:jhgaylor, at: 2026-08-27T04:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-27T04:00:00-04:00 }
stale_after: 2026-11-27
---

# 0036 — A Firecracker microVM backend for the self-hosted runner

**Status:** Accepted — built in this PR: the `Backend` seam in
`cli/internal/runner`, `Firecracker` (the microVM backend), `guestLink` (the
host's vsock end) and `fountain runner-guest` (the in-VM agent).

**Verified on hardware** on 2026-08-27, against `fireball` (Ryzen 5 PRO
6650H, Firecracker v1.16.1, Ubuntu 24.04, guest kernel 6.1.155), provisioned
by `jhgaylor/home-cloud` `playbooks/fountain-runner.yml`. A microVM's guest
agent answered a vsock ping **1.8s after `InstanceStart`**;
`systemd-detect-virt` in the guest reported `kvm`; an exec through the
forwarding path returned exit 0 with the guest's static address configured
from the kernel command line and egress through the host bridge returning
HTTP 200. The daemon registers and stays connected as a runner.

Extends [0022](0022-self-hosted-runner-provider.md), which named this mode and
did not build it. Inherits the contract from
[0018](0018-sandbox-provider-abstraction.md) and the park-never-destroy rule
from [0017](0017-suspend-idle-sandboxes.md).

## Context

0022 shipped the self-hosted runner in trusted mode and said so in as many
words: no VM, no container, no `sandbox-exec`, no egress policy. It also
recorded the way out.

> A container/VM mode (Apple's `container`, Tart, a Linux runner under Docker)
> is compatible with the protocol (the daemon would translate `create` into a
> container and `HOME` into a mount) and is **not built**.

That compatibility claim is the load-bearing one, and it is true for a
specific reason: the runner wire protocol never mentions directories. It has
`create`, `exec`, `spawn`, `attach` and eleven others, and not one of them
says what a sandbox is made of. Only the daemon said that, because `Daemon`
held the wire and the substance in the same file.

Three things push on trusted mode.

- **Trust is the reason people do not run one.** "Run it on a machine where
  you would hand a capable colleague a shell" is an honest sentence and a
  narrow audience. The machines worth attaching — a home server, a GPU box, a
  machine on a LAN with things worth reaching — are exactly the ones where
  that sentence is uncomfortable.
- **`packages.apt` fails on a Mac** and Fountain does not translate it to
  `brew`. A Linux guest makes an environment portable across providers again.
- **A microVM parks better than a directory.** 0017 says the sandbox
  filesystem is the agent's memory and an idle sweep must never destroy it.
  The process backend honours that by stopping processes and keeping the
  directory, which loses everything in memory. A paused microVM keeps the
  processes too.

## Decision

### The daemon grows a Backend seam

`Backend` is the fourteen ops of the wire protocol plus `StopAll`. `Process`
is 0022's behaviour, unchanged and still the default. `Daemon` keeps the wire:
the frames, the error taxonomy, the op switch, the reply.

The interface carries the contract obligations in its doc comments — the
idempotent-adopting create, the not-found-versus-transient distinction, the
exit-truth rule, replay from byte zero, stdin totality. None of them is
checkable by a compiler, and each of them is a way to destroy an agent's
memory or to report a failed turn as a success.

### A sandbox is a microVM on a private copy of a base image

`--backend firecracker` boots one Firecracker microVM per sandbox. The
daemon spawns `firecracker`, drives its HTTP API over the VM's own unix
socket, and holds the VM as a child process.

The sandbox's disk is a copy of `--fc-rootfs`, made with `cp --reflink=auto`
and never replaced once it exists. That copy is the agent's memory, so a
create against a sandbox whose disk is present boots a VM onto that disk
rather than provisioning a fresh one. A daemon restart therefore rebuilds the
same VM, on the same address, with the agent's work intact.

### The guest agent is the process backend, over vsock

`fountain runner-guest` runs inside the VM and serves the same newline-framed
protocol, with an ordinary `Process` backend rooted at `/home`. Its one
sandbox is `/home/sprite`, which makes the `/home/sprite` path mapping the
identity: a provisioning script that writes `/home/sprite/.env` writes exactly
there, with no rewriting on either side.

This is the whole economy of the design. Exec, streams, stdin, sessions,
journals and replay are not reimplemented for microVMs. The code that is the
trusted-mode runner on a host is the agent inside the guest, and the isolation
is the boundary around it.

The host needs no AF_VSOCK support, because Firecracker publishes a guest's
vsock ports as a unix socket with a `CONNECT <port>` handshake. Go's `net`
package has no AF_VSOCK support at all, so only the guest half uses raw
syscalls, and only on Linux.

### Two ordering rules the link owes

- **A spawn's replay must not pass the spawn's own reply.** The guest honours
  it on its side, but the host writes its reply only after the forwarding call
  returns, so the link holds the guest's frames for that session and releases
  them in the `after` the daemon already runs for exactly this purpose.
- **A microVM that dies mid-turn must not read as success.** Fountain reads a
  stream that stops with no exit frame as exit 0. A dropped link therefore
  ends every live session with exit 137 and a line saying why.

### Suspend pauses the VM

`suspend` is `PATCH /vm {"state": "Paused"}` and `resume` is its opposite. The
guest stops being scheduled, its processes keep their state, and the disk is
untouched. A turn that an idle sweep interrupts continues where it stopped
rather than restarting.

Waking is automatic. Anything that forwards to a guest first boots a VM that
is down and resumes one that is paused, so a sandbox Fountain never explicitly
resumed still answers — the way a Sprites sandbox wakes on its next exec.

### The daemon stops at the bridge

One tap device per VM, named from a hash of the sandbox name because Linux
caps an interface at 15 bytes and a Fountain sandbox name is 47. The tap joins
a bridge the operator names in `--bridge`, and the guest gets a static address
from `--subnet` on the kernel command line.

The daemon writes no firewall rule and no NAT rule. Creating the bridge,
addressing it and deciding what may leave it are the operator's, on a machine
that invited the daemon to run sandboxes and not to reconfigure networking.

## Consequences

- A self-hosted runner stops requiring the trust that 0022 asked for. The
  audience for "attach your own machine" widens to every machine where the
  operator would not hand out a shell.
- `packages.apt` works on a runner, because the guest is Linux whatever the
  host is.
- **A park frees CPU, not RAM.** A paused microVM keeps its memory resident.
  Snapshotting it to disk would free that, at the cost of a restore path and
  the vsock reconnection that a snapshot breaks. Not built.
- **Egress policy is still not advertised, and that now blocks more than
  `limited`.** A microVM makes a real policy possible for the first time on
  this provider, since each sandbox owns a tap device.
  `Fountain.Sandbox.capabilities/0` is a property of the *adapter*, not of one
  runner, so a runner that could enforce one cannot say so without a
  Fountain-side change to negotiate capabilities per runner.

  Running this on hardware surfaced the cost. `Provisioning.check_broker_support/4`
  ([0019](0019-egress-credential-brokerage.md) gate 1a) refuses a brokered
  conversation on any provider without `:network_policy` unless
  `BROKER_ALLOW_UNENFORCED` is set. So on a deployment that runs a broker,
  *no* runner can host a conversation at all — process or microVM — and the launch
  fails with `backend_lacks_network_policy` before a sandbox exists. That is
  correct behaviour by 0019 and it makes the capability gap a blocker rather
  than a missing feature. Closing it needs two pieces: the runner advertises
  its backend's capabilities in the `/api/runners/ws` handshake and Fountain
  resolves them per runner at launch, and the Firecracker backend implements
  `apply_network_policy` as nftables rules on the sandbox's tap.
- **The base image is the operator's to build.** Fountain ships no rootfs and
  no kernel. The image must carry the sandbox packages, the `fountain` binary
  for the guest architecture, and an init that starts `fountain runner-guest`.
  A VM that boots without the agent is refused at create, with an error naming
  the agent, rather than accepted and left to hang on every turn.
- The daemon runs `firecracker` directly rather than under `jailer`. The
  isolation the jailer adds is between the VMM and the host, which matters for
  a multi-tenant fleet and matters less for a machine serving its owner. A
  jailer mode is compatible with everything here and is not built.
- One host. Each microVM runs on the machine the daemon runs on.
- `Fountain.Sandbox.Runner`, `Fountain.Runners.Connection` and the runner's
  server-side story are untouched. This is a change to what the daemon does
  with a request, not to the protocol, so no Fountain deploy is involved.

## Alternatives considered

- **Speak the sprites.dev wire protocol and point `SPRITES_BASE_URL` at the
  host** — zero Fountain changes and zero daemon changes, and the existing
  adapter would work. Rejected because it needs public ingress into a home
  network with TLS and a shared platform token, and because it would inherit
  Sprites' semantics permanently, including the 16 KiB replay tail that #772
  had to work around. Worth revisiting only to build a general-purpose
  sprites.dev-compatible host, which is a different product.
- **A fifth `Fountain.Sandbox` adapter, `:firecracker`** — a free choice of
  wire protocol, at the cost of the same inbound-reachability problem as
  above, plus the schema enums, the boot check and the conformance suite. The
  runner's dial-out socket already solves NAT and already carries this exact
  vocabulary.
- **SSH into the guest instead of vsock** — needs sshd in the base image, key
  injection at boot, and a network path that works before the network is the
  thing being tested. vsock needs none of those and is up before the guest has
  an address.
- **firecracker-containerd, Ignite or flintlock** — an orchestrator would own
  VM lifecycle, which is the half of this that is least interesting. It would
  add a daemon to run and a dependency to track for the part that is a few
  hundred lines of HTTP over a unix socket.
- **Destroy the VM on idle instead of a pause** — frees RAM and loses every
  in-guest process, which is what the process backend already does. The
  pause is the thing a microVM makes uniquely cheap, so it is the default;
  freeing RAM is the snapshot follow-up.
