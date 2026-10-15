defmodule Fountain.Conversations.Labels do
  @moduledoc """
  The rule for a conversation's labels (#1637), in one place.

  A label is a free-form `key => value` pair of strings on the conversation
  row. A person titles and searches their own threads; a program running in a
  long-lived conversation wants to slice its runs by facts it knew when the turn ended —
  `env=prod`, `drift=true`, `gated=apply`. Those facts are not text worth
  searching, so they are not in the full-text index and never will be.

  Every door that writes labels goes through `changeset/1` here, so the
  limits cannot drift between the create request, the labels route and the
  ACP extension notification:

    * at most 32 entries;
    * a key is a non-empty string of at most 64 bytes;
    * a value is a string of at most 256 bytes;
    * neither may contain a NUL byte, which Postgres refuses inside `jsonb`.

  A refusal names the offending key, because a caller sending thirty-two of
  them cannot otherwise tell which one Fountain disliked. On a merge the key
  named is one the caller actually sent — see `check_merge/2`.

  ## Merge, and how a key is removed

  Writes merge (`merge/2`): a key that is not mentioned is left alone. A key
  whose value is `null` is removed. That is what lets a run add one label
  without reading the others first, and what makes a channel resume keep the
  labels the binding already carried.

  ## The list filter

  `GET /api/conversations?label=env:prod&label=drift:true` is repeatable and
  AND-combined. Each value splits on its **first** colon only, so
  `label=path:a:b` filters `path` for `a:b`. The query is jsonb containment,
  which the GIN index on the column serves.
  """

  import Ecto.Changeset, only: [get_change: 2, add_error: 3]

  require Logger

  @max_entries 32
  @max_key_bytes 64
  @max_value_bytes 256

  @doc "At most this many labels on one conversation."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc "A label key is at most this many bytes."
  @spec max_key_bytes() :: pos_integer()
  def max_key_bytes, do: @max_key_bytes

  @doc "A label value is at most this many bytes."
  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes, do: @max_value_bytes

  @doc """
  Validate the `:labels` change on a conversation changeset.

  Called from `Fountain.Conversations.Conversation.changeset/2`, which is the
  only writer of the column, so every door inherits it. It sees the *merged*
  map, which is the right thing to enforce and the wrong thing to word a
  count refusal from; `Fountain.Conversations._unsafe_merge_labels/3` runs
  `check_merge/2` first for that reason.
  """
  @spec changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def changeset(changeset) do
    case get_change(changeset, :labels) do
      nil -> changeset
      labels -> apply_check(changeset, check(labels))
    end
  end

  defp apply_check(changeset, :ok), do: changeset
  defp apply_check(changeset, {:error, message}), do: add_error(changeset, :labels, message)

  @doc """
  Whether `labels` is a legal label map. `:ok`, or `{:error, message}` naming
  the offending key.
  """
  @spec check(term()) :: :ok | {:error, String.t()}
  def check(labels) when is_map(labels) do
    with :ok <- check_entries(labels), do: check_count(labels)
  end

  def check(_labels), do: {:error, "must be an object of string keys and string values"}

  @doc """
  Check what merging `incoming` into `current` would produce, wording the
  refusal from the write the caller actually made.

  `check/1` alone would blame an arbitrary key for the count: merging one new
  label into a conversation that already holds 32 puts a *pre-existing* key
  over the boundary in sorted order, and telling somebody their write of
  `run` failed because of `env` — a label they never touched — sends them to
  fix the wrong thing. So the count is reported against the first key this
  write adds.

  Entry-level problems need no such care: `current` is already on the row and
  therefore already legal, so any entry `check/1` rejects came from
  `incoming`.
  """
  @spec check_merge(map(), term()) :: :ok | {:error, String.t()}
  def check_merge(current, incoming) when is_map(current) and is_map(incoming) do
    merged = merge(current, incoming)

    with :ok <- check_entries(merged) do
      check_merged_count(current, incoming, merged)
    end
  end

  def check_merge(_current, incoming), do: check(incoming)

  defp check_merged_count(current, incoming, merged) do
    if map_size(merged) > @max_entries do
      {:error,
       "at most #{@max_entries} labels; #{describe(blamed_key(current, incoming, merged))} does not fit"}
    else
      :ok
    end
  end

  # The first key of this write that does not fit.
  #
  # The labels already on the row are kept — the caller did not ask to change
  # them — so the room left is the ceiling minus what survives the merge, and
  # what spills past it is one of the keys this write added. Adding `run` to a
  # conversation that already holds 32 therefore names `run`, and sending 33
  # at once names the 33rd rather than the first.
  #
  # The fallback covers a write that adds nothing and is over the limit
  # anyway, which only a row already past the ceiling can produce.
  defp blamed_key(current, incoming, merged) do
    retained = Enum.count(Map.keys(current), &(not removed?(incoming, &1)))

    added =
      incoming
      |> Enum.reject(fn {key, value} -> is_nil(value) or Map.has_key?(current, key) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort_by(&describe/1)
      |> Enum.drop(max(@max_entries - retained, 0))

    case added do
      [key | _] -> key
      [] -> merged |> Map.keys() |> Enum.sort_by(&describe/1) |> Enum.at(@max_entries)
    end
  end

  defp removed?(incoming, key), do: Map.has_key?(incoming, key) and is_nil(Map.get(incoming, key))

  defp check_count(labels) do
    if map_size(labels) > @max_entries do
      # Sorted, so the key named is the same one on every run rather than
      # whichever the map happened to iterate to last.
      over = labels |> Map.keys() |> Enum.sort_by(&describe/1) |> Enum.at(@max_entries)

      {:error, "at most #{@max_entries} labels; #{describe(over)} does not fit"}
    else
      :ok
    end
  end

  defp check_entries(labels) do
    labels
    |> Enum.sort_by(fn {key, _value} -> describe(key) end)
    |> Enum.reduce_while(:ok, fn {key, value}, _acc ->
      case check_entry(key, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_entry(key, _value) when not is_binary(key),
    do: {:error, "label key #{describe(key)} must be a string"}

  defp check_entry("", _value), do: {:error, "a label key must not be empty"}

  defp check_entry(key, _value) when byte_size(key) > @max_key_bytes,
    do: {:error, "label key #{describe(key)} is longer than #{@max_key_bytes} bytes"}

  defp check_entry(key, value) when not is_binary(value),
    do: {:error, "label #{describe(key)} must have a string value"}

  defp check_entry(key, value) when byte_size(value) > @max_value_bytes,
    do: {:error, "label #{describe(key)} has a value longer than #{@max_value_bytes} bytes"}

  # Postgres refuses a NUL byte inside a jsonb string, so without this clause
  # the write reaches `Repo.update` and comes back as a raised
  # `Postgrex.Error` — a 500 on the HTTP doors, and on the ACP path a raise
  # that would travel up through the turn machine and take the conversation's
  # server down with the turn it was running.
  defp check_entry(key, value) do
    cond do
      nul?(key) -> {:error, "label key #{describe(key)} must not contain a NUL byte"}
      nul?(value) -> {:error, "label #{describe(key)} must not have a NUL byte in its value"}
      true -> :ok
    end
  end

  defp nul?(binary) when is_binary(binary), do: String.contains?(binary, <<0>>)

  # The key, quoted, for a message a caller reads. An over-long key is cut
  # rather than echoed whole: the message identifies which entry to fix, and a
  # 4KB key in an error body helps nobody. Cut by bytes, because bytes are
  # what the limit is measured in — and then backed off to a whole codepoint,
  # since a message sliced through the middle of one is not valid UTF-8 and
  # `Jason.encode!` would raise on it instead of rendering the 422.
  defp describe(key) when is_binary(key) do
    shown =
      if byte_size(key) > @max_key_bytes,
        do: cut(key, @max_key_bytes) <> "...",
        else: key

    ~s("#{shown}")
  end

  defp describe(key), do: inspect(key)

  defp cut(_binary, bytes) when bytes <= 0, do: ""

  defp cut(binary, bytes) do
    candidate = binary_part(binary, 0, bytes)
    if String.valid?(candidate), do: candidate, else: cut(binary, bytes - 1)
  end

  @doc """
  Merge `incoming` into `current`. A key with a `nil` value is removed; a key
  that is absent is left alone.

  Nothing is validated here — the merged map goes through `changeset/1` on
  its way to the row, so a write that would break a limit is refused with the
  key named rather than half-applied.
  """
  @spec merge(map() | nil, map()) :: map()
  def merge(current, incoming) when is_map(incoming) do
    Enum.reduce(incoming, current || %{}, fn
      {key, nil}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  @doc """
  Which keys `merge/2` would change, as `{written, removed}` — both sorted,
  both keys only.

  The audit trail records these and never the values (ADR 0013).
  """
  @spec changed_keys(map() | nil, map()) :: {[String.t()], [String.t()]}
  def changed_keys(current, incoming) when is_map(incoming) do
    current = current || %{}

    {removed, written} =
      incoming
      |> Enum.filter(fn {key, value} -> Map.get(current, key, :absent) != value end)
      |> Enum.split_with(fn {_key, value} -> is_nil(value) end)

    {written |> Enum.map(&to_string(elem(&1, 0))) |> Enum.sort(),
     removed
     |> Enum.map(&to_string(elem(&1, 0)))
     |> Enum.filter(&Map.has_key?(current, &1))
     |> Enum.sort()}
  end

  @doc """
  Merge the labels an agent stamped on its own run over the ACP extension
  notification (#1637).

  Unscoped, hence the prefix: it takes a bare conversation id and writes to
  that row without a `user_id` and without a credential check. The only
  caller is `Fountain.Conversations.TurnMachine`, running inside the
  conversation's own `ConversationServer`, holding the id that server was
  started with — so it cannot name another tenant's conversation, or another
  conversation of the same tenant. A request-shaped caller wants
  `Fountain.Conversations.set_conversation_labels/4`, which scopes by
  `user_id` and applies the sandbox rule.

  Recorded as `sprite` — code in the sandbox acting on the tenant's behalf
  (ADR 0013).

  **Nothing a label contains can take the turn down.** A stamp the limits
  refuse is logged and dropped, and so is one that raises on its way to the
  database. The run is mid-turn and doing real work, and losing it because a
  value was 300 bytes long, or held a byte `jsonb` will not store, would be
  the worse outcome by a distance.
  """
  @spec _unsafe_stamp(String.t() | nil, map()) :: :ok
  def _unsafe_stamp(conversation_id, labels)

  def _unsafe_stamp(conversation_id, labels)
      when is_binary(conversation_id) and is_map(labels) do
    # ownership: `conversation_id` is the id the calling `ConversationServer`
    # was started with, held by its own turn machine. It cannot name another
    # conversation, so both unscoped calls below are on this server's own row.
    with %{} = conv <- Fountain.Conversations._unsafe_get_conversation(conversation_id),
         {:error, changeset} <-
           Fountain.Conversations._unsafe_merge_labels(conv, labels, actor: "sprite") do
      Logger.warning(
        "conv #{conversation_id}: refused _fountain/labels update: #{inspect(changeset.errors)}"
      )
    end

    :ok
  rescue
    error ->
      # The belt to `check_entry/2`'s braces. Every shape we know of is
      # refused above with a message; this is here so that a shape we do not
      # know of costs the stamp and not the turn.
      Logger.warning(
        "conv #{conversation_id}: _fountain/labels update raised: #{Exception.message(error)}"
      )

      :ok
  end

  def _unsafe_stamp(_conversation_id, _labels), do: :ok

  @doc """
  Every `label` value in a raw query string, in the order they were sent.

  Read from the query string rather than from the parsed params because Plug
  collapses a repeated key to its last value, and the filter is repeatable by
  design. `label[]=` is accepted as well, for a client whose HTTP layer only
  builds arrays that way.
  """
  @spec from_query_string(String.t() | nil) :: [String.t()]
  def from_query_string(nil), do: []

  def from_query_string(query) when is_binary(query) do
    for {key, value} <- URI.query_decoder(query), key in ["label", "label[]"], do: value
  end

  @doc """
  Turn repeated `key:value` filter values into the map the list query
  contains against. Splits on the first colon only, so a value may contain
  colons of its own.

  `{:error, :invalid_label_filter}` for a value with no colon or an empty
  key: a caller who typed `?label=prod` meant something, and matching
  everything would be the wrong guess.
  """
  @spec parse_filter([String.t()] | nil) :: {:ok, map()} | {:error, :invalid_label_filter}
  def parse_filter(nil), do: {:ok, %{}}

  def parse_filter(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, acc} ->
      case value |> to_string() |> String.trim() |> String.split(":", parts: 2) do
        ["" | _] -> {:halt, {:error, :invalid_label_filter}}
        [key, filter_value] -> {:cont, {:ok, Map.put(acc, key, filter_value)}}
        [_no_colon] -> {:halt, {:error, :invalid_label_filter}}
      end
    end)
  end
end
