defmodule Site.MixProject do
  use Mix.Project

  def project do
    [
      app: :site,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: false,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # `~H`, `embed_templates` and function components. Nothing here starts an
      # endpoint: the templates are rendered to disk by `mix site.build`.
      {:phoenix_live_view, "~> 1.2"}
    ]
  end
end
