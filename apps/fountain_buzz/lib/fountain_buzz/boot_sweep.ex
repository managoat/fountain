defmodule FountainBuzz.BootSweep do
  @moduledoc """
  Starts a harness for every enabled Buzz identity at boot (ADR 0020, gate #736).

  Mirrors `Fountain.Conversations.Rehydrator`: on start it sweeps the enabled
  identities and asks `FountainBuzz.Manager` to stand each one up. The sweep is a
  no-op unless `:buzz_acp_path` is configured — until the binary ships in the
  image (increment 2b) there is nothing to run, so this stays inert in dev, in
  test, and on any instance that has not opted in.

  Cluster safety comes from the registry, not from leader election: two nodes
  sweeping at once both call `Manager.start_harness/2`, and the second gets the
  first's pid back (the registry key is unique), so a double sweep converges to
  one harness per identity rather than two. The credential a losing race minted
  is revoked by `Manager`, not leaked.
  """
  use GenServer

  require Logger

  alias FountainBuzz, as: Buzz
  alias FountainBuzz.Manager

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether the sweep is enabled — i.e. a `buzz-acp` binary path is configured."
  def enabled?, do: FountainBuzz.Assets.compatible?()

  @doc """
  Start a harness for every enabled identity. Safe to call repeatedly
  (`Manager.start_harness/2` is idempotent). Returns the count started or found.
  """
  def run do
    # ownership: a system-level sweep across all tenants (like the rehydrator),
    # not a user-facing request — every identity's own user_id scopes the mint
    # and vault decrypt that `Manager.start_harness/2` performs downstream.
    Buzz._unsafe_list_enabled_identities()
    |> Enum.map(&start_one/1)
    |> Enum.count(&(&1 == :ok))
  end

  @impl true
  def init(opts) do
    {:ok, opts, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    if enabled?() do
      count = run()
      Logger.info("buzz boot sweep: started/verified #{count} harness(es)")
    else
      Logger.debug("buzz boot sweep: skipped (no :buzz_acp_path configured)")
    end

    {:noreply, state}
  end

  defp start_one(identity) do
    case Manager.start_harness(identity, actor: "system:buzz_boot_sweep") do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error("buzz boot sweep: identity=#{identity.id} failed: #{inspect(reason)}")
        :error
    end
  end
end
