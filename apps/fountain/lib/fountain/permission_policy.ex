defmodule Fountain.PermissionPolicy do
  @moduledoc """
  The Fountain half of a `permission_policy` map (#1635).

  `Managoat.ACP.Permissions` owns the tool half: a key is a tool title or an
  ACP kind, a value is one of the three verdicts, and `"default"` covers the
  rest. That library reads every key it is given as a tool, so a key that is
  not one has to be taken out before the map reaches it. This module owns the
  taking out, and the one such key that exists.

  ## `ask_timeout`

  How long a request that outlived its turn waits, in seconds. Only detached
  requests read it. A request held inside a running turn keeps the global
  `:permission_ask_timeout_seconds` ceiling, which has to stay under the idle
  bound because the turn holding it defers idle reclaim
  (`Fountain.Conversations.Lifecycle.ask_timeout_ms/0`). A detached request
  holds nothing open, so that reasoning does not reach it and the value may
  be days.

  ## The ceiling, and what it is not

  `seconds/1` refuses anything above `max_ask_timeout_seconds/0` (365 days).
  That is **not** a quieter copy of the idle bound: the idle bound is minutes
  and exists because a held request keeps a sandbox from parking, which a
  detached request does not do. This ceiling exists because the value ends up
  in `turns.permission_deadline`, and a `timestamp` stops at 294276 AD — an
  `ask_timeout` of 1e15 seconds produced a year-31690765 deadline that
  Postgrex refused to encode, raising inside the `handle_info` that detaches
  the request and leaving the turn `running` with the request neither
  detached nor denied.

  One parser, so both halves of the bound get it: the tenant's `ask_timeout`
  here, and the sandbox's own `_meta.fountain.timeout` through
  `Fountain.Conversations.DetachedRequest.timeout_seconds/1`. A year is
  further out than anything this feature is for, so the refusal reads as a
  typo caught rather than as a limit imposed.

  ## Narrowing

  A launch policy may only narrow the agent's, and the same rule applies
  here: a **shorter** wait is the stricter one, because the tool is refused
  sooner. `effective_ask_timeout_seconds/2` takes the smaller of the two, and
  `check_narrows/2` refuses a launch that asks for a longer one.
  """

  @ask_timeout "ask_timeout"

  # Keys of a permission policy that name no tool. Everything here is stripped
  # before the map reaches `Managoat.ACP.Permissions`, whose every function
  # reads a key as a tool and a value as a verdict.
  @reserved [@ask_timeout]

  # 365 days. Not a product limit — see "The ceiling, and what it is not"
  # above. Any value comfortably under 9.2e12 seconds would do; this one is
  # chosen to be obviously longer than any wait the feature is for, so that
  # hitting it means a typo rather than a use case.
  @max_ask_timeout_seconds 365 * 24 * 60 * 60

  @doc "The longest `ask_timeout` that can be stored, in seconds."
  @spec max_ask_timeout_seconds() :: pos_integer()
  def max_ask_timeout_seconds, do: @max_ask_timeout_seconds

  @doc """
  `value` as a number of seconds this codebase can hold, or nil.

  A positive integer, or a string of one, no greater than
  `max_ask_timeout_seconds/0`. Everything else is nil rather than zero or the
  ceiling, because the callers all treat nil as "fall back to the next bound
  down" — so a typo becomes a shorter wait, never "deny at once" and never
  "never deny".

  The single parser for every seconds value on this path. A second copy is
  how one half of the bound gets a ceiling and the other does not.
  """
  @spec seconds(term()) :: pos_integer() | nil
  def seconds(value)
  def seconds(n) when is_integer(n) and n > 0 and n <= @max_ask_timeout_seconds, do: n

  def seconds(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> seconds(i)
      _ -> nil
    end
  end

  def seconds(_value), do: nil

  @doc "Policy keys that name something other than a tool."
  @spec reserved_keys() :: [String.t()]
  def reserved_keys, do: @reserved

  @doc "Validation errors for every reserved key present in a policy."
  @spec reserved_errors(map()) :: [{String.t(), String.t()}]
  def reserved_errors(policy) when is_map(policy) do
    policy
    |> Map.take(@reserved)
    |> Enum.flat_map(fn {key, value} ->
      case reserved_error(key, value) do
        nil -> []
        message -> [{key, message}]
      end
    end)
  end

  # Every reserved key needs a clause here. No catch-all: adding a key without
  # its validator must fail the reserved-key guardrail, never accept its value.
  defp reserved_error(@ask_timeout, value) do
    unless valid_ask_timeout?(value) do
      "#{inspect(value)} is not a positive number of seconds " <>
        "no greater than #{max_ask_timeout_seconds()}"
    end
  end

  @doc """
  The tool half of a policy: what `Managoat.ACP.Permissions` is given.

  Every call into that library goes through here. A reserved key left in
  would be read as a tool whose verdict is not a verdict, which
  `verdict_for/2` treats as `auto_deny` and `effective/2` would then write
  back into the merged map.
  """
  @spec verdicts(map() | nil) :: map()
  def verdicts(policy) when is_map(policy), do: Map.drop(policy, @reserved)
  def verdicts(_policy), do: %{}

  @doc """
  Carry the reserved keys of `previous` onto `policy`.

  The console's agent form rebuilds the tool half from its own inputs and
  knows nothing about the rest, so without this a save from that form would
  silently drop a configured `ask_timeout`.
  """
  @spec keep_reserved(map(), map() | nil) :: map()
  def keep_reserved(policy, previous) when is_map(policy) do
    Map.merge(policy, Map.take(previous || %{}, @reserved))
  end

  @doc """
  The `ask_timeout` a policy names, in seconds, or nil.

  `seconds/1`, so a value over the ceiling reads as nil and the caller falls
  back to the global ask timeout rather than storing a deadline nothing can
  write.
  """
  @spec ask_timeout_seconds(map() | nil) :: pos_integer() | nil
  def ask_timeout_seconds(policy) when is_map(policy) do
    seconds(Map.get(policy, @ask_timeout))
  end

  def ask_timeout_seconds(_policy), do: nil

  @doc """
  The `ask_timeout` in force for a conversation, in seconds, or nil.

  The smaller of the agent's and the launch's, which is the stricter of the
  two. Either side alone is honoured; neither leaves nil, and the caller
  falls back to the global ceiling.
  """
  @spec effective_ask_timeout_seconds(map() | nil, map() | nil) :: pos_integer() | nil
  def effective_ask_timeout_seconds(agent_policy, launch_policy) do
    case {ask_timeout_seconds(agent_policy), ask_timeout_seconds(launch_policy)} do
      {nil, nil} -> nil
      {agent, nil} -> agent
      {nil, launch} -> launch
      {agent, launch} -> min(agent, launch)
    end
  end

  @doc """
  Whether `launch` narrows `agent` on every reserved key.

  `:ok`, or `{:error, {:permission_policy_widens, key}}` naming the first key
  the launch would loosen — the same shape `Managoat.ACP.Permissions.check_narrows/2`
  returns, so a caller checks both and reports either the same way.

  `ceiling_seconds` is what applies when the agent names no `ask_timeout`, and
  it is the host's own global ask timeout. Without it an agent that never set
  the key would let any launch buy a wait of days, which is the escalation the
  narrowing rule exists to stop: a longer wait is more time for somebody to
  approve the tool, so longer is looser. The host reads its configuration and
  passes it, as `Managoat.ACP.Permissions.ask_timeout_ms/1` is given its own.
  """
  @spec check_narrows(map() | nil, map() | nil, pos_integer() | nil) ::
          :ok | {:error, {:permission_policy_widens, String.t()}}
  def check_narrows(agent, launch, ceiling_seconds \\ nil) do
    case {ask_timeout_seconds(agent) || ceiling_seconds, ask_timeout_seconds(launch)} do
      {a, l} when is_integer(a) and is_integer(l) and l > a ->
        {:error, {:permission_policy_widens, @ask_timeout}}

      _ ->
        :ok
    end
  end

  @doc """
  Whether `value` is an acceptable `ask_timeout`, for a changeset.

  The two doors that store a policy refuse what `seconds/1` cannot read, so
  an over-ceiling value is a validation error with a message rather than a
  row that raises when something tries to detach a request against it.
  """
  @spec valid_ask_timeout?(term()) :: boolean()
  def valid_ask_timeout?(value), do: not is_nil(seconds(value))
end
