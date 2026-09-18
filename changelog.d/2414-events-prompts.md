### Added

- API: `GET /api/conversations/{id}/events` takes `?prompts=true` (#2414). With
  `blocks=true`, it fills each turn's `turn`/`started` stage event — whose
  `blocks` array was otherwise always empty — with one `prompt` block carrying
  the prompt that opened that turn. Without it the feed holds only what the
  runtime wrote, so a client replaying a conversation renders it as a monologue
  in the agent's voice. It is opt-in and adds, removes and reorders no event, so
  `meta.next_cursor`, `has_more` and the page size are unchanged. A turn whose
  `origin` is `autonomous` contributes no block. Note that `streams=acp`
  excludes stage events, and so excludes these prompts with them. `prompt` is a
  new value of the `Block.kind` enum, and the one kind never produced by parsing
  a runtime's output.
