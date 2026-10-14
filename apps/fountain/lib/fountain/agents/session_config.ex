defmodule Fountain.Agents.SessionConfig do
  @moduledoc """
  The ACP session config options a turn asks its adapter for (ADR 0062):
  reasoning effort, fast mode, whatever the adapter advertises beyond the
  model. A map of option id to value, a string or a boolean.

  Three layers, each overriding the one before:

    1. the agent's `session_config`,
    2. the conversation's `session_config`, set at launch,
    3. the `session_config` of the prompt that opens the turn, for that turn
       only.

  `effective/3` merges them, and the result is recorded on the turn as
  `config_selection["requested"]` when it opens. It is what both connection
  paths send to `Managoat.ACP.Peer`.

  ## Only the shape is checked

  Which ids and values exist is the adapter's to say, per session and per
  model. Claude offers `effort` only on a model that supports it, and codex's
  `reasoning_effort` values are the model's own. A list here would be wrong
  the day an adapter moves, which is `Agents.ModelCatalog`'s argument for
  model ids (#554, #970). So this module checks the shape and nothing else.
  The peer skips an id the adapter does not advertise and reports it, and an
  adapter's refusal of a value it does advertise fails the turn with the
  adapter's own message.

  `"model"` is refused: the model has its own field, pinned first and
  verified (ADR 0061).

  ## The harness's permission mode is not a session option

  Both pinned adapters list their permission mode as a config option:
  claude-agent-acp 0.81.2's `mode` (`default`, `acceptEdits`, `plan`,
  `auto`, `bypassPermissions`) and codex-acp 1.10.0's `mode` (`read-only`,
  `agent`, `agent-full-access`) and `collaboration_mode`. Sending one would
  move the harness out from under the conversation's `permission_policy`, which
  a launch may narrow and never widen (ADR 0016); a prompt's
  `{"mode": "bypassPermissions"}` would widen it for anyone who can prompt. So
  `harness_mode_ids/0` are refused like `"model"`, and `effective/3` drops them
  from rows written before the refusal (ADR 0062, addendum of 2026-10-14).
  `offered/1` drops them from the options the adapter advertises, so a client
  reading `session_config_options` is not offered what it cannot request.
  """

  require Logger

  import Ecto.Changeset

  @max_options 16
  @max_value_length 200
  @id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/

  # The pinned adapters' permission, approval and sandbox mode ids. Gemini
  # 0.59.0 advertises no config options at all.
  @harness_mode_ids ~w(mode collaboration_mode)

  @type t :: %{optional(String.t()) => String.t() | boolean()}

  def max_options, do: @max_options
  def max_value_length, do: @max_value_length

  @doc "The option ids that set the harness's permission mode, which no layer may request."
  @spec harness_mode_ids() :: [String.t()]
  def harness_mode_ids, do: @harness_mode_ids

  @doc """
  `:ok`, or `{:error, message}` naming the first fault. `nil` is an empty
  request.
  """
  @spec check(term()) :: :ok | {:error, String.t()}
  def check(nil), do: :ok

  def check(config) when is_map(config) do
    cond do
      map_size(config) > @max_options ->
        {:error, "may name at most #{@max_options} options"}

      bad = Enum.find(config, fn {id, _} -> not valid_id?(id) end) ->
        {:error, "has an invalid option id: #{inspect(elem(bad, 0))}"}

      Map.has_key?(config, "model") ->
        {:error, "cannot set model; use the model field"}

      id = Enum.find(@harness_mode_ids, &Map.has_key?(config, &1)) ->
        {:error,
         "cannot set #{id}: the runtime's permission mode follows the agent's " <>
           "permission_policy, which a conversation may narrow and never widen"}

      bad = Enum.find(config, fn {_, value} -> not valid_value?(value) end) ->
        {:error,
         "option #{elem(bad, 0)} must be a string of 1 to #{@max_value_length} characters " <>
           "or a boolean"}

      true ->
        :ok
    end
  end

  def check(_config), do: {:error, "must be an object of option id to value"}

  @doc "Adds `check/1`'s fault to `field` of a changeset."
  @spec validate(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case check(value) do
        :ok -> []
        {:error, message} -> [{field, message}]
      end
    end)
  end

  @doc """
  The options a turn requests: the agent's, overridden by the
  conversation's, overridden by the prompt's. Any layer may be nil.

  A harness mode id is dropped from every layer, and a warning names the ids
  dropped. `check/1` refuses them at every door, so only a row written before
  that refusal still holds one; the turn runs without it rather than failing.
  """
  @spec effective(map() | nil, map() | nil, map() | nil) :: t()
  def effective(agent, conversation, prompt) do
    [config_of(agent), config_of(conversation), prompt || %{}]
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
    |> without_harness_modes()
  end

  @doc """
  `config` without the harness mode ids, logging the ids it dropped (the ids
  only, not the values). For stored rows and opened turns that predate
  `check/1`'s refusal.
  """
  @spec without_harness_modes(map() | nil) :: t()
  def without_harness_modes(nil), do: %{}

  def without_harness_modes(config) when is_map(config) do
    case Enum.filter(@harness_mode_ids, &Map.has_key?(config, &1)) do
      [] ->
        config

      dropped ->
        Logger.warning(
          "session_config: dropped #{Enum.join(dropped, ", ")} stored before " <>
            "harness modes were refused (ADR 0062 addendum, 2026-10-14)"
        )

        Map.drop(config, dropped)
    end
  end

  @doc """
  The adapter's advertised option list without the harness mode options:
  what Fountain stores and serves as a conversation's
  `session_config_options`. `nil` stays `nil` (no turn has reported any).
  """
  @spec offered([map()] | nil) :: [map()] | nil
  def offered(nil), do: nil

  def offered(options) when is_list(options),
    do: Enum.reject(options, &(is_map(&1) and Map.get(&1, "id") in @harness_mode_ids))

  defp config_of(%{session_config: config}) when is_map(config), do: config
  defp config_of(_), do: %{}

  defp valid_id?(id), do: is_binary(id) and Regex.match?(@id_pattern, id)

  defp valid_value?(value) when is_boolean(value), do: true

  defp valid_value?(value) when is_binary(value),
    do: String.length(value) in 1..@max_value_length and not String.contains?(value, <<0>>)

  defp valid_value?(_value), do: false
end
