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
  first, a restarted server stops at `Provision.admissible/1`.

  ## A refused retire, and why it is bounded (round 1)

  The ordering above turns #394 into a *condition*: a retire the owner refuses
  means the row is not terminal, so killing would be the old bug. The first
  draft stopped there — do nothing, and leave the row to
  `SandboxReaper.release_stuck_sandboxes/0`.

  **That pass cannot collect this row**, and both reviewers proved it. It ends
  in `Enum.reject(&Lifecycle.any_server_alive?/1)` (`sandbox_reaper.ex`), and
  the whole reason this watchdog exists is a server wedged alive inside
  `handle_continue(:provision)` — which the refusal arm then deliberately keeps
  alive. So "leave it for the reaper" named a backstop excluded by the very
  condition this module creates: row `starting`, an active-status quota slot
  held, the conversation `pending`, until the next deploy. That is verbatim the
  failure #329 exists to prevent, and it is not reachable on `main`, which
  killed unconditionally at thirty minutes.

  So a refusal is **retried**, at `retire_retry_ms/0`, up to
  `max_retire_attempts/0` times in all — and then the ceiling falls back to
  `main`'s: the server is stopped even though the row is live. The three
  reachable refusals are a lock held for the whole wait, a database fault, and
  `{:ok, :claimed_elsewhere}` — a genuine takeover, where the row is somebody
  else's and the only thing left to collect is this orphan server. Retrying
  clears the first two. For the third, and for a fault that does not clear,
  stopping the server is what makes `release_stuck_sandboxes/0` able to see the
  row at all, and it is done through the supervisor (`kill/1`), which *removes*
  the child rather than letting Horde restart it — so the #394 restart does not
  happen even though the row is not terminal.

  The bound is therefore `max_retire_attempts/0 × retire_wait_ms/0 +
  (max_retire_attempts/0 - 1) × retire_retry_ms/0` past the ceiling — **about
  sixteen and a half minutes** on the defaults, where an earlier draft said five
  (round 2) and then wrote an expression for seventeen and a half (round 3).
  Both terms count and neither is a whole multiple: `attempt <
  max_retire_attempts/0` gives four waits of `retire_retry_ms/0` *between* five
  attempts, and each of the five also spends up to `retire_wait_ms/0`
  busy-waiting for the lease before it refuses — which the refusal that matters,
  a genuine takeover, burns in full. Still finite, and still the difference
  between minutes and the next deploy.
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

  # How long a refused retire waits before asking again, and how many times it
  # asks. A minute is long enough that a lock or a database fault has a real
  # chance to clear between attempts and short enough that five of them is five
  # minutes rather than an hour — so a wedged server outlives the ceiling by
  # minutes, not until the next deploy. Overridable, and only tests do.
  @retire_retry_ms 60_000
  @max_retire_attempts 5

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
  How long a refused retire waits before asking again.

  Overridable with `config :fountain, :provision_retire_retry_ms`;
  `conversation_server_provision_deadline_test.exs` sets it to zero so it can
  drive the re-arm without waiting minutes. Nothing in `lib/` or `config/` sets
  it.
  """
  @spec retire_retry_ms() :: non_neg_integer()
  def retire_retry_ms do
    Application.get_env(:fountain, :provision_retire_retry_ms, @retire_retry_ms)
  end

  @doc "How many times a refused retire is asked again before the server is stopped anyway."
  @spec max_retire_attempts() :: pos_integer()
  def max_retire_attempts, do: @max_retire_attempts

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

      await(%{
        conv_id: conv_id,
        sandbox_id: sandbox_id,
        server: server,
        monitor: ref,
        timer: timer,
        fires_in_ms: fires_in_ms,
        attempt: 1
      })
    end)
  end

  # The watchdog's whole life: wait for the deadline or for the server to stop
  # first, and — since the retire can be refused — be prepared to come back.
  defp await(%{monitor: ref, server: server, timer: timer} = state) do
    receive do
      {:DOWN, ^ref, :process, ^server, _reason} ->
        Process.cancel_timer(timer)

      :provision_deadline ->
        Process.cancel_timer(timer)

        case expire(state) do
          :done ->
            :ok

          :retry ->
            await(%{
              state
              | timer: Process.send_after(self(), :provision_deadline, retire_retry_ms()),
                attempt: state.attempt + 1
            })
        end
    end
  end

  # ownership: the two ids are the ones the ConversationServer was started
  # with, and it established ownership of both at init. The watchdog reads and
  # writes no row it was not handed.
  defp expire(%{conv_id: conv_id, sandbox_id: sandbox_id} = state) do
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
          "conv #{conv_id}: provisioning exceeded #{state.fires_in_ms}ms; " <>
            "failed the sandbox and killing the stuck server"
        )

        fail_conversation(conv_id)

        Output.publish_stage(conv_id, "provision", "failed", %{
          reason: "provision deadline exceeded"
        })

        kill(state.server)

        :telemetry.execute([:fountain, :provision, :deadline_exceeded], %{count: 1}, %{
          conversation_id: conv_id
        })

        :done

      # The row had already settled — the provision finished, or somebody else
      # retired it — and there is nothing here to bound. The monitor in
      # `await/1` covers the ordinary case; this is the race where the two
      # cross.
      {:ok, settled} when settled in [:already_terminal, :not_provisioning] ->
        :done

      # The row is *not* terminal, so killing now would be the #394 ordering
      # inverted. Ask again shortly: a lock held for the whole wait and a
      # database fault both clear on their own, and a takeover settles the row
      # under somebody else.
      other when state.attempt < @max_retire_attempts ->
        Logger.warning(
          "conv #{conv_id}: provisioning exceeded #{state.fires_in_ms}ms and the machine could " <>
            "not be retired (#{inspect(other)}); attempt #{state.attempt} of " <>
            "#{@max_retire_attempts}, asking again in #{retire_retry_ms()}ms"
        )

        :retry

      # Out of attempts. `main`'s ceiling, restored: the server is stopped
      # although the row is live, because a wedged server is the one thing that
      # keeps `SandboxReaper.release_stuck_sandboxes/0` from ever seeing this
      # row (it rejects rows whose server is alive). The stop goes through the
      # supervisor, which removes the child — so nothing restarts onto the live
      # row, which is what #394 was actually about.
      #
      # **Whether the conversation is failed with it depends on who holds the
      # row** (round 2, protocol review), and the two cases really are
      # different:
      #
      #   * `{:ok, :claimed_elsewhere}` — another owner has the machine and is
      #     very likely building *this* conversation's. Failing it would mark a
      #     live conversation dead while its machine comes up, which is the one
      #     thing the stand-down arms exist to prevent. Left alone.
      #   * `{:error, _}` — this owner could not reach the row at all: a lock
      #     held for every wait, or a database fault. Nobody else is finishing
      #     this conversation, and `release_stuck_sandboxes/0` fails the
      #     *sandbox* row only, so leaving it would strand a `pending`
      #     conversation with no server and nothing that resolves it. Failed,
      #     as `main` did unconditionally.
      #
      # The distinction is exactly the one `Machine.fail_provision/2` already
      # draws, which is why it is available here for free.
      #
      # **`provision/failed` goes with the row write, not beside it** (round 3,
      # surfaces review). The first draft decided about the conversation and
      # then published unconditionally, which left the `:claimed_elsewhere` arm
      # announcing a terminal outcome on the very conversation it had just
      # decided to keep alive — and `provision`/`failed` *is* terminal to a
      # client: `cli/internal/acp/prompt.go` ends the turn with "the sandbox
      # never started" on it. So a CLI or an editor streaming that conversation
      # aborted the prompt while the successor's machine was coming up. Every
      # other stand-down in this tree announces nothing, `FreshProvision`'s
      # included; this one does now too.
      other ->
        Logger.error(
          "conv #{conv_id}: provisioning exceeded #{state.fires_in_ms}ms and the machine could " <>
            "not be retired after #{@max_retire_attempts} attempts (#{inspect(other)}); " <>
            "stopping the server anyway so the reaper can collect the row"
        )

        if held_by_another_owner?(other) do
          Logger.info(
            "conv #{conv_id}: leaving the conversation alone; another owner holds its machine"
          )
        else
          fail_conversation(conv_id)

          Output.publish_stage(conv_id, "provision", "failed", %{
            reason: "provision deadline exceeded; the machine could not be retired"
          })
        end

        kill(state.server)

        :telemetry.execute([:fountain, :provision, :deadline_exceeded], %{count: 1}, %{
          conversation_id: conv_id
        })

        :done
    end
  end

  # `Machine.fail_provision/2` answers `{:ok, :claimed_elsewhere}` when the
  # machine is somebody else's and `{:error, _}` when it could not be reached.
  defp held_by_another_owner?({:ok, :claimed_elsewhere}), do: true
  defp held_by_another_owner?(_other), do: false

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
