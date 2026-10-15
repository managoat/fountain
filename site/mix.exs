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
      {:phoenix_live_view, "~> 1.2"},
      # The manual (`docs/` at the repo root): comrak through MDEx renders it,
      # Lumis highlights its fenced code at build time, Jason writes the
      # search index. Lumis is called directly rather than through MDEx's
      # highlighting, whose NIF bundles every grammar (147 MB against 12 MB).
      {:mdex, "~> 0.13.5"},
      {:lumis, "~> 0.7.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
