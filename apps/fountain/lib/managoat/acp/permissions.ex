defmodule Managoat.ACP.Permissions do
  @moduledoc """
  What answers `session/request_permission`, per tool.

  Gate 3 of Fountain's ADR 0014, built in #939; the issue numbers here are
  that repository's.

  Every runtime the platform shipped used to run with its safety rail removed
  by a vendor flag. Three of those four flags went with the legacy spawn path
  (#671-#675); what replaced them was this module's predecessor — a constant in
  `Managoat.ACP.Peer` that answered every request by picking `allow_always`,
  else `allow_once`, else whatever was offered first. The rail was still off,
  but it was off in one function we own, which is what made it a policy
  problem rather than a fork-four-CLIs problem.

  ## The shape

  A policy is a map of key to verdict, plus a `"default"` key:

      %{"default" => "auto_allow", "execute" => "ask"}

  A request is matched most-specific-first (`verdict_for_request/2`): the tool
  card's title, then ACP's coarse `kind`, then `"default"`.

  **Reach for `kind` unless you know the runtime's titles.** claude-agent-acp,
  which every shipped agent runs, titles a tool call with the command itself
  — `curl -sS … https://example.com` — so a title key matches exactly one
  invocation and nothing else. `kind` is the stable half: `execute`, `edit`,
  `read`, `delete`, `move`, `search`, `fetch`, `think`, `other`. Measured live
  on 2026-08-22; see `verdict_for_request/2`.

  ## Narrow, never widen

  An agent holds a policy; a launch may supply its own. **The launch may only
  make the policy more restrictive.** That single rule is the no-escalation
  guarantee, and it is why there is no `allowed_permission_policies` list beside
  it the way `environment_id` needs `allowed_environment_ids` — a launch cannot
  reach anything the agent did not already permit, so there is nothing to
  allow-list.

  It is enforced twice, deliberately:

  - `check_narrows/2` rejects a widening launch **at the door**, so the caller
    gets an error naming the tool rather than a silent downgrade.
  - `effective/2` **clamps** — the result is the more restrictive of the two for
    every tool. This is the invariant the peer actually depends on, and it means
    an agent that tightens its policy later also tightens every conversation
    already running under it. Storing a pre-merged policy on the conversation
    would have frozen the old, looser one.

  ## Verdicts

  | verdict | what answers |
  |---|---|
  | `auto_allow` | today's behaviour: `allow_always`, else `allow_once`, else the first option offered |
  | `auto_deny` | a `reject_*` option when the agent offered one, `cancelled` when it did not |
  | `ask` | a human, over the stream, within the timeout — then deny (#940) |

  `auto_allow` is the default, so adopting a policy changes nothing until
  someone writes one.

  ## Never synthesise an option

  `auto_deny` picks from what the agent offered and never invents an id. An
  adapter that offers no rejection gets `cancelled`, which is the protocol's own
  "no option was selected" and the only honest answer available. Inventing an
  `optionId` the agent never advertised would at best error and at worst select
  something unrelated.

  ## The client does not remember an answer, and "always" often does not either

  An answer is relayed to the peer and forgotten. Every "remember this"
  semantic belongs to the agent, and each of the three that ask implements it
  differently. Measured live against production on 2026-08-22 — do not
  re-derive, and do not assume an `allow_always` option means what it says:

  | runtime | what `allow_always` does |
  |---|---|
  | claude | Writes a rule into `.claude/settings.local.json` in the sandbox. Holds across turns, dies with the sandbox. **Except** where the command writes outside the working directory — see below. |
  | codex | "Allow for Session" lives in the codex process, so it lasts exactly one turn. "Allow Commands Starting With …" (`accept_execpolicy_amendment`) is written to disk and holds. |
  | opencode | Never asks, so there is nothing to grant (#959). |

  Two consequences worth holding on to. **codex's session grant is the
  client's, not a defect**: a connection that ends at turn end tears that
  process down, which is the same lever as #817. And **every grant dies with
  the sandbox**, so a sandbox reclaim silently resets consent.

  claude's exception is upstream and is a prompt loop no clicking resolves
  (anthropics/claude-code#88919). A shell redirect to a path outside the
  session's working directory is gated by a filesystem write check that no
  `Bash(...)` or `Read(...)` rule participates in, and `allow_always` only ever
  proposes those. So it writes a well-formed, general, irrelevant rule, and the
  byte-identical command asks again — measured twice within a single turn, in
  one process. The rule of thumb: **`allow_always` holds only where the command
  writes nothing outside its cwd.**

  None of this is worked around here. #996 is where the question of whether
  the client should own grants at all is being decided; a matcher written
  before that decision would be a second permission authority arriving by
  accident.

  ## Configuration

  None. The policy is an argument, and `ask_timeout_ms/1` takes the
  configured number of seconds as its argument too — the host reads its own
  configuration and passes it, so the library never reads anyone's.
  """

  @auto_allow "auto_allow"
  @ask "ask"
  @auto_deny "auto_deny"

  @verdicts [@auto_allow, @ask, @auto_deny]

  # Restrictiveness, low to high. `effective/2` takes the max, `check_narrows/2`
  # requires the launch to be >= the agent. `ask` sits between the two because
  # it withholds the tool until a human acts, which is stricter than allowing
  # and looser than refusing outright.
  @rank %{@auto_allow => 0, @ask => 1, @auto_deny => 2}

  @default_key "default"

  # ACP's `toolCall.kind` vocabulary, in the protocol's own order.
  @tool_kinds ~w(read edit delete move search execute think fetch switch_mode other)

  # Well under a typical idle-reclaim bound (Fountain's is 60 minutes), and
  # deliberately so: a held request suppresses only the idle verdict, so one
  # that outlived the idle bound would be resolved by the max-lifetime ceiling
  # instead — which destroys the sandbox rather than parking it. The timeout
  # has to fire first for an unanswered prompt to cost a turn rather than the
  # agent's memory.
  @default_ask_timeout_seconds 300

  @doc """
  How long a held `ask` waits for a human before it is denied, in
  milliseconds, from a configured number of seconds.

  Deny on expiry is the only safe default. `configured` is whatever the host
  read from its own configuration: a positive integer, a numeric string, or
  `nil` for the default (#{@default_ask_timeout_seconds} seconds). Anything
  else is the default too — a misconfiguration must not become "never deny".
  A value at or above the host's idle-reclaim bound is a misconfiguration,
  for the reason in the comment above this function.
  """
  @spec ask_timeout_ms(term()) :: pos_integer()
  def ask_timeout_ms(configured \\ nil) do
    configured
    |> to_positive_seconds(@default_ask_timeout_seconds)
    |> Kernel.*(1000)
  end

  defp to_positive_seconds(n, _default) when is_integer(n) and n > 0, do: n

  defp to_positive_seconds(n, default) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} when i > 0 -> i
      _ -> default
    end
  end

  defp to_positive_seconds(_n, default), do: default

  @doc "Every verdict a policy may name."
  @spec verdicts() :: [String.t()]
  def verdicts, do: @verdicts

  @doc """
  ACP's own tool kinds, which are the policy keys worth offering in a form.

  The protocol's closed list, so it is the stable half of a request: a title
  matches one invocation of one command on claude (#958), while a kind means
  the same thing on every runtime and every turn. A policy may still name a
  title — `verdict_for_request/2` tries that first — it is simply not something
  to invite someone to type.
  """
  @spec tool_kinds() :: [String.t()]
  def tool_kinds, do: @tool_kinds

  @doc "The verdict applied when a policy names neither the tool nor a default."
  @spec default_verdict() :: String.t()
  def default_verdict, do: @auto_allow

  @doc """
  Verdicts that can be honoured.

  All three, since #940 built somewhere to ask: the peer holds the request
  open, the request renders as a `permission_request` block, and
  `POST /api/conversations/:id/requests/:request_id` answers it. Before that
  `ask` was a valid policy value with nowhere to ask, and both doors refused
  it.

  Kept as its own list rather than folded into `verdicts/0` because the
  published OpenAPI enum reads from here: a verdict the API would 422 on must
  not be advertised as accepted.
  """
  @spec buildable_verdicts() :: [String.t()]
  def buildable_verdicts, do: @verdicts

  @doc "Whether `verdict` can be honoured."
  @spec buildable?(String.t()) :: boolean()
  def buildable?(verdict), do: verdict in buildable_verdicts()

  @doc """
  Whether a policy asks for anything the runtime has to act on.

  `auto_allow` everywhere is what the peer would do with no policy at all, so it
  needs nothing from the runtime. Anything else has to reach the agent as an
  answer to `session/request_permission` — which is why a host that knows a
  runtime never sends one should refuse such a policy at the door.
  """
  @spec needs_enforcement?(map() | nil) :: boolean()
  def needs_enforcement?(policy) do
    policy |> normalize() |> Enum.any?(fn {_key, verdict} -> verdict != @auto_allow end)
  end

  @doc """
  The verdict `policy` gives `tool`.

  Falls back to the policy's own `"default"`, then to `auto_allow`.
  """
  @spec verdict_for(map() | nil, String.t() | nil) :: String.t()
  def verdict_for(policy, tool) when is_map(policy) do
    with nil <- tool && Map.get(policy, tool),
         nil <- Map.get(policy, @default_key) do
      @auto_allow
    else
      verdict when verdict in @verdicts -> verdict
      # A value that is not a verdict is not trusted into an allow: the
      # changesets reject these, so reaching here means the row was written
      # around them.
      _ -> @auto_deny
    end
  end

  def verdict_for(_policy, _tool), do: @auto_allow

  @doc """
  Merge an agent's policy with a launch's, taking the **more restrictive** of
  the two for every tool either of them names.

  Clamping rather than replacing is what makes the launch override safe by
  construction: no merge can produce a verdict looser than the agent's, whatever
  was stored, and a later tightening of the agent applies to conversations
  already running.
  """
  @spec effective(map() | nil, map() | nil) :: map()
  def effective(agent_policy, launch_policy) do
    agent_policy = normalize(agent_policy)
    launch_policy = normalize(launch_policy)

    agent_policy
    |> keys_with(launch_policy)
    |> Map.new(fn key ->
      {key, stricter(verdict_for(agent_policy, key), verdict_for(launch_policy, key))}
    end)
    |> Map.put(
      @default_key,
      stricter(verdict_for(agent_policy, nil), verdict_for(launch_policy, nil))
    )
  end

  @doc """
  Whether `launch` is at least as restrictive as `agent` for every tool.

  Returns `:ok`, or `{:error, {:permission_policy_widens, tool}}` naming the
  first tool the launch would loosen. The check spans the union of both key
  sets *and* the defaults, because a launch that only lowers `"default"` still
  loosens every tool the agent covered by its own default.
  """
  @spec check_narrows(map() | nil, map() | nil) ::
          :ok | {:error, {:permission_policy_widens, String.t()}}
  def check_narrows(agent, launch) do
    agent = normalize(agent)
    launch = normalize(launch)

    agent
    |> keys_with(launch)
    |> Enum.concat([@default_key])
    |> Enum.find_value(:ok, fn key ->
      if rank(verdict_for(launch, key)) < rank(verdict_for(agent, key)) do
        {:error, {:permission_policy_widens, key}}
      end
    end)
  end

  @doc """
  The `session/request_permission` result for `params` under `policy`.

  Returns the inner `outcome` object — the caller wraps it, because ACP's
  response body is `{"outcome": {"outcome": …}}`.
  """
  @spec outcome(map() | nil, map()) :: map()
  def outcome(policy, params) when is_map(params) do
    options = Map.get(params, "options") || []

    case verdict_for_request(policy, params) do
      @auto_deny -> deny(options)
      # `ask` is not answered here — the peer holds the request open and a human
      # answers it (#940). Denying is the safe reading if a caller asks this
      # function for an outcome anyway, and `deny_outcome/1` is what the timeout
      # and the turn's end use directly.
      @ask -> deny(options)
      _ -> allow(options)
    end
  end

  @doc """
  The verdict `policy` gives one `session/request_permission`.

  Tries the request's keys in order — the tool card's title first, then ACP's
  coarse `kind` — and falls through to the policy's `"default"`.

  **The `kind` fallback is what makes a per-tool policy writable.** Measured
  against claude-agent-acp 0.66 in production on 2026-08-22: its `toolCall.title`
  is the command itself (`curl -sS -o /dev/null -w "%{http_code}" https://…`),
  not the tool. A title key can therefore only ever match one invocation, which
  left `"default"` as the only usable key on the runtime every shipped agent
  runs — a per-tool policy in name only. `kind` (`execute`, `edit`, `read`,
  `delete`, `move`, `search`, `fetch`, `think`, `other`) is the stable half of
  the same request, so `%{"execute" => "ask"}` means "ask before running
  anything in the shell" and keeps working across invocations.

  Title stays first: an exact-title rule is the more specific of the two, and a
  runtime whose titles *are* tool names (`Bash`, `Edit`) keeps behaving as
  0014 gate 3 described.
  """
  @spec verdict_for_request(map() | nil, map()) :: String.t()
  def verdict_for_request(policy, params) when is_map(params) do
    policy = normalize(policy)

    params
    |> policy_keys()
    |> Enum.find_value(nil, fn key -> Map.get(policy, key) end)
    |> case do
      verdict when verdict in @verdicts -> verdict
      # Not a verdict at all: the changesets reject these, so a value here means
      # the row was written around them. Not trusted into an allow.
      verdict when not is_nil(verdict) -> @auto_deny
      nil -> verdict_for(policy, nil)
    end
  end

  @doc """
  The policy keys one request matches, most specific first.

  The tool card's title, then ACP's `kind`. Empty when the request carries no
  tool call at all, which falls through to the policy's default.
  """
  @spec policy_keys(map()) :: [String.t()]
  def policy_keys(%{"toolCall" => call}) when is_map(call) do
    [call["title"], call["kind"]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  def policy_keys(_params), do: []

  @doc """
  The tool a permission request is about, as the transcript labels it.

  Mirrors `Managoat.ACP.Blocks`' tool naming so a policy key is the string a user reads on
  the tool card. `nil` when the request carries no tool call at all, which falls
  through to the policy's default.
  """
  @spec tool_name(map()) :: String.t() | nil
  def tool_name(%{"toolCall" => call}) when is_map(call) do
    case {call["title"], call["kind"]} do
      {title, _} when is_binary(title) and title != "" -> title
      {_, kind} when is_binary(kind) and kind != "" -> kind
      _ -> nil
    end
  end

  def tool_name(_params), do: nil

  @doc "Which verdict of the two withholds more."
  @spec stricter(String.t(), String.t()) :: String.t()
  def stricter(a, b), do: if(rank(a) >= rank(b), do: a, else: b)

  defp rank(verdict), do: Map.get(@rank, verdict, @rank[@auto_deny])

  # Every tool either side names, minus the default — which is handled
  # separately because it is a fallback, not a tool.
  defp keys_with(a, b) do
    a
    |> Map.keys()
    |> Enum.concat(Map.keys(b))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == @default_key))
  end

  defp normalize(policy) when is_map(policy), do: policy
  defp normalize(_), do: %{}

  # Today's ladder, kept verbatim: `allow_always`, else `allow_once`, else
  # whatever was offered first. That last rung is why this is parity and not a
  # new behaviour — an adapter offering only bespoke option kinds is answered
  # exactly as it was before #939.
  defp allow(options) do
    select(options, ~w(allow_always allow_once)) || selected(List.first(options)) || cancelled()
  end

  # No such rung on the deny side. Falling back to "whatever was offered first"
  # would pick an *allow* on any adapter that lists its options that way, which
  # is the one thing `auto_deny` must never do. An adapter that offers no
  # rejection gets `cancelled` — the protocol's own "nothing was selected".
  defp deny(options), do: deny_outcome(options)

  @doc """
  The outcome that refuses a request, from the options the agent offered.

  Public because #940's timeout and end-of-turn paths refuse a *held* request
  directly, without a policy in hand — the policy already said `ask`, and what
  is being decided at that point is only that nobody answered.
  """
  @spec deny_outcome([map()]) :: map()
  def deny_outcome(options) do
    select(options, ~w(reject_always reject_once)) || cancelled()
  end

  defp select(options, kinds) do
    Enum.find_value(kinds, fn kind ->
      options |> Enum.find(&(is_map(&1) and &1["kind"] == kind)) |> selected()
    end)
  end

  defp selected(%{"optionId" => id}), do: %{outcome: "selected", optionId: id}
  defp selected(_), do: nil

  defp cancelled, do: %{outcome: "cancelled"}
end
