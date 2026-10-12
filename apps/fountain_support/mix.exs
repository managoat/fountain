defmodule FountainSupport.MixProject do
  use Mix.Project

  @moduledoc """
  The problem-report extension (ADR 0043, #1528).

  The second first-party Fountain extension, and the one that exists to prove
  the seam rather than to widen it: it uses three of the nine callbacks
  (`api_mounts/0`, `migrations/0`, `openapi_paths/0`) and adds none.

  An OTP application that depends on `:fountain`, is compiled into the bundled
  release, and is switched on by naming `FountainSupport.Extension` in
  `config :fountain, :extensions`.

  AGPL-3.0-or-later, like `apps/fountain` and unlike a
  `managoat_*` component library (ADR 0037): databaseful, Fountain-specific
  product code that depends on the server. Not published to hex.
  """

  def project do
    [
      app: :fountain_support,
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
    # No `mod:`. This extension starts no processes of its own — its one
    # background job is an Oban worker enqueued by its own context, run by the
    # host's Oban instance on the host's `:mailer` queue. An application with no
    # callback module is still an application: it is loaded, so
    # `:code.priv_dir(:fountain_support)` resolves its migration path, and the
    # release starts and stops it with everything else.
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # The one dependency, and it points one way. Fountain must never declare
      # a dependency on :fountain_support; the distribution owns inclusion.
      {:fountain, in_umbrella: true}
    ]
  end
end
