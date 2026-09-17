defmodule Fountain.Machines.Policy do
  @moduledoc """
  What the two sandbox modes mean, as decisions rather than as branches
  (ADR 0058, stage 7a).

  ADR 0058's Decision says "the two sandbox modes become one lifecycle policy on
  the machine: `ephemeral` is a machine that destroys itself on its last detach,
  `persistent` one that parks". That policy existed before this module, spread
  across four call sites in three modules, and each of them read like a local
  branch rather than like the rule it was one half of:

  | The decision | Where it lived |
  |---|---|
  | Can this provider park at all? | `Lifecycle.idle_action/1` |
  | Park or destroy at the idle bound? | `Lifecycle.idle_machine_action/1` |
  | Park or destroy at the ceiling? | `Lifecycle.max_lifetime_action/2` |
  | Keep the machine on the last detach? | `Lifecycle.do_fence_sandbox_for_teardown/2` |
  | What mode does a launch get? | `Launch.resolve_sandbox_mode/2` |

  They are gathered here, pure and query-free, and each call site delegates.
  **Nothing about the answers changed** — `policy_test.exs` states them as ADR
  0023 step 5's decision table, and every existing test of the five sites passes
  untouched. That is the point of doing it as a move: stage 9 turns the fence
  columns off, #1089 gives `attach` an agent layer, and both want one place to
  read the mode's meaning from rather than four.

  ## What deliberately did not move

  **The questions, only the answers.** `home?/1`, `busy_elsewhere?/2` and
  `_unsafe_sandbox_held_by_other?/2` each run a query, and two of them run it
  inside the teardown fence's own transaction where it must stay on the caller's
  connection (#2348 review). A pure module that took a `Repo` with it would be
  neither pure nor a policy. So the caller answers "is this a home?" and "is
  anybody else on it?" and hands the answers here.

  **`Lifecycle.check/4`, the clock.** Whether a bound has been crossed is a
  measurement, not a policy, and `Park.still_expired?/3` and
  `SandboxReaper.expired?/2` both re-run it. Moving it would separate it from
  the two `explain/2` strings that have to stay honest about what each bound
  does (a suspend keeps the disk; a destroy does not).

  **`Launch.home_or_new/5`.** It reads the identity index to find an existing
  home, which is a query and a uniqueness rule rather than a decision about what
  the mode means. Only its *default* — what mode a launch that names none
  gets — is here, as `default_mode/1`.
  """

  alias Fountain.Agents
  alias Fountain.Conversations.Sandbox

  @doc """
  The mode a launch that named none gets: the agent's default, or `ephemeral`.

  `ephemeral` is the floor rather than a preference. A persistent machine is a
  disk Fountain keeps and bills for until somebody asks it not to, and an agent
  that has never said which it wants has not asked for that.
  """
  @spec default_mode(Agents.Agent.t()) :: String.t()
  def default_mode(%Agents.Agent{sandbox_mode: mode}) when mode in [nil, ""], do: "ephemeral"
  def default_mode(%Agents.Agent{sandbox_mode: mode}), do: mode

  @doc """
  What crossing the idle bound does on this provider: `:suspend` where the disk
  can be kept, `:destroy` where it cannot.

  The capability question, and the whole of ADR 0017's degradation. A provider
  that advertises `:suspend` parks with the disk preserved — implicit
  scale-to-zero for Sprites, an explicit pause or stop for E2B and Daytona, a
  marker file for the self-hosted runner. A provider without it would leave an
  idle machine billing, so the cost control wins over the agent's memory,
  exactly as the max-lifetime ceiling already prices it.

  A capability, not a promise about a particular machine: `Machines.Park` asks
  this again under the lease, because a pre-lease verdict is stale by
  construction, and the provider's answer to `suspend/1` is the one that
  decides.
  """
  @spec idle_action(atom()) :: :suspend | :destroy
  def idle_action(provider) when is_atom(provider) do
    if Managoat.Sandbox.supports?(provider, :suspend), do: :suspend, else: :destroy
  end

  @doc """
  What a reclaim does to this machine: `:park` it, or `:destroy` it.

  ADR 0023 step 5's table, in one function. Two inputs beyond the provider: the
  bound that fired, and whether this machine is a persistent home.

  | Bound | Home? | Provider can park | Provider cannot park |
  |---|---|---|---|
  | `:idle` | either | `:park` | `:destroy` |
  | `:max_lifetime` | yes | `:park` | `:destroy` |
  | `:max_lifetime` | no | `:destroy` | `:destroy` |

  The idle bound does not care whether the machine is a home, and that is worth
  saying rather than leaving to be read off the table: an idle ephemeral machine
  is parked too, because the disk is the agent's memory whatever the mode, and
  #649 proved it cannot be rebuilt on a fresh one. What `persistent` buys is
  the ceiling row and the last-detach row below it.

  The ceiling is where the modes part. It exists for the conversation that never
  stops being busy, so it fires with work in flight and reclaims the machine
  whatever the activity; destroying a *home* at it would defeat the mode, since
  that disk is the agent's memory across every conversation on it. A home on a
  provider that cannot park is destroyed like an ephemeral machine, for the
  reason `idle_action/1` gives.

  `home?` is the caller's answer — see the moduledoc on what did not move.
  """
  @spec reclaim_action(:idle | :max_lifetime, atom(), boolean()) :: :park | :destroy
  def reclaim_action(bound, provider, home?)
      when bound in [:idle, :max_lifetime] and is_atom(provider) and is_boolean(home?) do
    if bound == :max_lifetime and not home? do
      :destroy
    else
      case idle_action(provider) do
        :suspend -> :park
        :destroy -> :destroy
      end
    end
  end

  @doc """
  Does the machine survive the conversation that is detaching from it?

  The last-detach rule, and the other half of what the two modes mean. A
  `persistent` machine is a home: it outlives every conversation on it by
  definition, and tearing it down when one ends would make the mode meaningless.
  An `ephemeral` one is kept only while somebody else is still on it — which
  they can be, since ADR 0023 put several conversations on one machine and the
  busiest production home carries 36.

  `held_by_other?` is the caller's answer, and on the teardown-fence path it has
  to be: it is read inside that fence's own advisory-locked transaction, on that
  transaction's uncommitted rows, so it cannot move behind a process or a pure
  function (#2348 review).

  **It may be given as a zero-arity function, and the fence gives it as one**
  (round 1, behaviour review). `or` short-circuits, so `main` never ran the
  "is anybody else here" query for a `persistent` machine — it had already
  decided. Passing the answer as a value made that query unconditional: a
  locked read of every conversation on the machine, inside the fence's own
  transaction, on the one path where the result could not change the outcome.
  A thunk restores the short-circuit exactly, and the boolean arity stays for
  callers that have the answer in hand.

  This answers only the *forced* case — a conversation ending and asking whether
  its machine should go with it. A machine nobody is on and nobody is ending is
  reclaimed by the bounds above instead.
  """
  @spec keep_on_last_detach?(String.t() | nil, boolean() | (-> boolean())) :: boolean()
  def keep_on_last_detach?("persistent", _held_by_other?), do: true

  def keep_on_last_detach?(_mode, held_by_other?) when is_function(held_by_other?, 0),
    do: held_by_other?.()

  def keep_on_last_detach?(_mode, held_by_other?) when is_boolean(held_by_other?),
    do: held_by_other?

  @doc """
  Is this machine a persistent home?

  The predicate over a row the caller has already read, so the *question* stays
  where the query is and the *answer* is read here. `Sandbox.modes/0` is the
  closed set; anything else is not a home.
  """
  @spec home?(Sandbox.t() | map() | nil) :: boolean()
  def home?(%{mode: "persistent"}), do: true
  def home?(_sandbox), do: false
end
