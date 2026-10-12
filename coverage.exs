# The `:test_coverage` configuration, in a file of its own because two mix.exs
# files need it and a copy in each would drift: the umbrella root uses it when
# `mix test.coverage` merges the partitions' exports, and apps/fountain uses it
# when `mix test --cover` reports on a single run (including a run started from
# inside apps/fountain, where the root mix.exs is never loaded).
#
# This replaces coveralls.json, which #620 removed along with ExCoveralls.
# `minimum_coverage: 85` became `summary: [threshold: 85]`; `skip_files` became
# `:ignore_modules`. ExCoveralls matched source paths, but the built-in tool
# matches *module names* — a bare atom for a single module, a regex (against
# `inspect(module)`) for what used to be a trailing-slash directory entry. The
# old `fountain/priv/` entry has no equivalent and needs none: nothing under
# priv/ is compiled into the app, so cover never instruments it.
#
# Ignoring a module here is a claim that it is exercised by the runtime rather
# than by the suite: OTP/Ecto/Swoosh boilerplate, release tasks, the Sprites
# provisioning path, and the LiveViews that predate the integration tests.
[
  summary: [threshold: 85],
  ignore_modules: [
    Fountain.Application,
    Managoat.Sandbox.Fake,
    Fountain.Repo,
    Fountain.Mailer,
    Fountain.Release,
    Fountain.Telemetry,
    Fountain.Conversations.Provisioning,
    Fountain.Conversations.Rehydrator,
    FountainWeb.SettingsController,
    ~r/^FountainWeb\.AgentsLive\./,
    ~r/^FountainWeb\.EnvironmentsLive\./,
    ~r/^FountainWeb\.HelpLive\./,
    ~r/^FountainWeb\.InferenceCredentialsLive\./
  ]
]
