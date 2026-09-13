defmodule FountainSdk.MixProject do
  use Mix.Project

  @version "0.2.1"

  def project do
    [
      app: :fountain_sdk,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Official Elixir SDK for Fountain",
      source_url: "https://github.com/managoat/fountain",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/managoat/fountain"}
      ],
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md", "LICENSE"],
        source_url_pattern:
          "https://github.com/managoat/fountain/blob/main/sdk/elixir/%{path}#L%{line}"
      ]
    ]
  end

  def application,
    do: [mod: {FountainSdk.Application, []}, extra_applications: [:logger, :ssl]]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:finch, "~> 0.23.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
