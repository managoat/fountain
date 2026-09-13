defmodule Fountain.Conversations.Lifecycle do
  @moduledoc """
  How long a sandbox is allowed to run unattended, and what crossing each
  bound costs.

  Two bounds, both off by setting the value to `nil` or `0`:

  * **Idle timeout** — no turn activity for this long and the sandbox is
    **suspended**: the ConversationServer stops, the sprite stays alive at
    sprites.dev and scales itself to zero, and the sandbox row parks in
    `suspended`. The next prompt reattaches to the same sprite — same disk,
    same runtime session, so the agent keeps its memory of the conversation.
    This is the common case: someone starts a run, reads the answer, closes
    the tab. See decisions/0017.

  * **Max lifetime** — a ceiling on a *continuous run*, measured from the
    sandbox's creation or its last wake from `suspended`
    (`last_resumed_at || inserted_at`). Crossing it **destroys** an ephemeral
    sprite and **parks** a persistent home (ADR 0023). **Off by default since
    #936**: a tenant who wants a machine running 24/7 is not something to
    stop, so nothing automatic stops a sandbox that keeps itself busy — the
    idle timeout parks it once it stops, and the concurrent-sandbox cap
    bounds how many can be up. An operator who wants the old backstop sets
    `SANDBOX_MAX_LIFETIME_HOURS`.

  ## Why the split

  The original design (#233) destroyed the sprite on both bounds, on the
  premise that an idle sprite bills indefinitely. It doesn't — sprites scale
  to zero on their own — and #649 measured what the destroy costs: the
  runtime's session lives in the sandbox's filesystem, so resuming onto a new
  sprite fails on every path we have (`claude --resume` answers "No
  conversation found with session ID"; ACP `session/resume` answers `-32002
  Resource not found`). Fountain's own transcript survives either way — every
  `log_events` row still renders — but the agent's memory does not. So the
  idle bound, which exists for abandoned-not-runaway conversations, now parks
  instead of destroying, and only the max-lifetime ceiling still pays the
  #649 price. `explain/1` tells the user which one they got.

  Suspended sandboxes are never aged out — a parked sprite is treated as
  costing nothing (decisions/0017), and the disk it holds is the agent's
  memory.

  Setting the conversation itself to `terminated` on either bound would *not*
  be safe — it would make the conversation permanently unresumable, turning a
  cost control into data loss.

  ## Policy, then the actions

  The first half of this module is policy: `check/4`, `idle_action/1`,
  `explain/1,2` and the two bounds they read. Pure, and safe to ask from
  anywhere — the `ConversationServer` and `Workers.SandboxReaper` both do.

  The second half (#1376) is the consequence: the sandbox clock, the calls
  that park or destroy the machine, and what the co-tenants on it are told.
  They talk to the provider, the rows, the stream and the other servers, and
  they run inside a `ConversationServer` whose ownership of the conversation
  was established at `init/1`. The decision and its consequence sit in one
  file so a reader of `idle_action/1` can see what `:destroy` costs.
  """

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Egress
  alias Fountain.Conversations.HomeCheckpoint
  alias Managoat.Sandbox.Handle

  @default_idle_minutes 60
  @default_max_lifetime_hours 0

  # How often the sandbox lifetime bounds are evaluated. A minute is far finer
  # than the bounds themselves (an hour, a day), so the cost of the tick is
  # irrelevant and the overshoot is bounded by it.
  @check_ms :timer.minutes(1)

  @doc "Idle timeout in seconds, or `nil` when disabled."
  @spec idle_timeout_seconds() :: pos_integer() | nil
  def idle_timeout_seconds do
    to_seconds(
      Application.get_env(:fountain, :sandbox_idle_timeout_minutes, @default_idle_minutes),
      60
    )
  end

  @doc "Absolute sandbox lifetime in seconds, or `nil` when disabled."
  @spec max_lifetime_seconds() :: pos_integer() | nil
  def max_lifetime_seconds do
    to_seconds(
      Application.get_env(:fountain, :sandbox_max_lifetime_hours, @default_max_lifetime_hours),
      3600
    )
  end

  @doc """
  How long a held `ask` waits for a human before it is denied (#940).

  Read from `:permission_ask_timeout_seconds`; the default and the parsing
  are the ACP library's (`Managoat.ACP.Permissions.ask_timeout_ms/1`). Must
  sit under `idle_timeout_seconds/0`: a held request suppresses only the idle
  verdict, so one that outlived the idle bound would be resolved by the
  max-lifetime ceiling instead — which destroys the sandbox rather than
  parking it (0017). The timeout has to fire first for an unanswered prompt
  to cost a turn rather than the agent's memory; `lifecycle_test.exs` pins
  the bound.

  This is the bound for a request **held inside a turn**. A request that
  outlived its turn (#1635) holds nothing open, so the reasoning above does
  not reach it and its deadline may be days out; see
  `Fountain.Conversations.DetachedRequest`.

  Lived on `Fountain.Runtimes.ACP` until that module left for
  `Managoat.Runtimes` (#1368); it is the one thing there that read Fountain's
  configuration, and it belongs with the bound it has to stay under.
  """
  @spec ask_timeout_ms() :: pos_integer()
  def ask_timeout_ms do
    :fountain
    |> Application.get_env(:permission_ask_timeout_seconds)
    |> Managoat.ACP.Permissions.ask_timeout_ms()
  end

  defp to_seconds(nil, _unit), do: nil
  defp to_seconds(0, _unit), do: nil
  defp to_seconds(n, unit) when is_integer(n) and n > 0, do: n * unit

  defp to_seconds(n, unit) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> to_seconds(i, unit)
      :error -> nil
    end
  end

  defp to_seconds(_, _), do: nil

  @doc """
  Which bound, if any, a sandbox has crossed.

  Returns `{:expired, :idle | :max_lifetime}` or `:ok`. `busy?` suppresses only
  the idle verdict: a turn in flight is activity by definition, while the
  absolute ceiling exists precisely for the conversation that never stops being
  busy.
  """
  @spec check(DateTime.t(), DateTime.t(), boolean(), DateTime.t()) ::
          {:expired, :idle | :max_lifetime} | :ok
  def check(started_at, last_activity_at, busy?, now \\ DateTime.utc_now()) do
    max_lifetime = max_lifetime_seconds()
    idle = idle_timeout_seconds()

    cond do
      max_lifetime && DateTime.diff(now, started_at) >= max_lifetime ->
        {:expired, :max_lifetime}

      not busy? && idle && DateTime.diff(now, last_activity_at) >= idle ->
        {:expired, :idle}

      true ->
        :ok
    end
  end

  @doc """
  Human-readable reason, for the stage event a client sees on the stream.

  Worth spending words on: from the user's side the sandbox simply went away,
  and an explanation is the difference between a bug report and a shrug.

  The two bounds now promise different things and the copy must not blur
  them. A suspend keeps the sprite's disk, so the agent genuinely resumes
  with its memory; a max-lifetime reclaim destroys it, and the agent's
  context goes with it (#649). Telling someone "history is preserved" on the
  destroy path — or hedging on the suspend path — makes the true sentence
  discredit the other.
  """
  @spec explain(:idle | :max_lifetime) :: String.t()
  def explain(:idle), do: explain(:idle, :suspend)

  def explain(:max_lifetime) do
    "Sandbox reclaimed after reaching the #{hours(max_lifetime_seconds())} hour maximum " <>
      "lifetime. Send another prompt to continue — the transcript above is kept, but the " <>
      "agent starts a fresh session and will not remember the earlier turns."
  end

  @doc """
  What crossing the idle bound does on this provider.

  `:suspend` where the provider can park with the disk preserved (the
  `:suspend` capability); `:destroy` where it cannot — an idle sandbox on
  such a backend keeps billing, so the cost control wins over the agent's
  memory, exactly as the max-lifetime ceiling already prices it.

  This is the single place the degradation decision lives; the
  ConversationServer's idle reclaim and the reaper's park both consult it —
  the same change-both-together discipline as the clock in `check/4`.
  """
  @spec idle_action(atom()) :: :suspend | :destroy
  def idle_action(provider) when is_atom(provider) do
    if Managoat.Sandbox.supports?(provider, :suspend), do: :suspend, else: :destroy
  end

  @doc """
  The idle copy, by what actually happened. Same honesty rule as the two
  arms of `explain/1`: promise memory only where the disk survives.
  """
  @spec explain(:idle | :max_lifetime, :suspend | :destroy) :: String.t()
  def explain(:idle, :suspend) do
    "Sandbox suspended after #{minutes(idle_timeout_seconds())} minutes idle. " <>
      "Send another prompt to continue — the agent picks up right where it left off."
  end

  # A home at the ceiling is parked, not destroyed (ADR 0023): the disk stays,
  # the turn that was in flight does not.
  def explain(:max_lifetime, :suspend) do
    "Sandbox suspended after reaching the #{hours(max_lifetime_seconds())} hour maximum " <>
      "lifetime; a turn in flight was cut. Send another prompt to continue — the agent " <>
      "picks up right where it left off."
  end

  def explain(:idle, :destroy) do
    "Sandbox reclaimed after #{minutes(idle_timeout_seconds())} minutes idle. " <>
      "Send another prompt to continue — the transcript above is kept, but this sandbox " <>
      "provider cannot park an idle sandbox, so the agent starts a fresh session and " <>
      "will not remember the earlier turns."
  end

  @doc """
  The copy for a destroy, by the bound that reached it. `explain/2`'s
  destroy arms, named once so the two `publish_stage` fields agree.
  """
  @spec reclaim_message(:idle | :max_lifetime) :: String.t()
  def reclaim_message(:max_lifetime), do: explain(:max_lifetime)
  def reclaim_message(:idle), do: explain(:idle, :destroy)

  # ── the actions ───────────────────────────────────────────────────────────

  @doc """
  The provider tag for telemetry: read off the live handle, which was built
  from the sandbox row's provider column.
  """
  @spec provider(Handle.t() | nil) :: atom()
  def provider(%Handle{provider: provider}), do: provider
  def provider(_handle), do: :sprites

  @doc """
  When the sandbox's continuous run started.

  The absolute lifetime ceiling measures a continuous run, not calendar age:
  a wake from `suspended` stamps `last_resumed_at` and restarts the clock,
  while a deploy reattach of a `ready` row stamps nothing and keeps it.
  `SandboxReaper.expired?/2` must agree with this — change both together.
  """
  @spec clock_start(map()) :: DateTime.t() | NaiveDateTime.t()
  def clock_start(sandbox), do: sandbox.last_resumed_at || sandbox.inserted_at

  @doc """
  Arm the next lifecycle tick, in the calling process — the server.

  Interval overridable in tests so the timer wiring itself is testable —
  dropping this call from `ConversationServer.init/1` used to pass the whole
  suite (#337) while silently disabling idle/max-lifetime reclamation.
  """
  @spec schedule_check() :: reference()
  def schedule_check do
    interval = Application.get_env(:fountain, :lifecycle_check_ms, @check_ms)
    Process.send_after(self(), :lifecycle_check, interval)
  end

  @doc "Whether this machine is a persistent home (ADR 0023)."
  @spec home?(String.t() | nil) :: boolean()
  def home?(sandbox_id) when is_binary(sandbox_id) do
    # Ownership: the caller is the server for a conversation on this sandbox,
    # established at its init/1.
    match?(%{mode: "persistent"}, Conversations._unsafe_get_sandbox(sandbox_id))
  end

  def home?(_sandbox_id), do: false

  @doc """
  Whether a conversation other than this one holds the machine busy: mid-turn,
  or active more recently than the idle bound. One conversation going quiet is
  not the machine's verdict; that is reached over all of them (ADR 0023 step
  5).
  """
  @spec busy_elsewhere?(String.t() | nil, String.t()) :: boolean()
  def busy_elsewhere?(sandbox_id, conversation_id) do
    # Ownership: as home?/1 above.
    Conversations._unsafe_sandbox_busy_elsewhere?(
      sandbox_id,
      conversation_id,
      idle_timeout_seconds()
    )
  end

  @doc """
  Explicitly park the sandbox before the row flips: for Sprites this is a
  no-op (scale-to-zero), for pause/stop providers it is the call that stops
  the meter. Ordering matters — a row marked suspended with the backend still
  running would be invisible to every reclaim pass.
  """
  @spec suspend(Handle.t() | nil) :: :ok | {:error, term()}
  def suspend(nil), do: :ok
  def suspend(handle), do: Managoat.Sandbox.suspend(handle)

  @doc """
  What the idle bound does to this machine, the suspend call included.

  Park where the provider can preserve the disk (the `:suspend` capability —
  implicit scale-to-zero for Sprites, an explicit pause/stop for providers
  that need one), destroy where it cannot. The disk holds the runtime session
  — the agent's memory, which #649 proved cannot be rebuilt on a fresh
  sandbox — so parking is always preferred; but an idle sandbox that cannot
  park keeps billing, and a park *call* that fails leaves it billing too, so
  both of those degrade to the destroy arm. `idle_action/1` is the
  capability half of the decision.
  """
  @spec idle_machine_action(String.t(), Handle.t() | nil) :: :park | :destroy
  def idle_machine_action(conversation_id, handle) do
    with :suspend <- idle_action(provider(handle)),
         :ok <- suspend(handle) do
      :park
    else
      :destroy ->
        :destroy

      {:error, reason} ->
        Logger.warning(
          "suspend call failed for conv #{conversation_id} " <>
            "(#{inspect(reason)}); destroying instead — an unparked sandbox keeps billing"
        )

        :destroy
    end
  end

  @doc """
  Retire the machine of an authorized, terminated conversation with no actor.
  The conditional fence preserves homes and other live co-tenants, and blocks
  new attachments before the terminal write. No provider I/O runs here; the
  reaper handles terminal rows. The caller owns the conversation lifecycle
  audit; the fence records teardown intent using the supplied attribution.
  """
  def retire_terminated_sandbox(%{sandbox_id: nil}, _opts), do: :ok

  def retire_terminated_sandbox(conv, opts) do
    opts =
      opts
      |> Keyword.put(:terminating_conversation_id, conv.id)
      |> Keyword.put_new(:reason, "conversation_terminated")

    # ownership: this sandbox belongs to the conversation authorized by the caller.
    case Conversations._unsafe_get_sandbox(conv.sandbox_id) do
      nil ->
        {:error, :sandbox_unavailable}

      sandbox ->
        # ownership: the authorized conversation supplies this sandbox; the fence rechecks binding.
        case Conversations._unsafe_fence_sandbox_for_teardown(sandbox, opts) do
          {:ok, %{status: status}} when status in ["terminated", "failed"] ->
            :ok

          {:ok, fenced} ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)

            with {:ok, _} <-
                   Conversations.update_sandbox(fenced, %{
                     status: "terminated",
                     terminated_at: now
                   }) do
              :ok
            end

          {:error, :sandbox_kept} ->
            :ok

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  What the max-lifetime ceiling does to this machine, the suspend call
  included.

  Tear down, whatever the provider. This bound exists for the conversation
  that never stops being busy; the conversation stays `idle` and resumable —
  setting it `terminated` would make a cost control into data loss.

  A home is parked instead, where the provider can park: its disk is the
  agent's memory across every conversation, and destroying it at a busy
  ceiling would defeat the mode (ADR 0023 step 5). The ceiling itself is
  slated to go; until then this is the interim it names. A home on a provider
  that cannot park, or whose park call fails, is destroyed as an ephemeral one
  would be — an unparked machine keeps billing.
  """
  @spec max_lifetime_action(String.t() | nil, Handle.t() | nil) :: :park | :destroy
  def max_lifetime_action(sandbox_id, handle) do
    with true <- home?(sandbox_id),
         :suspend <- idle_action(provider(handle)),
         :ok <- suspend(handle) do
      :park
    else
      _ -> :destroy
    end
  end

  @doc """
  Park the machine: the sandbox row to `suspended`, the conversation back to
  `idle`, the stage event, the telemetry and the co-tenants. The suspend call
  itself has already been made by whichever action decided on `:park`.
  """
  @spec park(String.t(), String.t() | nil, Handle.t() | nil, :idle | :max_lifetime) :: :ok
  def park(conversation_id, sandbox_id, handle, reason) do
    case park_row(sandbox_id) do
      :ok -> finish_park(conversation_id, sandbox_id, handle, reason)
      :skipped -> :ok
    end
  end

  defp park_row(nil), do: :ok

  defp park_row(sandbox_id) do
    # Ownership: as home?/1 above. Recheck after the provider checkpoint:
    # retirement or a reset fence can win while that call is in flight.
    sandbox = Conversations._unsafe_get_sandbox!(sandbox_id)

    if sandbox.status in ["terminated", "failed"] or not is_nil(sandbox.reset_requested_at) do
      :skipped
    else
      HomeCheckpoint.on_park(sandbox)

      case Conversations.update_sandbox(sandbox, %{status: "suspended"}) do
        {:ok, _} -> :ok
        {:error, %Ecto.Changeset{errors: [status: {"sandbox is retired", []}]}} -> :skipped
        {:error, :sandbox_reset_pending} -> :skipped
        error -> raise MatchError, term: error
      end
    end
  end

  defp finish_park(conversation_id, sandbox_id, handle, reason) do
    # The conversation stays idle and resumable; the sprite stays parked.
    conv = Conversations._unsafe_get_conversation!(conversation_id)
    if conv.status == "running", do: Conversations.update_conversation(conv, %{status: "idle"})

    # Same stage/state as the reclaim below (LogEvent's state set is closed and
    # clients already key on the "sandbox" stage); `event` is the discriminator.
    Conversations.publish_stage(conversation_id, "sandbox", "done", %{
      event: "suspended",
      reason: to_string(reason),
      message: explain(reason, :suspend)
    })

    :telemetry.execute([:fountain, :sandbox, :suspended], %{count: 1}, %{
      provider: provider(handle)
    })

    stop_cotenants(
      sandbox_id,
      conversation_id,
      "suspended",
      to_string(reason),
      explain(reason, :suspend)
    )
  end

  @doc """
  Fence admission before the server closes its adapter or destroys the machine.
  The caller owns the sandbox through its conversation, as in `home?/1`.
  Refuses an enclosing transaction; a successful fence commits before returning.
  Already-admitted turns may still be interrupted by this forced reclaim.
  """
  @spec prepare_destroy(String.t() | nil, :idle | :max_lifetime) :: :ok | {:error, term()}
  def prepare_destroy(sandbox_id, reason) do
    cond do
      Fountain.Repo.in_transaction?() ->
        {:error, :provider_transaction_open}

      is_nil(sandbox_id) ->
        :ok

      true ->
        with %Conversations.Sandbox{} = sandbox <- Conversations._unsafe_get_sandbox(sandbox_id),
             {:ok, _} <-
               Conversations._unsafe_fence_sandbox_for_teardown(sandbox,
                 actor: "system:conversation_server",
                 reason: to_string(reason)
               ) do
          :ok
        else
          nil -> {:error, :not_found}
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  Tear down the sandbox; the conversation stays `idle` and resumable (setting
  it `terminated` here would make a cost control into data loss). Serves both
  the max-lifetime ceiling and the idle bound on a provider that cannot park.
  """
  @spec destroy(
          String.t(),
          String.t() | nil,
          Handle.t() | nil,
          :idle | :max_lifetime
        ) :: :ok | {:error, term()}
  def destroy(conversation_id, sandbox_id, handle, reason) do
    # The server prepares before closing its adapter. Check again here for
    # direct callers; an existing fence adds no second request event.
    with :ok <- prepare_destroy(sandbox_id, reason) do
      do_destroy(conversation_id, sandbox_id, handle, reason)
    end
  end

  defp do_destroy(conversation_id, sandbox_id, handle, reason) do
    if handle, do: _ = Managoat.Sandbox.destroy(handle)
    Egress.release(conversation_id)

    if sandbox_id do
      # Ownership: as home?/1 above.
      sandbox = Conversations._unsafe_get_sandbox!(sandbox_id)

      if sandbox.status not in ["terminated", "failed"] do
        {:ok, _} =
          Conversations.update_sandbox(sandbox, %{
            status: "terminated",
            terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
      end
    end

    conv = Conversations._unsafe_get_conversation!(conversation_id)
    if conv.status == "running", do: Conversations.update_conversation(conv, %{status: "idle"})

    # `state` is a stage-lifecycle vocabulary — LogEvent allows only
    # started/done/failed/interrupted, and both the CLI and the LiveView switch
    # on it. A reclaimed sandbox is a stage that reached its end, so "done" is
    # accurate and needs no client to learn a new word; the `reason` and
    # `message` fields carry what actually happened.
    Conversations.publish_stage(conversation_id, "sandbox", "done", %{
      event: "reclaimed",
      reason: to_string(reason),
      message: reclaim_message(reason)
    })

    :telemetry.execute([:fountain, :sandbox, :reclaimed], %{count: 1}, %{
      reason: reason,
      provider: provider(handle)
    })

    stop_cotenants(
      sandbox_id,
      conversation_id,
      "reclaimed",
      to_string(reason),
      reclaim_message(reason)
    )
  end

  @doc """
  A park or a destroy is a machine operation: every other conversation on the
  sandbox loses its handle with it. Tell their servers, so each records what
  happened on its own transcript and stops — the next prompt then takes the
  wake path, the only path that brings the machine back. A cast: a co-tenant
  whose server is already gone is not an error here.
  """
  @spec stop_cotenants(String.t() | nil, String.t(), String.t(), String.t(), String.t()) :: :ok
  def stop_cotenants(sandbox_id, conversation_id, event, reason, message) do
    # Ownership: as home?/1 above.
    sandbox_id
    |> Conversations._unsafe_list_cotenant_ids(conversation_id)
    |> Enum.each(fn conv_id ->
      case ConversationServer.whereis(conv_id) do
        nil -> :ok
        pid -> GenServer.cast(pid, {:machine_gone, event, reason, message})
      end
    end)
  end

  defp minutes(nil), do: "?"
  defp minutes(seconds), do: div(seconds, 60)
  defp hours(nil), do: "?"
  defp hours(seconds), do: div(seconds, 3600)
end
