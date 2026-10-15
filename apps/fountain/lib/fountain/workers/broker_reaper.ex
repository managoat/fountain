defmodule Fountain.Workers.BrokerReaper do
  @moduledoc """
  The daily sweep of what the egress broker leaves behind (ADR 0019 gate 4):
  expired `broker_sessions`, and `broker_requests` rows older than
  `BROKER_LOG_RETENTION_HOURS`.

  Sessions are also deleted by `Fountain.Broker.release/1` at the end of a
  conversation and by every `prepare/4`, so this pass is the backstop for a
  conversation that never released. The request log has no such moment: it is
  per-request rather than per-conversation, so age is the only rule, and
  without this pass a chatty tenant's rows would accumulate forever.

  This was `BrokerVaultReaper`, which deleted a whole vault per conversation
  from the vendor proxy once its request log had aged out. There are no vaults
  now (#1487), and the log is a table here.

  A no-op when the broker is not configured.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Fountain.Broker
  alias Fountain.Broker.Native.RequestLog
  alias Fountain.Broker.Native.Sessions

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    %{sessions: sessions, requests: requests} = run()

    if sessions > 0 or requests > 0 do
      Logger.info("broker reaper: swept #{sessions} session(s), #{requests} request row(s)")
    end

    :ok
  end

  @doc "Sweep now. `now:` pins the clock."
  @spec run(keyword()) :: %{sessions: non_neg_integer(), requests: non_neg_integer()}
  def run(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    cutoff = DateTime.add(now, -Broker.log_retention_hours() * 3600, :second)

    %{sessions: Sessions.sweep_expired(), requests: RequestLog.sweep(cutoff)}
  end
end
