defmodule FountainBuzz.Workers.HarnessSweep do
  @moduledoc """
  Stops a hosted Buzz agent's harness when its tenant runs out of credit, and
  starts it again when they top up (#1017).

  ## Why this exists at all

  A `Identity` is not a row. Each enabled one is a supervised `buzz-acp`
  **OS process** on Fountain's own pods (`FountainBuzz.Harness`, ADR 0020),
  holding an Erlang port, a live relay connection and a long-lived API key. It
  runs whether or not anyone ever mentions the agent, so the cost is
  **standing, not usage**, and `Fountain.Machines.Usage` reports zero for
  it: a harness is not a sandbox on any provider, and every existing meter
  measures sandboxes.

  So the balance could reach zero with the harnesses still up, and
  `FountainBuzz.BootSweep` would stand every one of them back up on the next
  deploy. Under ADR 0031 the gate is the balance, and nothing was applying it
  to the one cost that is invisible to the meters.

  ## Park, do not destroy

  A tenant who fails `Billing.check_spend/1` has their harnesses **stopped**,
  and the identity rows keep `enabled: true`. That mirrors how ADR 0017 parks
  an idle sandbox rather than destroying it: the account is out of credit, not
  gone, and a top-up should bring the agent back exactly as it was rather than
  ask the provider to deploy it again. The sweep is symmetric for that reason
  — it starts a harness whose tenant can spend again, which is also the
  self-healing path for a harness that lost a race or died on a drained node.

  Setting `enabled: false` is the tenant's own lever and this worker never
  touches it. A disabled identity is a decision; a stopped harness is a
  balance.

  ## Reading the gate

  `check_spend/1` is `:ok` with billing off, for a comped account, or on a
  positive balance, so a deployment with `CREDITS_ENABLED` unset sweeps
  nothing and every harness stays up. The tenants are asked once each rather
  than once per identity — an account with several agents is one query, not
  several.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias FountainBuzz, as: Buzz
  alias FountainBuzz.{BootSweep, Manager}

  @impl Oban.Worker
  def perform(_job) do
    %{stopped: stopped, started: started} = run()

    Logger.info("buzz harness sweep: stopped=#{stopped} started=#{started}")

    :telemetry.execute(
      [:fountain, :buzz_harness_sweep, :run],
      %{stopped: stopped, started: started},
      %{}
    )

    :ok
  end

  @doc """
  Reconcile every enabled identity's harness against its tenant's balance.

  Returns `%{stopped: n, started: n}`. A no-op unless a `buzz-acp` binary is
  configured — with none there is no harness to stop, and `BootSweep.enabled?/0`
  is the same question this asks.
  """
  @spec run() :: %{stopped: non_neg_integer(), started: non_neg_integer()}
  def run do
    if BootSweep.enabled?() do
      # ownership: a system-level sweep across all tenants, like the boot
      # sweep and the sandbox reaper. Each identity's own user_id scopes the
      # gate below and the mint that `start_harness/2` performs downstream.
      identities = Buzz._unsafe_list_enabled_identities()

      may_spend =
        identities
        |> Enum.map(& &1.user_id)
        |> Enum.uniq()
        |> Map.new(&{&1, Fountain.Billing.check_spend(&1) == :ok})

      Enum.reduce(identities, %{stopped: 0, started: 0}, fn identity, acc ->
        reconcile(identity, Map.get(may_spend, identity.user_id, true), acc)
      end)
    else
      %{stopped: 0, started: 0}
    end
  end

  defp reconcile(identity, may_spend?, acc) do
    case {may_spend?, Manager.running?(identity.id)} do
      {false, true} ->
        :ok = Manager.stop_harness(identity.id)

        Logger.info(
          "buzz harness sweep: stopped #{identity.id} (user #{identity.user_id} cannot spend)"
        )

        %{acc | stopped: acc.stopped + 1}

      {true, false} ->
        case Manager.start_harness(identity) do
          {:ok, _pid} ->
            %{acc | started: acc.started + 1}

          {:error, reason} ->
            Logger.warning(
              "buzz harness sweep: could not start #{identity.id}: #{inspect(reason)}"
            )

            acc
        end

      _ ->
        acc
    end
  end
end
