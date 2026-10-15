### Changed

- **The permissions page now says which tool calls each runtime asks about**
  (#2670). It said claude and codex ask before every tool. Measured on the
  pinned adapters, claude runs read-only commands in its workspace without
  asking, and codex in its default mode writes in its workspace and has its
  own reviewer decide escalations, so few of its tool calls reach a
  permission policy. See
  [permissions](https://managoat.com/docs/concepts/permissions#what-each-runtime-can-do).
