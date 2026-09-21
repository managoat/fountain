defmodule Fountain.ChatGPTAccounts.Reserved do
  @moduledoc """
  Names reserved for Fountain-managed ChatGPT credentials (ADR 0052).

  Configuration may neither name the managed input nor embed its placeholder.
  This is shared by binding writes and protected compilation of persisted data.
  It does not identify arbitrary secrets: the managed grant must still travel
  separately from environment, vault and ordinary broker inputs.

  A grant on the protected broker path has a placeholder of its own
  (`placeholder/1`, ADR 0060 decision 6), so a sandbox file read out of place
  says which grant it stood for. `conflict?/1` is a case-insensitive
  substring match on the reserved key, and every per-grant placeholder
  contains it, so all of them are refused with no list of grants to consult.
  """

  @key "CODEX_CHATGPT_ACCESS_TOKEN"
  @placeholder "__codex_chatgpt_access_token__"

  def key, do: @key
  def placeholder, do: @placeholder

  @doc """
  What stands where the bearer would in the sandbox `auth.json` of the grant
  `grant_id`. Not a secret and not authority: the broker ignores whatever
  bearer the client sends to the Codex backend and supplies the session's
  own.
  """
  @spec placeholder(Ecto.UUID.t()) :: String.t()
  def placeholder(grant_id) when is_binary(grant_id) do
    "__codex_chatgpt_access_token_" <>
      (grant_id |> String.downcase() |> String.replace("-", "")) <> "__"
  end

  @doc "Whether `value` is some grant's `placeholder/1`."
  @spec placeholder?(term()) :: boolean()
  def placeholder?(value) when is_binary(value),
    do: Regex.match?(~r/\A__codex_chatgpt_access_token_[0-9a-f]{32}__\z/, value)

  def placeholder?(_value), do: false

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
