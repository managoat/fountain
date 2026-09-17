### Changed

- Waking a parked computer is now done by one Fountain process at a time
  (#2344, ADR 0058). Two prompts arriving on one parked computer together used
  to wake it twice: both read it as parked, both asked the provider to start it,
  and both wrote it down as running. Now the second one waits for the first and
  then finds the computer already up. If the first is slow enough that the
  second gives up waiting, the second answers `503 sandbox_unavailable` with a
  `Retry-After` header, and sending it again lands on the computer that is now
  running.

- Waking a computer no longer holds up the rest of the account while it happens
  (#2344). The wake used to run inside the same check that counts how many
  computers an account has running, so starting one computer blocked every other
  start and wake that account was making, for as long as the provider took to
  answer. The count is now settled before the provider is asked, and what keeps
  two wakes of the same computer apart is the computer itself. Nothing about the
  limit changes: an account at its cap still cannot wake one more, and a
  computer being woken counts from the moment it is allowed to, not from the
  moment it finishes.

- Waking a computer now appears in that account's activity trail as
  `sandbox.resumed` (#2344), beside the `sandbox.suspended` that records it
  being parked. Until now the trail showed a computer going away and never
  coming back.

- A prompt whose computer the provider says is stopped now starts it, instead of
  handing the conversation a computer that is not running (#2344). Fountain
  asked the provider whether the computer still existed and reused it on any
  answer at all; on providers that really stop a computer when it is parked —
  E2B and Daytona — a parking that had been interrupted left the computer
  stopped and the record saying it was running. Starting a computer this way is
  not counted as waking a parked one: it does not restart the maximum-lifetime
  clock and it does not appear in the activity trail, because Fountain never
  parked it.

- A prompt to a conversation whose computer is being reset or deleted now
  answers `409 sandbox_reset_pending` from every path that can meet the fence
  (#2344). One of those paths — a reset or deletion asked for in the moment
  between Fountain checking and taking the computer — used to answer `422` with
  a bare `fenced`, which told a client the request itself was malformed. The
  answer is the same one this route has given for a reset-fenced computer all
  along; `POST /api/conversations/{id}/prompts` now documents it, which it
  never did.

- A wake the provider refuses now answers `503` with a `Retry-After` header
  instead of `422` (#2344). Nothing was written and the disk is untouched, so it
  is worth sending again; the old answer told every client the request itself
  was at fault and not to retry. Scheduled runs report it, and two other
  transient refusals, in words rather than as an error code.

- A prompt to a computer that an interrupted operation left a marker on is no
  longer refused (#2344). Fountain records what it is doing to a computer on the
  computer's own record, and a process that stops part-way — a deploy, a lost
  node — leaves that marker behind. A prompt arriving afterwards used to answer
  `503` until an hourly pass cleared it, up to an hour later. The next thing to
  take the computer now clears the marker itself, and a computer that is simply
  running is handed over as it always was. A computer somebody has asked to
  reset or delete is still refused, which is what that request means.

- An operation that takes longer than a minute no longer loses the computer it
  is working on (#2344, ADR 0058). Fountain holds a computer for the length of
  one operation, and that hold used to be measured from when the operation
  started rather than from the last sign of progress — so a slow checkpoint, or
  a computer coming back from long-term storage, could have its hold expire
  while it was still running and be taken over by the next cleanup pass. The
  hold is now extended while the work continues.

- An operation whose process is killed outright no longer keeps the computer
  (#2344). Fountain extends its hold on a computer while it works, and a process
  stopped without warning — a rolling deploy, a background job killed at its
  time limit — used to leave that extension running with nothing behind it, on a
  computer nothing could then take. The hold now ends when the work does, and in
  any case after ten times its normal length.

- How long Fountain is holding a computer for is now measured on the database's
  clock rather than on each server's own (#2344). Nothing about a single-server
  install changes; on a cluster, one server's clock running fast or slow can no
  longer make it disagree with the others about whether an operation is still
  running. The reading is also no longer affected by the time zone a database
  connection happens to be configured with, which could make every live
  operation look finished.
