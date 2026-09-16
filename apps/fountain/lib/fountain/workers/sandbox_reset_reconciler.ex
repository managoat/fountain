defmodule Fountain.Workers.SandboxResetReconciler do
  @moduledoc """
  Retry fenced sandbox deletions without releasing capacity on an uncertain result.

  The scheduled sweep discovers fences left by errors or lost callers. Each
  sandbox gets one durable job; Oban backs off failed deletes independently.
  A discarded job becomes eligible on a later sweep, so an extended provider
  outage never makes a fence permanent. Disabled providers wait for credentials.

  The sweep itself is enqueued by the Oban cron entry in `config/config.exs`
  (`*/5 * * * *`), which is the only thing that runs the bare-args clause; the
  per-sandbox jobs it inserts are the other clause.

  Since ADR 0058 stage 5c the delete goes through the machine's owner, and both
  the sweep and the retry skip a machine whose owner holds a live lease. This
  worker is a reconciler for resets nobody is finishing, and a fenced row is
  not evidence that nobody is: a *forced* teardown stamps `reset_requested_at`
  too, so before the lease existed this sweep could reach a machine another
  destroy was halfway through and call the provider beside it.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sandbox_id" => id}}) do
    case Repo.get(Sandbox, id) do
      %Sandbox{mode: "persistent", status: status, reset_requested_at: at} = sandbox
      when status in ["ready", "suspended"] and not is_nil(at) ->
        if Fountain.SandboxProviders.enabled?(Conversations.sandbox_provider_atom(sandbox)) do
          case Conversations.retry_pending_sandbox_reset(sandbox,
                 actor: "system:sandbox_reset_reconciler"
               ) do
            {:ok, _} ->
              :ok

            # Not a failed delete: another teardown of this machine holds its
            # lease and this job has nothing to reconcile yet (ADR 0058 stage
            # 5c). Snoozing rather than erroring keeps the job's `max_attempts`
            # for the thing they are for — a provider that will not confirm —
            # so contention, which stage 6 makes ordinary, cannot exhaust a job
            # into `discarded` without a single provider call being made. The
            # sweep's own guard keeps most of these out of the queue; this is
            # the one that arrives after the lease is taken.
            {:error, :sandbox_unavailable} ->
              {:snooze, 60}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:snooze, 300}
        end

      _ ->
        :ok
    end
  end

  def perform(%Oban.Job{args: %{}}) do
    now = DateTime.utc_now()

    from(s in Sandbox,
      where:
        s.mode == "persistent" and s.status in ["ready", "suspended"] and
          not is_nil(s.reset_requested_at),
      select: %{id: s.id, lease_node: s.lease_node, lease_until: s.lease_until}
    )
    # A machine whose owner holds a live lease is not a lost caller; it is a
    # destroy in flight (ADR 0058 stage 5c), and this sweep exists for the
    # ones nobody is working on. Mirrors
    # `SandboxReaper.sweep_fenced_teardowns/0`'s guard and the same guard in
    # `Conversations.retry_pending_sandbox_reset/2`, which is the door this
    # worker's per-sandbox job goes through and the one that actually decides.
    # Here it keeps the job out of the queue in the first place, so a sweep
    # over a contended fleet does not enqueue work that will only refuse.
    #
    # A *forced* teardown also stamps `reset_requested_at` (the teardown fence
    # reuses the reset fence), so rows this sweep sees include machines being
    # destroyed outright, not only resets — which is exactly the race this
    # guard closes.
    #
    # Asked through `Lease.live?/2` since ADR 0058 stage 6a, which is why the
    # query selects the two lease columns beside the id: one predicate, one
    # clock, rather than this module's own SQL rendering of it. The rows it
    # loads and drops are the contended ones, which the guard was going to drop
    # anyway.
    |> Repo.all()
    |> Enum.reject(&Lease.live?(&1, now))
    |> Enum.reduce_while(:ok, fn %{id: id}, :ok ->
      case %{sandbox_id: id} |> new() |> Oban.insert() do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
