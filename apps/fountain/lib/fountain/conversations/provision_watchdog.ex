defmodule Fountain.Conversations.ProvisionWatchdog do
  @moduledoc """
  The absolute deadline on `ConversationServer`'s provisioning.

  It cannot live inside that server: a stuck `handle_continue(:provision)`
  blocks the mailbox, so a `send_after` (or a trapped exit signal) queues
  behind the very thing it is meant to bound. The watchdog is a separate
  process that, at the deadline, retires the machine through its owner — the
  provision path's own source of truth — and only if that row really was still
  being provisioned does it brutally kill the server. The sprite, if one was
  created, is picked up by SandboxReaper's untracked sweep. A monitor exits
  the watchdog quietly whenever the server stops first, which covers every
  success and ordinary-failure path.

  ## Two deadlines, and the order between them (ADR 0058 stage 7b)

  Since the provision runs under a machine lease, there are now two bounds on
  it and they are deliberately not the same number.

  The **lease's** deadline is the one that matters first.
  `Machines.Renewal` renews the provision's lease for as long as
  `deadline_ms/0` — the thirty minutes below — and then stops. From that moment
  the lease is merely expiring: the stuck server's own writes will fail their
  compare-and-set, and the row becomes claimable by the next owner. That is the
  mechanism; the watchdog is the thing that uses it.

  So this fires at `deadline_ms/0` **plus a grace**, and the grace is exactly
  what it takes for the lease to lapse once renewals stop. Without it the
  watchdog would arrive while the lease was still live, be refused by
  `Machine.fail_provision/2`, and have to choose between killing a server whose
  row was not terminal — which is the #394 bug, below — and doing nothing.

  **Rows before the kill, and the kill only if the rows landed** (#394). The
  server is `restart: :transient` and `:killed` is an abnormal exit, so a
  kill-first ordering let Horde restart it into `handle_continue(:provision)`
  while the row still said pending — and the restart re-provisioned a second
  billable sprite, then kept streaming into it while this stale struct's late
  "failed" write made the row lie about it. With the terminal status committed
  first, a restarted server stops at `Provision.admissible/1`. The ordering is
  now a *condition* rather than a sequence: a refused retire means the row is
  not terminal, so nothing is killed and the next pass — the reaper's
  `release_stuck_sandboxes/0` — is what collects it.
  """

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Output}
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Provision

  # Absolute ceiling on provisioning (#329). Generous against the summed
  # default step timeouts (packages 300s + clone 600s + setup 120s). Setup
  # may opt into up to 900s, but this overall ceiling still applies. It also
  # catches a step that stalls without raising — the case where
  # the row sat in `starting` holding a quota slot until the next deploy:
  # the reaper exempts rows whose server is alive, and the server's own
  # timers queue behind the stuck handle_continue. Overridable in tests.
  @provision_deadline_ms :timer.minutes(30)

  # How long after the provision's own deadline this fires. One lease TTL, plus
  # thirty seconds: once `Renewal` stops renewing at `deadline_ms/0`, the
  # longest a lease can still have to run is the TTL it was last extended by,
  # and the margin covers a renewal that landed a moment before the stop. See
  # the moduledoc for what would happen without it.
  @lapse_grace_ms Provision.lease_ttl_ms() + 30_000

  # How long the retire waits for a lease that should already be gone. Longer
  # than the protocol's own five seconds on purpose: this caller is not a
  # person, it has waited half an hour already, and the one thing it must not
  # do is give up early and leave a stuck server alive with a live row.
  #
  # A whole lease TTL past the grace above, so it covers the case where the
  # grace was not enough — a renewal that landed late, a clock the two disagree
  # about by seconds — without the watchdog having to be right about the
  # timing to be safe.
  @retire_wait_ms @lapse_grace_ms + Provision.lease_ttl_ms()

  @doc """
  The ceiling on one provision, in milliseconds.

  The lease's renewals stop here (`Machines.Renewal`'s `:deadline_ms`) and this
  watchdog fires `#{@lapse_grace_ms}`ms later. Overridable with
  `config :fountain, :provision_deadline_ms` — `conversation_server_provision_deadline_test.exs`
  is the only caller that does.
  """
  @spec deadline_ms() :: pos_integer()
  def deadline_ms do
    Application.get_env(:fountain, :provision_deadline_ms, @provision_deadline_ms)
  end

  @doc """
  How long after `deadline_ms/0` this fires. See the moduledoc.

  Public so `machine_bounds_test.exs` can pin it clear of the lease TTL it is
  waiting out. Overridable with `config :fountain, :provision_lapse_grace_ms`,
  which one test sets to zero so it can watch the real timer rather than
  deliver the message by hand; nothing in `lib/` or `config/` sets it.
  """
  @spec lapse_grace_ms() :: non_neg_integer()
  def lapse_grace_ms do
    Application.get_env(:fountain, :provision_lapse_grace_ms, @lapse_grace_ms)
  end

  @doc """
  How long the retire waits for a lease that should already be gone.

  The one bound in `lib/` that overrides a protocol's own, pinned by
  `machine_bounds_test.exs` rather than exempted quietly.
  """
  @spec retire_wait_ms() :: pos_integer()
  def retire_wait_ms, do: @retire_wait_ms

  @doc """
  Start the watchdog for the calling server. Returns the watchdog's pid.
  """
  @spec start(String.t(), String.t() | nil) :: pid()
  def start(conv_id, sandbox_id) do
    server = self()
    fires_in_ms = deadline_ms() + lapse_grace_ms()

    spawn(fn ->
      ref = Process.monitor(server)
      timer = Process.send_after(self(), :provision_deadline, fires_in_ms)

      receive do
        {:DOWN, ^ref, :process, ^server, _reason} ->
          Process.cancel_timer(timer)

        :provision_deadline ->
          Process.cancel_timer(timer)
          expire(conv_id, sandbox_id, server, fires_in_ms)
      end
    end)
  end

  # ownership: the two ids are the ones the ConversationServer was started
  # with, and it established ownership of both at init. The watchdog reads and
  # writes no row it was not handed.
  defp expire(conv_id, sandbox_id, server, fires_in_ms) do
    retired =
      Machine.fail_provision(sandbox_id,
        actor: "system:provision_watchdog",
        reason: :provision_deadline_exceeded,
        conversation_id: conv_id,
        busy_wait_ms: @retire_wait_ms
      )

    case retired do
      {:ok, :failed} ->
        Logger.error(
          "conv #{conv_id}: provisioning exceeded #{fires_in_ms}ms; " <>
            "failed the sandbox and killing the stuck server"
        )

        fail_conversation(conv_id)

        Output.publish_stage(conv_id, "provision", "failed", %{
          reason: "provision deadline exceeded"
        })

        kill(server)

        :telemetry.execute([:fountain, :provision, :deadline_exceeded], %{count: 1}, %{
          conversation_id: conv_id
        })

      # The row had already settled — the provision finished, or somebody else
      # retired it — and there is nothing here to bound. The monitor above
      # covers the ordinary case; this is the race where the two cross.
      {:ok, settled} when settled in [:already_terminal, :not_provisioning] ->
        :ok

      # The row is *not* terminal, so killing the server would be the #394
      # ordering inverted: a restart would find a live row and build a second
      # machine. Left for `SandboxReaper.release_stuck_sandboxes/0`, which
      # collects a row this old with no server alive.
      other ->
        Logger.error(
          "conv #{conv_id}: provisioning exceeded #{fires_in_ms}ms and the machine could not " <>
            "be retired (#{inspect(other)}); leaving the server alive rather than restarting " <>
            "it onto a live row"
        )
    end
  end

  defp fail_conversation(conv_id) do
    # ownership: `conv_id` is the one the `ConversationServer` this watchdog
    # belongs to was started with, and that server established its tenant at
    # `init/1`. The watchdog reads no row it was not handed.
    case Conversations._unsafe_get_conversation(conv_id) do
      %Conversation{status: status} = conv when status not in ["terminated", "failed"] ->
        Conversations.update_conversation(conv, %{status: "failed"})

      _ ->
        :ok
    end
  end

  # Prefer supervisor termination over Process.exit: it removes the child, so
  # no restart happens at all, and it bounds the wait — the server traps exits
  # and is stuck in a callback, so the :shutdown signal queues until the
  # child-spec shutdown timeout expires and the supervisor escalates to :kill.
  # terminate/2 still does not run for the stuck server; expires_at bounds the
  # un-revoked callback key, and the reaper reclaims the sprite. The fallback
  # covers a server not running under the supervisor (tests) or one that died
  # in the meantime.
  defp kill(server) do
    case Horde.DynamicSupervisor.terminate_child(Fountain.ConversationSupervisor, server) do
      :ok -> :ok
      {:error, _} -> Process.exit(server, :kill)
    end
  end
end
