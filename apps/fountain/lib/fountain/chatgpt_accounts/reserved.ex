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

  ## Names and values are held to different rules

  `conflict?/1` is for everything that can *name* a credential or say where
  one goes: a secret's key, every field of a binding, a network pattern, an
  account id. There the substring match is right, because a key or a header
  template that contains the name has no other reason to.

  A secret's **value** is opaque text the tenant owns: a script, a JSON blob,
  a certificate. One that merely mentions `codex_chatgpt_access_token` names
  nothing, and refusing it failed the write, and for a row older than the
  write's check every provision of a conversation on a grant. `value_conflict?/1`
  refuses a value only where it could stand for the managed credential: the
  reserved name and nothing else, a placeholder occurring anywhere in it (the
  deployment's or any grant's, since a `:substitute` rule rewrites a
  placeholder inside whatever text carries it), or a `{{ NAME }}` template
  reference to it (inert in a value today, because the library renders a
  template once; refused so that stays true if it ever renders twice).
  """

  @key "CODEX_CHATGPT_ACCESS_TOKEN"
  @placeholder "__codex_chatgpt_access_token__"
  @placeholder_occurrence ~r/__codex_chatgpt_access_token(?:_[0-9a-f]{32})?__/i
  @template_reference ~r/\{\{\s*codex_chatgpt_access_token\s*\}\}/i

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

  @doc false
  def validate_value(changeset, field) do
    if value_conflict?(Ecto.Changeset.get_field(changeset, field)),
      do: Ecto.Changeset.add_error(changeset, field, "is reserved for managed ChatGPT credentials"),
      else: changeset
  end

  @doc """
  Whether a secret's value could stand for the managed credential (see the
  moduledoc). Anything that is not text is held to `conflict?/1`.
  """
  @spec value_conflict?(term()) :: boolean()
  def value_conflict?(value) when is_binary(value) do
    String.downcase(String.trim(value)) == String.downcase(@key) or
      Regex.match?(@placeholder_occurrence, value) or
      Regex.match?(@template_reference, value)
  end

  def value_conflict?(value), do: conflict?(value)

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
