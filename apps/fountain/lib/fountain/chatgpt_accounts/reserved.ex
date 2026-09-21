defmodule Fountain.ChatGPTAccounts.Reserved do
  @moduledoc """
  Names reserved for Fountain-managed ChatGPT credentials (ADR 0052).

  Configuration may neither name the managed input nor embed its placeholder.
  This is shared by binding writes and protected compilation of persisted data.
  It does not identify arbitrary secrets: the managed grant must still travel
  separately from environment, vault and ordinary broker inputs.
  """

  @key "CODEX_CHATGPT_ACCESS_TOKEN"
  @placeholder "__codex_chatgpt_access_token__"

  def key, do: @key
  def placeholder, do: @placeholder

  @doc false
  def validate_changeset(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, cs ->
      if conflict?(Ecto.Changeset.get_field(cs, field)),
        do: Ecto.Changeset.add_error(cs, field, "is reserved for managed ChatGPT credentials"),
        else: cs
    end)
  end

  @doc "Whether configuration contains a reserved name, placeholder or typed grant."
  def conflict?(%Fountain.ChatGPTAccounts.Grant{}), do: true
  def conflict?(%_{} = value), do: value |> Map.from_struct() |> conflict?()

  def conflict?(value) when is_map(value),
    do: Enum.any?(value, fn {key, value} -> conflict?(key) or conflict?(value) end)

  def conflict?(value) when is_list(value), do: Enum.any?(value, &conflict?/1)
  def conflict?(value) when is_tuple(value), do: value |> Tuple.to_list() |> conflict?()

  def conflict?(value) when is_binary(value),
    do: String.contains?(String.downcase(value), String.downcase(@key))

  def conflict?(_value), do: false
end
