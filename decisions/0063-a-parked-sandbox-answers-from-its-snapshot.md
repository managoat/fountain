---
type: ADR
title: "A parked sandbox answers file reads from the snapshot its park took"
description: "A park takes a bounded, redacted, encrypted snapshot of the git work trees under the runtime's working directory, after the checkpoint and before the suspend, and the four sandbox files reads answer a suspended sandbox from it with `snapshot_at`, where it holds the answer. Anything it does not hold stays `409 sandbox_not_ready`. The machine is still never woken for a read."
tags: [api, sandbox, apps]
status: stable
adr: "0063"
adr_status: "Accepted"
date: 2026-10-02
---

# 0063 — A parked sandbox answers file reads from the snapshot its park took

**Status:** Accepted, 2026-10-02. Built in the same PR:
`Fountain.SandboxFiles.Snapshots`, the `sandbox_snapshots` table, the call in
`Fountain.Machines.Park`, and the `snapshot_at` field on the four responses.
Nothing described here is unbuilt.

## Context

[0039](0039-sandbox-files-over-the-api.md) gave apps that watch an agent work
four read-only requests on a sandbox — a listing, a file, `git diff`,
`git status` — and decision 6 made them never wake a parked machine: a
`suspended` sandbox is `409 sandbox_not_ready`, because a read that resumed
it would spend provider time outside any turn.

That is right about the cost and wrong about the moment. A machine is parked
once its agent has been idle for a while, which is exactly when a person comes
back to see what the agent did. The app then has nothing to show: not the
file the agent wrote, not the tree, not the diff. Ravix, the app this was
first reported from, shows "asleep" over an empty Files tab until somebody
sends a prompt to wake the machine just to look at it — the provider time 0039
refused to spend, spent anyway, by a person, slowly.

What the code already offers:

- **The park is one protocol with one owner**
  ([0058](0058-the-machine-has-one-owner.md)). `Machines.Park` claims the
  machine's lease, stamps `transition: "parking"`, and then — outside every
  lock and transaction, under a renewed lease — takes the home checkpoint and
  calls the provider's suspend. Between the stamp and the finalize nothing
  can start work on the machine and every files read is refused, so the disk
  is as still as it will ever be, and the machine is still up.
- **Every reaper and server park goes through it**, including the reaper's
  sweep of machines nobody is watching.
- **The files scripts already run over `exec`**, confined by physical path,
  with arguments as positional parameters, on every provider.

## Decision

1. **The park takes the picture.** After the checkpoint and before the
   suspend, `Machines.Park` calls `Snapshots.capture/1`. It is best effort on
   exactly the checkpoint's terms: rescued, logged, and never a reason not to
   park, because an unparked machine keeps billing. It runs as the owner's
   own provider call, not through `Machines.Reads`, which refuses the stamped
   row by design.

2. **What is kept is the agent's work, chosen by git.** The git work trees
   found under the runtime's working directory (`find -P`, five levels,
   skipping package caches and dependency trees); in each,
   `git ls-files -co --exclude-standard`, so ignored output and the home's
   dotfiles are left out with no list of names to maintain. For each
   repository, the default `git diff` and `git status` in its `all` and
   `normal` forms. The listing of every directory a kept path sits in and of
   those between the working directory and each repository. The bytes of the
   files, changed ones first and then the shallowest.

3. **Bounded, in size and in time.** 16 repositories, 20,000 paths, 1,500
   directories; files up to 256 KiB each (the files API's default read), at
   most 2,000 of them and 4 MiB in all; diffs and statuses up to the 1 MiB
   cap the status read already has. Two fixed scripts with thirty seconds
   between them, well inside the minute the park's caller waits
   (`Machine.park_timeout_ms/0`).

4. **Redacted when taken, encrypted at rest.** Content, diffs, statuses and
   names are redacted with the values a live server has registered as well as
   the identity's: the inference credential and the callback token are only
   known while a server is up, and when the snapshot is read there is none.
   They are redacted again when served. Both payloads are compressed terms
   under the tenant's DEK, in one row per sandbox; listings, diffs and
   statuses decrypt only the manifest, and only a file read decrypts the
   contents.

5. **Read only while parked, and only where it knows.** The live read runs
   first, always, and decides on the row under the machine's lock as before.
   Only its `suspended` refusal turns to the snapshot, and the snapshot is read
   only while the row is `suspended`. An answer carries `snapshot_at`, the
   instant it was taken. A read the snapshot cannot answer — an ignored
   directory, a file past a bound, a symlink, a diff with `staged` or `ref` —
   is the `409 sandbox_not_ready` it always was. Where the snapshot can rule a
   path out (its directory was listed whole and holds no such name) it is
   `404`, as a live read would be. Confinement is the live reads' own
   `resolve_path/2`.

6. **One picture, the latest or none.** The next park replaces the row; a
   capture that fails removes it, so a parked sandbox never answers from a
   picture older than its last park. A machine that stops for good drops it
   (`Conversations.sandbox_status_effects/2`), and the row cascades with the
   sandbox and the account.

7. **Decision 6 of 0039 stands.** Nothing here wakes a machine. The snapshot
   costs one park thirty seconds at most and some database storage; it costs
   no provider time once the machine is parked.

## Consequences

- An app shows a parked agent's work at once, marked with when it was taken,
  and can offer to wake the machine for anything the picture does not hold.
- Every park pays for two more `exec` calls before its suspend. On Sprites the
  suspend is a no-op and the machine scales to zero by itself, so this is
  time on a machine that is idle anyway.
- Storage grows with parked sandboxes: one row each, at most about 4 MiB of
  file content before compression plus the manifest.
- `snapshot_at` is a new optional field on four responses. A client that
  ignores it reads a parked sandbox's answer as if it were live; the SDK
  contract regenerates it.
- What it does not cover: work outside a git repository, ignored files, files
  past the bounds, and anything that changed between the last park and a wake
  — after a wake the machine answers live.

## Alternatives considered

- **Snapshot in the app, after each turn.** What Ravix would have done alone.
  It misses everything written after the last turn (a terminal, a setup
  script), costs an exec per turn rather than per park, works only where the
  app can exec, and every app would build it again. The park is the one place
  that knows the machine is about to sleep.
- **Remember what was read live, and replay it.** Cheapest, and it answers
  only for what somebody already looked at — never the file the agent wrote
  while nobody was watching.
- **Waking the machine for a read.** 0039 refused it; nothing has changed.
- **A provider checkpoint or volume read.** A Sprites checkpoint restores a
  machine and cannot be read as files, and no other provider offers a read of
  a parked disk; it would be per-adapter work for one provider at best.
- **Every file in the home.** The home holds the agent's credentials, caches
  and dependency trees. Git's own view of the work is both the bound and the
  privacy line.
