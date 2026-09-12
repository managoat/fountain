defmodule Fountain.PlatformChatGPT.Refresher do
  @moduledoc """
  The one process on this node that talks to `auth.openai.com` for the
  deployment's ChatGPT grant (ADR 0047 decision 3).

  A refresh is an HTTP round-trip, and every conversation on the deployment
  shares the one grant, so when it goes stale every turn and every launch
  wants to refresh it at the same moment. Waiters queue here, holding no
  database connection: the first call refreshes, the rest find the row fresh
  when their turn comes.

  Across nodes, a per-grant PostgreSQL try-lock excludes concurrent upstream
  requests. Only the holder keeps a checkout; contenders release theirs
  between bounded retries. Generation/version checks still fence reconnect
  and disconnect while the provider call is in flight. The transaction is
  bounded to 20 seconds and contention to 5 seconds. Per-user queues and
  fleet-wide user keepalive scheduling remain unbuilt under ADR 0052.
  """

  use GenServer

  @call_timeout 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Refresh the grant on this node's queue. `:if_stale` serves the row when it
  is still fresh; `:force` refreshes regardless (the keepalive). A refresher
  that is down or slow answers `{:error, {:refresher, reason}}` rather than
  taking the caller with it.
  """
  @spec refresh(:if_stale | :force) :: {:ok, String.t()} | {:error, term()}
  def refresh(mode) when mode in [:if_stale, :force] do
    GenServer.call(__MODULE__, {:refresh, mode}, @call_timeout)
  catch
    :exit, reason -> {:error, {:refresher, reason}}
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:refresh, mode}, _from, state) do
    {:reply, Fountain.PlatformChatGPT.refresh_serialized(mode), state}
  end
end
