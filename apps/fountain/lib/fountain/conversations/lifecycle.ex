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

  Since ADR 0058 stage 5, the destroy half of that consequence is not written
  here: `destroy/4` asks `Fountain.Machines.Machine.destroy/2` for the machine
  and keeps only the conversation's side of a reclaim. The park half still is,
  until stage 6.

  ## The teardown fence

  This module also owns the forced-teardown admission fence
  (`fence_sandbox_for_teardown/2`) and the one predicate it decides
  `:sandbox_kept` by (`_unsafe_sandbox_held_by_other?/2`, ADR 0023) — moved
  here from `Fountain.Conversations` in #2258. It is a rule about the
  machine, not a conversation verb, and this module already is one of its
  callers (`prepare_destroy/2`); `Termination`, `Accounts.Deletion` and the
  destroy-home path call it, they do not own it.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.Egress
  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Occupancy
  alias Fountain.Machines.Policy
  alias Fountain.Repo
  alias Managoat.Sandbox.Handle

  @default_idle_minutes 60
  @default_max_lifetime_hours 0

  # Advisory-lock namespace for per-sandbox machine operations — must match
  # `Fountain.Conversations`' own `@sandbox_lock_namespace` (4316); every
  # module that takes this lock hardcodes the same integer rather than
  # sharing the attribute, since module attributes do not cross a module
  # boundary (`conversations/launch.ex`, `conversations/execution_guard.ex`,
  # `conversations/sandbox_identity.ex` do the same).
  @sandbox_lock_namespace 4316

  # Sandbox statuses a fence never reopens — must match
  # `Fountain.Conversations`' own `@billable_terminal`, for the same reason.
  @billable_terminal ~w(terminated failed)

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

  The decision itself moved to `Fountain.Machines.Policy.idle_action/1` in ADR
  0058 stage 7a, with the rest of what the two modes mean; this is the name the
  ConversationServer's idle reclaim, the reaper's park and `Machines.Park`'s
  recheck under the lease have always called it by, and it still is.
  """
  @spec idle_action(atom()) :: :suspend | :destroy
  defdelegate idle_action(provider), to: Fountain.Machines.Policy

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
    # established at its init/1. The query is here; the rule it feeds is
    # `Machines.Policy.home?/1` (stage 7a), which the fence and the ceiling
    # both read through.
    Policy.home?(Conversations._unsafe_get_sandbox(sandbox_id))
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
  What the idle bound does to this machine.

  Park where the provider can preserve the disk (the `:suspend` capability —
  implicit scale-to-zero for Sprites, an explicit pause/stop for providers
  that need one), destroy where it cannot. The disk holds the runtime session
  — the agent's memory, which #649 proved cannot be rebuilt on a fresh
  sandbox — so parking is always preferred; but an idle sandbox that cannot
  park keeps billing, so that degrades to the destroy arm.

  **The suspend call is no longer made here** (ADR 0058 stage 6b). This
  function once asked the provider to suspend and answered `:destroy` when the
  call failed, which meant the decision, the provider round trip and the row
  write happened in three different modules with nothing held across them —
  #2307. The call now happens inside `Fountain.Machines.Park`, under the
  machine's lease and after a recheck, and the *same* degradation is reached
  from the other end: the protocol answers `{:error, :suspend_failed}` and the
  caller destroys instead. What is left here is the capability half, which is
  a pure question about the provider and needs no lease to answer — and
  `Park` asks it again under one anyway, because a pre-lease verdict is stale
  by construction.
  """
  @spec idle_machine_action(Handle.t() | nil) :: :park | :destroy
  # `home?: false` and it does not matter which: the idle bound parks a home and
  # an ephemeral machine alike, because the disk is the agent's memory whatever
  # the mode (#649). `Policy.reclaim_action/3`'s table says so in one place.
  def idle_machine_action(handle), do: Policy.reclaim_action(:idle, provider(handle), false)

  @doc """
  The whole idle verdict for a conversation server: `:keep` the machine,
  `:park` it, or `:destroy` it.

  `:keep` is `busy_elsewhere?/2` — this conversation is idle and the machine is
  not, because another conversation on it is mid-turn or was active more
  recently than the bound. The verdict is the machine's, reached over all of
  them (ADR 0023 step 5), and the next tick asks again.

  It is decided here rather than in the server for the reason the rest of this
  module exists (#1376): the server owns its transcript, its adapter and its
  turn state machine, and the lifecycle policy is not any of those. The owner
  re-asks the same question under the lease and can still answer
  `:machine_occupied`; this one keeps the server from dropping its connection
  to find that out on every tick of a machine somebody else is using.
  """
  @spec idle_machine_action(String.t(), String.t() | nil, Handle.t() | nil) ::
          :keep | :park | :destroy
  def idle_machine_action(conversation_id, sandbox_id, handle) do
    if busy_elsewhere?(sandbox_id, conversation_id),
      do: :keep,
      else: idle_machine_action(handle)
  end

  @doc """
  What the max-lifetime ceiling does to this machine.

  Tear down, whatever the provider. This bound exists for the conversation
  that never stops being busy; the conversation stays `idle` and resumable —
  setting it `terminated` would make a cost control into data loss.

  A home is parked instead, where the provider can park: its disk is the
  agent's memory across every conversation, and destroying it at a busy
  ceiling would defeat the mode (ADR 0023 step 5). The ceiling itself is
  slated to go; until then this is the interim it names. A home on a provider
  that cannot park is destroyed as an ephemeral one would be — an unparked
  machine keeps billing — and so is one whose park call fails, which is now
  the protocol's answer rather than this function's. See
  `idle_machine_action/1`.
  """
  @spec max_lifetime_action(String.t() | nil, Handle.t() | nil) :: :park | :destroy
  def max_lifetime_action(sandbox_id, handle),
    do: Policy.reclaim_action(:max_lifetime, provider(handle), home?(sandbox_id))

  @doc """
  Park the machine a conversation server has decided to give up: the machine
  through its owner, then the conversation back to `idle`, the stage event and
  the telemetry.

  The server-side wrapper around `Fountain.Machines.Park`, which owns
  everything that touches the machine — the lease, the recheck under it, the
  checkpoint, the suspend, the row write, the `sandbox.suspended` event and the
  notice to the machine's other conversations. What is left here is what is
  the *conversation's*: its own status, its transcript and the telemetry tag
  taken off the live handle.

  `nil` for `sandbox_id` is a conversation with no machine to park, and it
  still finishes: the stage event is what the client is waiting for, and there
  is nothing for an owner to do. Same as `main`'s `park_row(nil)`.

  The answers:

    * `:ok` — parked, or already parked by somebody else. Either way the
      machine is at rest and the conversation should say so.
    * `{:error, :suspend_failed}` / `{:error, :cannot_park}` — the machine
      cannot be parked. The caller destroys instead: an unparked machine keeps
      billing (ADR 0017).
    * `{:error, :machine_occupied}` — somebody else is on the machine. Neither
      parked nor destroyed; the next tick asks again.
    * any other `{:error, _}` — a refusal to act on right now. The server logs
      it and keeps the machine, exactly as a refused destroy already does.

  A terminal row answers `:ok` and writes nothing, and so does a fenced one —
  which is what `main` did with `park_row/1`'s `:skipped`. A machine somebody
  else has finished, or is in the middle of finishing, is not this
  conversation's news to publish.
  """
  @spec park(String.t(), String.t() | nil, Handle.t() | nil, :idle | :max_lifetime) ::
          :ok | {:error, term()}
  def park(conversation_id, nil, handle, reason),
    do: finish_park(conversation_id, handle, reason)

  def park(conversation_id, sandbox_id, handle, reason) do
    case Machine.park(sandbox_id,
           actor: "system:conversation_server",
           reason: reason,
           # Excluded from the owner's occupancy check, the way
           # `busy_elsewhere?/2` excludes it here: a server parking the machine
           # it is bound to is not a reason to call that machine busy.
           requesting_conversation_id: conversation_id,
           # The wording is the caller's, and this caller has always had one.
           notify: {conversation_id, "suspended", to_string(reason), explain(reason, :suspend)}
         ) do
      {:ok, outcome} when outcome in [:parked, :already_parked] ->
        finish_park(conversation_id, handle, reason)

      # Somebody else has stopped this machine, or is about to: a terminal row,
      # or a reset or teardown fence on a live one. Nothing to park and nothing
      # to say — `main` reached the same answer through `park_row/1`'s
      # `:skipped`, and the server stops either way rather than ticking at a
      # machine somebody else owns the end of.
      {:ok, :already_terminal} ->
        :ok

      {:error, :fenced} ->
        :ok

      # The owner found an abandoned park on a machine that is still running
      # and cleared it. Nothing was parked, so this is not a park — the next
      # tick decides again, on a row that now says what it means.
      {:ok, :recovered} ->
        {:error, :recovered}

      {:error, _} = error ->
        error
    end
  end

  defp finish_park(conversation_id, handle, reason) do
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

    :ok
  end

  @doc """
  Fence admission before the server closes its adapter.
  The caller owns the sandbox through its conversation, as in `home?/1`.
  Refuses an enclosing transaction; a successful fence commits before returning.
  Already-admitted turns may still be interrupted by this forced reclaim.

  A pre-check, not the fence of record: `destroy/4` reaches the same fence
  through `Machine.destroy/2`, and a repeat adds no second request event. What
  this buys the server is the *timing* — it closes its adapter knowing nothing
  can be admitted behind it, and a refusal here costs no teardown at all.
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
             # `lifecycle_fence_test.exs` pins this fence through `Lifecycle`
             # with Mimic, to simulate a race on the second call —
             # `Machines.Destroy`'s, once the adapter is already closed. A
             # self-call written `__MODULE__.fence_sandbox_for_teardown(...)`
             # keeps that stub able to intercept this one too, as
             # `Interruption.interrupt_dead/1` does for `wake_for_interrupt/1`.
             {:ok, _} <-
               __MODULE__.fence_sandbox_for_teardown(sandbox,
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

  The machine half — the fence, the provider destroy, the terminal write and
  the co-tenant notice — is `Fountain.Machines.Machine.destroy/2` (ADR 0058
  stage 5). What is left here is the conversation half: the egress release,
  the conversation's own status, its stage event and the telemetry the server
  matches on, none of which the machine's owner knows or should.

  **No `:terminating_conversation_id`**, deliberately. This is a reclaim, not
  a terminate: the bound has been reached over the whole machine (ADR 0023
  step 5, `busy_elsewhere?/2` and `max_lifetime_action/2` decide it), so a
  home or a machine with idle co-tenants on it is the case this destroys
  rather than the case it keeps. Handing the fence a terminating conversation
  would turn every one of those into `:sandbox_kept` and leave an unparkable
  machine billing forever, which is the bound's whole reason to exist.

  `handle` is now only the provider tag on the telemetry. The machine to
  destroy is read off the row, so a reclaim whose caller has already dropped
  its handle destroys the machine rather than leaking it.
  """
  @spec destroy(
          String.t(),
          String.t() | nil,
          Handle.t() | nil,
          :idle | :max_lifetime
        ) :: :ok | {:error, term()}
  def destroy(conversation_id, sandbox_id, handle, reason) do
    # Checked here as well as in the protocol, and with this module's own word
    # for it: `Machine.destroy/2` is not reached at all when there is no
    # machine, and a caller inside a transaction must be refused either way.
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      with :ok <- reclaim_machine(conversation_id, sandbox_id, reason) do
        do_destroy(conversation_id, handle, reason)
      end
    end
  end

  # No machine was ever minted for this conversation; there is nothing to
  # reclaim and the rows below still move.
  defp reclaim_machine(_conversation_id, nil, _reason), do: :ok

  defp reclaim_machine(conversation_id, sandbox_id, reason) do
    case Machine.destroy(sandbox_id,
           actor: "system:conversation_server",
           reason: reason,
           notify: {conversation_id, "reclaimed", to_string(reason), reclaim_message(reason)}
         ) do
      # `:kept` is unreachable without a terminating conversation and
      # `:already_terminal` is a machine someone else finished first; both
      # leave this conversation's own bookkeeping below to do.
      {:ok, _outcome} -> :ok
      {:error, _} = error -> error
    end
  end

  defp do_destroy(conversation_id, handle, reason) do
    Egress.release(conversation_id)

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

    # The co-tenants were told by `Machine.destroy/2`, before this, as part of
    # the machine operation itself, and a park's are told by `Machine.park/2`
    # the same way (ADR 0058 stage 6b). Both go through
    # `MachineEvents.tell_cotenants/5`, which is still the one sender of that
    # cast; the wrapper this module used to keep for the park path
    # (`stop_cotenants/5`) had no callers left and went with it.
    :telemetry.execute([:fountain, :sandbox, :reclaimed], %{count: 1}, %{
      reason: reason,
      provider: provider(handle)
    })

    :ok
  end

  # Liveness (#2255 decision 2): "is any server alive on this machine" is one
  # question, asked by two callers that each used to scan for it themselves —
  # `Termination.reap_sandbox/1` and `Workers.SandboxReaper`'s own
  # `server_alive?/1`. One scan, exposed in the two shapes those callers need:
  # the conversation ids for the one that acts on them, the boolean for the
  # one that only decides.
  #
  # Both now read `Fountain.Machines.Occupancy` (ADR 0058 stage 4), which is
  # the same scan for every "is anyone here" question rather than for these
  # two alone. `from_preloaded/1` is the constructor that runs no query, which
  # is what keeps this usable inside the reaper's per-row passes.
  @doc """
  Conversation ids on `sandbox` with a live, registered `ConversationServer`.

  `sandbox.conversations` must already be preloaded — every caller already
  carries it from the query that fetched the sandbox (a reap target, or the
  reaper's own stuck/abandoned scan), so this runs no query of its own.
  """
  @spec live_conversation_ids(Sandbox.t()) :: [String.t()]
  def live_conversation_ids(%Sandbox{conversations: conversations} = sandbox)
      when is_list(conversations) do
    sandbox |> Occupancy.from_preloaded() |> Occupancy.live_ids()
  end

  @doc """
  Whether any conversation on `sandbox` has a live, registered
  `ConversationServer` — the same scan as `live_conversation_ids/1`, for a
  caller that only needs yes or no.
  """
  @spec any_server_alive?(Sandbox.t()) :: boolean()
  def any_server_alive?(%Sandbox{} = sandbox) do
    sandbox |> Occupancy.from_preloaded() |> Occupancy.any_live?()
  end

  # Teardown fence (#2258): the machine-policy rule an admin reap, a
  # forced account deletion, and the destroy-home path all refuse or
  # commit against, plus the "is anyone else on this machine" predicate
  # it decides `:sandbox_kept` by (ADR 0023).
  @doc """
  Whether a conversation other than `conv_id` still holds `sandbox_id` — one
  that is not `terminated`/`failed`. A sandbox normally has one conversation;
  it gets a second when a teammate starts a fresh conversation on the same
  computer (`Fountain.Conversations.Termination.release_conversation/2`, `Fountain.Team`),
  and from then on the retired thread's lifecycle must not reach the disk
  its successor is running on. `_unsafe_`: callers have established
  ownership of `conv_id` already (a GenServer, or a scoped fetch before it).

  Status only, no clock: `Conversations._unsafe_sandbox_busy_elsewhere?/4` is
  the same question with the idle window applied, and the two answer
  differently on purpose. Both read `Fountain.Machines.Occupancy` (ADR 0058
  stage 4); this one takes `bindings/1`, the constructor that reads the
  conversation rows and nothing else, because its caller asks inside a
  transaction under the per-sandbox advisory lock.
  """
  def _unsafe_sandbox_held_by_other?(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    sandbox_id |> Occupancy.bindings() |> Occupancy.held_by_other?(conv_id)
  end

  @doc """
  Commit an admission fence before a caller tears down a sandbox. No provider
  I/O runs here. The caller owns this row and must stop actors and clean up
  the provider after success. Already admitted turns may be forcibly stopped.

  Reuses the reset fence so every existing reuse path refuses the machine,
  retaining capacity until retirement completes. `teardown_requested_at`
  distinguishes forced teardown from an ordinary reset. A new forced intent
  records `sandbox.teardown_requested` after commit; repeats preserve both
  timestamps. Escalating an existing reset preserves its admission fence.
  Refuses an enclosing transaction. `opts` carries actor, request_ip, reason and
  `:metadata` — extra keys merged into the event, for a caller whose own delete
  is about to nilify `user_id` on both the event and the sandbox it names.

  With a terminating_conversation_id, first lock and verify that conversation's
  current attachment and owner. A persistent home or another live conversation
  returns {:error, :sandbox_kept} without a new fence. The sandbox row stays
  locked through this decision and the fence, serializing supported attachments.
  """
  def fence_sandbox_for_teardown(%Sandbox{} = sandbox, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      case do_fence_sandbox_for_teardown(sandbox, Keyword.get(opts, :terminating_conversation_id)) do
        {:ok, {fenced, true}} ->
          Audit.record(%{
            user_id: fenced.user_id,
            action: "sandbox.teardown_requested",
            resource_type: "sandbox",
            resource_id: fenced.id,
            # ADR 0013 keeps `admin:<operator_id>` for account deletion alone,
            # so an operator reaping a machine from /admin/sandboxes records
            # the plain `admin` the vocabulary allows here.
            actor: teardown_actor(Keyword.get(opts, :actor, "self")),
            request_ip: Keyword.get(opts, :request_ip),
            metadata:
              Map.merge(
                %{
                  "reason" => Keyword.get(opts, :reason, "teardown"),
                  "provider" => fenced.provider
                },
                Keyword.get(opts, :metadata, %{})
              )
          })

          {:ok, fenced}

        {:ok, {fenced, false}} ->
          {:ok, fenced}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  The actor string a machine-lifecycle event records, from the one a caller
  gave.

  ADR 0013 reserves `admin:<operator_id>` for account deletion alone, so an
  operator reaping a machine from /admin/sandboxes records the plain `admin`
  the vocabulary allows. Public since ADR 0058 stage 5 so `sandbox.destroyed`
  and this module's own `sandbox.teardown_requested` cannot disagree about who
  did it: the two events describe one operation.
  """
  @spec teardown_actor(String.t()) :: String.t()
  def teardown_actor("admin:" <> _), do: "admin"
  def teardown_actor(actor), do: actor

  defp do_fence_sandbox_for_teardown(sandbox, ending_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
        @sandbox_lock_namespace,
        :erlang.phash2(sandbox.id)
      ])

      # Match admission's advisory -> conversation -> sandbox lock order.
      lock_terminating_conversation(sandbox, ending_id)

      current =
        Repo.one(from s in Sandbox, where: s.id == ^sandbox.id, lock: "FOR UPDATE") ||
          Repo.rollback(:not_found)

      # The last-detach rule, through `Machines.Policy` since stage 7a. The
      # `held_by_other?` half stays a query made *here*, on this transaction's
      # own connection: it reads rows this advisory-locked transaction has
      # written and not yet committed, so it can move behind neither a process
      # nor a pure function (#2348 review).
      #
      # Passed as a thunk so it keeps `main`'s short-circuit: `or` never ran
      # that query for a `persistent` machine, and handing the answer in as a
      # value made a locked read of every conversation on the machine
      # unconditional on the one path where it cannot change the outcome.
      if not is_nil(ending_id) and
           Policy.keep_on_last_detach?(
             current.mode,
             fn -> _unsafe_sandbox_held_by_other?(current.id, ending_id) end
           ) do
        Repo.rollback(:sandbox_kept)
      end

      # Forced teardown may stop an admitted turn. Keep the admission fence
      # and its timestamp when an ordinary reset is escalated to forced teardown.
      cond do
        current.status in @billable_terminal ->
          {current, false}

        is_nil(current.teardown_requested_at) ->
          now = DateTime.utc_now()

          fenced =
            current
            |> Ecto.Changeset.change(
              reset_requested_at: current.reset_requested_at || now,
              teardown_requested_at: now
            )
            |> Repo.update!()

          {fenced, true}

        true ->
          {current, false}
      end
    end)
  end

  defp lock_terminating_conversation(_sandbox, nil), do: :ok

  defp lock_terminating_conversation(sandbox, ending_id) when is_binary(ending_id) do
    Repo.one(
      from c in Conversation,
        where:
          c.id == ^ending_id and c.sandbox_id == ^sandbox.id and c.user_id == ^sandbox.user_id,
        select: c.id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:sandbox_unavailable)
  end

  defp minutes(nil), do: "?"
  defp minutes(seconds), do: div(seconds, 60)
  defp hours(nil), do: "?"
  defp hours(seconds), do: div(seconds, 3600)
end
