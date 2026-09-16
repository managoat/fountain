defmodule Fountain.Conversations.Redaction do
  @moduledoc """
  Redacts tenant secrets out of sprite output before it is persisted.

  Decrypted secrets are placed in the sprite's environment and written to
  `/home/sprite/.env`, and every byte a sprite writes to stdout or stderr is
  persisted verbatim into `log_events` and streamed over SSE. So an `env`, a
  `set -x`, a `cat .env` in someone's `setup_script`, or an agent that simply
  prints its environment, wrote plaintext credentials into Postgres — a table
  with none of the envelope encryption the secret itself has, and one that
  outlives the conversation.

  ## Why a registry rather than an argument

  A scrubber already existed for git's HTTPS token, and it was applied on the
  HTTPS clone path and *not* on the SSH one. That is the failure mode worth
  designing against: redaction that a caller has to remember will eventually be
  forgotten by a new caller.

  So the values live in an ETS table keyed by conversation, and
  `Conversations.log!/1` — the single writer for every log event — consults it.
  A new log path is redacted whether or not its author knew this module existed.

  ## The length floor

  Only values of at least #{8} bytes are redacted. Sprite environments hold
  plenty of short non-secrets (`true`, `1`, a port, a region), and redacting
  those would turn logs into noise while protecting nothing. Real credentials —
  tokens, keys, connection strings — are comfortably longer. A deliberately
  short password is the case this misses, and is worth knowing about.
  """

  use GenServer

  @table :fountain_redaction
  @min_length 8
  @placeholder "[REDACTED]"

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @doc """
  Register the values to redact for a conversation.

  Accepts the sprite env as a keyword-ish list of `{name, value}` tuples, or a
  plain list of values.
  """
  def put(conversation_id, values) when is_binary(conversation_id) and is_list(values) do
    redactable =
      values
      |> Enum.map(fn
        {_name, value} -> value
        value -> value
      end)
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @min_length))
      # Longest first: a secret that contains another as a substring must be
      # replaced whole, or the shorter match would leave a fragment behind.
      |> Enum.sort_by(&byte_size/1, :desc)
      |> Enum.uniq()

    if redactable == [] do
      delete(conversation_id)
    else
      ensure_table()
      :ets.insert(@table, {conversation_id, redactable})
    end

    :ok
  end

  def put(_conversation_id, _values), do: :ok

  @doc """
  Register more values for a conversation without forgetting any.

  `put/2` replaces, which is right for the first registration and wrong for
  every one after it. A credential rotates mid-conversation — an edited vault
  secret, a refreshed connection token — while output produced under the old
  one can still be on its way to `log_events`. So once a value has been a
  secret in this conversation, it stays redacted until the conversation ends
  and `delete/1` clears it. Over-redacting a retired credential costs nothing;
  un-redacting one that is still in flight is the disclosure.

  Reads then writes, which is safe because a conversation's registry is written
  only from its own server process.
  """
  def add(conversation_id, values) when is_binary(conversation_id) and is_list(values),
    do: put(conversation_id, lookup(conversation_id) ++ values)

  def add(_conversation_id, _values), do: :ok

  @doc "Forget a conversation's values. Called when its server stops."
  def delete(conversation_id) when is_binary(conversation_id) do
    ensure_table()
    :ets.delete(@table, conversation_id)
    :ok
  end

  def delete(_), do: :ok

  @doc """
  Replace any registered secret value appearing in `text`.

  Returns `text` unchanged when the conversation has no registered values, which
  is the common case for conversations with no secrets at all.
  """
  def redact(conversation_id, text) when is_binary(conversation_id) and is_binary(text) do
    case lookup(conversation_id) do
      [] -> text
      values -> :binary.replace(text, values, @placeholder, [:global])
    end
  end

  def redact(_conversation_id, text), do: text

  @doc "Values registered for a conversation. Empty when none or unavailable."
  def lookup(conversation_id) when is_binary(conversation_id) do
    ensure_table()

    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, values}] -> values
      _ -> []
    end
  catch
    :error, :badarg -> []
  end

  def lookup(_), do: []

  def min_length, do: @min_length
  def placeholder, do: @placeholder

  # The table is owned by this GenServer. Tests and any caller that runs before
  # the supervision tree is up should degrade to "no redaction registered"
  # rather than crash the operation being logged.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc """
  A `ConversationServer` state with every secret in it replaced, for
  `format_status/1` (#315).

  An unhandled raise in any callback logs `State:` through `inspect`. Without
  this that meant plaintext env secrets, the raw tenant DEK, decrypted BYO
  inference credentials, the callback API key and the platform Sprites token
  (inside `sprite.client`) on stdout and, with `SENTRY_DSN` set, in a Sentry
  event body. Sentry's PlugContext scrubbing never sees process crash reports,
  so the redaction has to happen at the server.

  Key names are kept and only values are replaced, so crash reports stay
  debuggable.

  The list is the whole point, and it has fallen behind the state twice
  (#1690): `brokered` and `broker` arrived with the egress broker
  (#1136/#1150), `resolved_mcp_servers` with the one-substitution-pass fix
  (#1511), and none of them were scrubbed. Reviewing that fix found three
  more — the sandbox command's adapter-owned client, the turn's prompt and
  reply text, and the runner reattach buffer, which is fed raw sandbox bytes
  that never pass a log writer. `ConversationServerRedactionTest`'s field
  guard now fails for a new state field until it is either redacted here or
  classified as plaintext there, so the next one cannot arrive quietly.
  """
  def server_state(state) do
    %{
      state
      | handle: state.handle && %{state.handle | private: nil},
        sprite_env: Enum.map(state.sprite_env, fn {k, _v} -> {k, @placeholder} end),
        # ADR 0019: `Broker.split/2` leaves placeholders in the sandbox env and
        # puts the real values here, so this map — not `sprite_env` — is where
        # a brokered GITHUB_TOKEN, connection token or inference key lives.
        brokered: secrets(state.brokered),
        # The minted proxy session: `%{vault, token, expires_at}`. Every value
        # goes rather than the token alone, so a field added to the session
        # shape is redacted the day it appears; the vault and the expiry are
        # already published on the `broker` stage event.
        broker: secrets(state.broker),
        env_credentials: secrets(state.env_credentials),
        resolved_mcp_servers: deep_redact(state.resolved_mcp_servers),
        # The same adapter-owned `private` that `handle` carries — for Sprites,
        # the client struct holding the platform bearer token. Both structs
        # `@derive` a narrow `Inspect`, but that is the dependency's choice to
        # change, not a property this server can rely on.
        current_command: state.current_command && %{state.current_command | private: nil},
        current_turn: turn(state.current_turn),
        # The cached permission request includes raw tool input. Keep the
        # request id and parameter keys, but not tenant-supplied text.
        acp_request_params: deep_redact(state.acp_request_params),
        # The bounded execution journal can carry provider error text. The
        # current turn above retains the identity needed to find its journal.
        turn_execution: secrets(state.turn_execution),
        runner_replay: replay(state.runner_replay),
        tenant_key: secret(state.tenant_key),
        inference_credentials: secrets(state.inference_credentials),
        callback_token: secret(state.callback_token),
        turn_session_retry: secret(state.turn_session_retry)
    }
  end

  @doc """
  `server_state/1` applied to the `:state` entry of a `format_status/1` map.
  """
  def server_status(status) do
    Map.new(status, fn
      {:state, %{conversation_id: _} = state} -> {:state, server_state(state)}
      other -> other
    end)
  end

  # A struct is not enumerable, so it cannot be walked key by key. Replacing it
  # whole is the safe reading: `format_status/1` raising is itself a leak, since
  # OTP then reports the unredacted state.
  defp secrets(%_{}), do: @placeholder
  defp secrets(%{} = map), do: Map.new(map, fn {k, _v} -> {k, @placeholder} end)
  defp secrets(other), do: secret(other)

  defp secret(nil), do: nil
  defp secret(_present), do: @placeholder

  # `resolved_mcp_servers` is the agent's MCP document with `${VAR}` already
  # substituted (#1404/#1511): a header written `Bearer ${GITHUB_TOKEN}` holds
  # the token itself, and so does a server's `env`. Which servers were resolved
  # is exactly the debugging signal worth keeping, so every key and the shape of
  # the document survive and only the leaves go.
  #
  # Tuples and charlists cannot appear in an Ecto `:map` decoded from JSON, so
  # the last two clauses are for the day the field's shape changes: a keyword
  # list is a list of tuples, and a charlist is a list of integers that a
  # crash report prints as text.
  defp deep_redact(nil), do: nil
  defp deep_redact(%_{}), do: @placeholder
  defp deep_redact(%{} = map), do: Map.new(map, fn {k, v} -> {k, deep_redact(v)} end)

  defp deep_redact([_ | _] = list),
    do: if(charlist?(list), do: @placeholder, else: redact_each(list))

  defp deep_redact(list) when is_list(list), do: list
  defp deep_redact(value) when is_binary(value), do: @placeholder

  defp deep_redact(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> redact_each() |> List.to_tuple()

  defp deep_redact(other), do: other

  defp redact_each(list), do: Enum.map(list, &deep_redact/1)

  defp charlist?(list), do: List.ascii_printable?(list)

  # Everything a `%Turn{}` holds that is not on this list — the prompt, the
  # reply text, the pending permission request, the usage map — is tenant
  # content, and a crash report goes to a third-party processor when
  # `SENTRY_DSN` is set. Keeping the list of identity fields rather than
  # naming the content fields means a text field added to the schema is
  # redacted the day it appears.
  @turn_identity_fields [
    :id,
    :conversation_id,
    :turn_number,
    :status,
    :origin,
    :exit_code,
    :acp_prompt_id,
    :started_at,
    :ended_at,
    :orphaned_at,
    :inserted_at
  ]

  defp turn(nil), do: nil

  defp turn(%_{} = turn) do
    turn
    |> Map.from_struct()
    |> Enum.reduce(turn, fn
      # Nothing to redact, and both read better left alone in a report.
      {_key, nil}, acc -> acc
      {_key, %Ecto.Association.NotLoaded{}}, acc -> acc
      {:__meta__, _value}, acc -> acc
      {key, _value}, acc when key in @turn_identity_fields -> acc
      {key, _value}, acc -> Map.put(acc, key, @placeholder)
    end)
  end

  defp turn(other), do: secrets(other)

  # The runner reattach buffer is fed raw sandbox bytes before anything reaches
  # a log writer, so `redact/2` — which protects every persisted byte — never
  # sees them. Up to 4 MiB of agent output can be sitting here when a callback
  # raises. The boundary id and the buffer's size are what a reattach crash is
  # diagnosed from, so both survive.
  defp replay(nil), do: nil

  defp replay(%{buffer: buffer} = replay) when is_binary(buffer),
    do: %{replay | buffer: "#{@placeholder} #{byte_size(buffer)} bytes"}

  defp replay(other), do: secrets(other)
end
