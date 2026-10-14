### Upgrade notes

- **The reapply columns are dropped** (#2676). Migration `20261014173000`
  removes `conversations.configuration_revision` and
  `sandboxes.build_fingerprint`, which nothing has read or written since
  reapply was removed. Take it only after the release that removed reapply
  is fully rolled out.
