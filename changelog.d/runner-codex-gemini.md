### Fixed

- Codex and Gemini agents run on self-hosted runners. Before, every codex
  conversation on a runner failed at provision with
  `{:codex_login_write, :command_exited}`, and every gemini turn exited 127,
  because both relied on a CLI that the hosted images ship and a runner does
  not have. Codex now gets its `auth.json` written directly, and Gemini's CLI
  is installed, pinned, when it is missing (managoat_runtimes 0.5.6). The
  runners page listed CLIs Fountain did not install; it now says what each
  runtime gets.

### Changed

- Sprites refuses checkpoint calls unless checkpoint creation is enabled,
  which matches the capability it advertises (managoat_sandbox 0.5.4).
  Fountain already checks that capability first, so nothing changes in use.
