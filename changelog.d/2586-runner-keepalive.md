### Fixed

- A runner on a host that suspends, like a sprite between requests, now
  reconnects when the host wakes (#2586). It pings Fountain every 10 seconds
  and reconnects when a ping goes unanswered, instead of waiting forever on a
  connection that died while it was suspended.
