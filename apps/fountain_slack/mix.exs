defmodule FountainSlack.MixProject do
  use Mix.Project

  @moduledoc """
  The Slack connection provider as an extension (ADR 0054, #2152).

  The fourth first-party Fountain extension, and the second to exist for a
  connection provider alone: it implements `connection_providers/0` and
  `docs/0`, and nothing else. What it contributes is one config-backed
  `Fountain.Connections.Provider` — the Slack app whose user token, one per
  workspace, is brokered to `slack.com` — and the manual page that describes
  it. The OAuth flow, the token storage and the broker are the host's; this
  application never sees a token.

  An OTP application that depends on `:fountain`, is compiled into the bundled
  release, and is switched on by naming `FountainSlack.Extension` in
  `config :fountain, :extensions`.

  AGPL-3.0-or-later, like `apps/fountain` and the other extensions and unlike a
  `managoat_*` component library (ADR 0037): Fountain-specific product code that
  depends on the server. Not published to hex.
  """

  def project do
    [
      app: :fountain_slack,
      version: "0.16.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: coverage()
    ]
  end

  defp coverage do
    Path.expand("../../coverage.exs", __DIR__) |> Code.eval_file() |> elem(0)
  end

  def application do
    # No `mod:`. This extension starts no processes: a provider is data the
    # host reads through a callback. An application with no callback module is
    # still an application — it is loaded, so the release starts and stops it
    # with everything else and `config :fountain_slack` has an owner.
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # The one dependency, and it points one way. Fountain must never declare
      # a dependency on :fountain_slack; the distribution owns inclusion.
      {:fountain, in_umbrella: true}
    ]
  end
end
