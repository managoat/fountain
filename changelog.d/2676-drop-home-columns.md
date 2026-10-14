### Upgrade notes

- **The persistent-home columns are dropped** (#2676). `sandboxes.mode`,
  `runtime`, `codex_inference_source`, `codex_peer_homes` and
  `departed_conversations`, the `sandboxes_home_identity_index`, the
  `record_departed_conversation` trigger and `agents.sandbox_mode` are
  removed. Upgrade to the release that removed persistent homes first, and
  let it roll out fully before taking this one: a replica of an older
  release still reads these columns.
