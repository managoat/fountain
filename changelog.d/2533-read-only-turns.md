### Added

- **Read-only turns** (#2533). `POST /api/conversations/{id}/prompts` and
  `POST /api/conversations` take `read_only: true`. The turn runs in the same
  conversation and runtime session, so the agent answers from its context, but
  the runtime refuses every write: on `claude`, a fresh runtime process starts
  under a managed Claude Code policy that denies `Bash`, `Edit`, `MultiEdit`,
  `NotebookEdit` and `Write` and ignores stored allow rules, and Fountain
  refuses every tool request that is not a read. The next normal prompt runs
  writable again. The turn, its `started` stage event, its `prompt` block and
  the prompt's response carry `read_only: true`. Other runtimes, Codex among
  them, refuse the prompt with `422 read_only_unsupported` rather than run it
  writable. See
  [Ask without write access](https://managoat.com/docs/api#ask-without-write-access).
