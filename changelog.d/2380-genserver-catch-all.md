### Fixed

- **Three supervised processes no longer crash on a message they do not
  match** (#2380). Defining any `handle_info/2` or `handle_cast/2` clause
  removes the one `use GenServer` supplies, so the execution deadline worker,
  the native broker's request log and the analytics sink were taken down by an
  unrelated monitor, a linked process exiting or a cast from a later release.
  Each now logs the message's shape and continues, keeping its in-flight jobs,
  its buffered egress rows and its queued events. A new guardrail test holds
  the rule for the rest of the server.
