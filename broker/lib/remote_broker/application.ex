defmodule RemoteBroker.Application do
  @moduledoc false
  use Application
  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:remote_broker, :enabled, true) do
        :ok = RemoteBroker.Events.attach()

        [
          RemoteBroker.Events,
          {Managoat.Broker,
           port: Application.fetch_env!(:remote_broker, :port),
           ca_seed: Application.fetch_env!(:remote_broker, :ca_seed),
           store: RemoteBroker.Store,
           diagnostics_interval: 5_000}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: RemoteBroker.Supervisor)
  end
end
