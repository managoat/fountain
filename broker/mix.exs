defmodule RemoteBroker.MixProject do
  use Mix.Project

  def project do
    [
      app: :remote_broker,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:managoat_broker, "== 0.18.0"},
        {:req, "~> 0.7.5"},
        {:jason, "~> 1.4"},
        {:plug, "~> 1.16", only: :test}
      ],
      releases: [remote_broker: []]
    ]
  end

  def application, do: [extra_applications: [:logger, :ssl], mod: {RemoteBroker.Application, []}]
end
