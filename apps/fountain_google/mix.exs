defmodule FountainGoogle.MixProject do
  use Mix.Project

  @moduledoc """
  The Google extension (ADR 0043, #2152 step 2).

  The third first-party Fountain extension: the Gmail MCP server a conversation
  gets when its agent names a Google connection (#1178). It uses three of the
  ten callbacks (`api_mounts/0`, `conversation_mcp_servers/2`, `docs/0`) and
  adds none — the shape ADR 0043 decision 3 specified for it before it was
  built.

  An OTP application that depends on `:fountain`, is compiled into the bundled
  release, and is switched on by naming `FountainGoogle.Extension` in
  `config :fountain, :extensions`.

  AGPL-3.0-or-later, like `apps/fountain`, `apps/fountain_buzz` and
  `apps/fountain_support`, and unlike a `managoat_*` component library
  (ADR 0037): Fountain-specific product code that depends on the server's
  connections, conversations and agents. Not published to hex.
  """

  def project do
    [
      app: :fountain_google,
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
    # No `mod:`. This extension starts no processes of its own: every tool call
    # runs in the host's request process, and the Google API client is a `Req`
    # request per call. An application with no callback module is still an
    # application: it is loaded, so its modules are on the code path, and the
    # release starts and stops it with everything else.
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # The one dependency, and it points one way. Fountain must never declare
      # a dependency on :fountain_google; the distribution owns inclusion.
      {:fountain, in_umbrella: true}
    ]
  end
end
