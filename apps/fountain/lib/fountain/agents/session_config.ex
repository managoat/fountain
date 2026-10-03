defmodule Fountain.Agents.SessionConfig do
  @moduledoc """
  The ACP session config options a turn asks its adapter for (ADR 0062):
  reasoning effort, fast mode, whatever the adapter advertises beyond the
  model. A map of option id to value, a string or a boolean.

  Three layers, each overriding the one before:

    1. the agent's `session_config`,
    2. the conversation's `session_config`, set at launch or by reapply,
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
  """

  import Ecto.Changeset

  @max_options 16
  @max_value_length 200
  @id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/

  @type t :: %{optional(String.t()) => String.t() | boolean()}

  def max_options, do: @max_options
  def max_value_length, do: @max_value_length
  def id_pattern, do: @id_pattern

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
  """
  @spec effective(map() | nil, map() | nil, map() | nil) :: t()
  def effective(agent, conversation, prompt) do
    [config_of(agent), config_of(conversation), prompt || %{}]
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
  end

  defp config_of(%{session_config: config}) when is_map(config), do: config
  defp config_of(_), do: %{}

  defp valid_id?(id), do: is_binary(id) and Regex.match?(@id_pattern, id)

  defp valid_value?(value) when is_boolean(value), do: true

  defp valid_value?(value) when is_binary(value),
    do: String.length(value) in 1..@max_value_length and not String.contains?(value, <<0>>)

  defp valid_value?(_value), do: false
end
