defmodule Fountain.Broker.Native.Sessions do
  @moduledoc """
  The native broker's session store: Fountain's `Managoat.Broker.Store`.

  `Fountain.Broker.Native.prepare/4` mints a session here for one
  conversation: a random token, stored hashed; the `Managoat.Broker.Rule`s
  the proxy may apply, with the credentials inside them, as one ciphertext
  under the tenant's DEK (exactly as the environment and vault rows hold
  the same values); the unmatched-host policy; a TTL; and a `meta` map with
  the conversation and user ids for the request log. `lookup/1` is what the
  proxy calls to resolve a token, on whichever replica the ingress chose: the
  raw token from the header in, the decrypted session out, or `:error` for a
  token that is unknown, expired or undecryptable.

  It is called **once per tunnel, and once per request on the plain path**.
  Since `managoat_broker` 0.10.0 an absolute-form connection stays alive and
  carries several requests, each with its own `Proxy-Authorization`, and
  trusting the first would serve a token the proxy never checked (#1501 row
  4). That is one indexed lookup and one AES open per request there; the
  traffic is `apt` and its kin, and a tunnel -- which is every inference
  call, every clone and every `npm install` -- is unchanged at one.

  A session is not tenant-editable state and is not audited: it is
  provisioning machinery, created and deleted with the sandbox it serves,
  and the audit trail records the conversation's lifecycle instead.
  """

  @behaviour Managoat.Broker.Store

  import Ecto.Query

  alias Fountain.Broker
  alias Fountain.Broker.Native.Session
  alias Fountain.Crypto
  alias Fountain.Repo
  alias Managoat.Broker.Rule

  require Logger

  @aad "fountain.broker.rules"
  @schemes %{
    "bearer" => :bearer,
    "basic" => :basic,
    "api_key" => :api_key,
    "custom" => :custom,
    "substitute" => :substitute,
    "passthrough" => :passthrough
  }

  @doc """
  Mint a session. Returns the plaintext token exactly once; only its hash
  is stored. Expired sessions are swept on the way.
  """
  @spec create(%{
          required(:conversation_id) => String.t(),
          required(:user_id) => String.t(),
          required(:rules) => [Rule.t()],
          required(:ttl_seconds) => pos_integer(),
          optional(:unmatched_host_policy) => :passthrough | :deny,
          optional(:meta) => map()
        }) :: {:ok, Broker.session()} | {:error, term()}
  def create(%{conversation_id: _, user_id: user_id} = attrs) do
    sweep_expired()

    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      insert(attrs, dek)
    end
  end

  defp insert(%{conversation_id: conv_id, user_id: user_id} = attrs, dek) do
    token = "fb_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), attrs.ttl_seconds, :second)

    changeset =
      Session.changeset(%Session{}, %{
        token_hash: hash(token),
        conversation_id: conv_id,
        user_id: user_id,
        rules_ciphertext: Crypto.encrypt(encode_rules(attrs.rules), dek, @aad),
        unmatched_host_policy:
          Atom.to_string(Map.get(attrs, :unmatched_host_policy, :passthrough)),
        meta: Map.get(attrs, :meta, %{}),
        expires_at: expires_at
      })

    case Repo.insert(changeset) do
      {:ok, _} ->
        {:ok, %{token: token, vault: Broker.vault_name(conv_id), expires_at: expires_at}}

      {:error, changeset} ->
        {:error, {:broker, :session, changeset}}
    end
  end

  @impl Managoat.Broker.Store
  def lookup(token) when is_binary(token) do
    case Repo.get_by(Session, token_hash: hash(token)) do
      nil ->
        report(:unknown)
        :error

      %Session{} = session ->
        if DateTime.compare(session.expires_at, DateTime.utc_now()) == :lt do
          report(:expired)
          :error
        else
          case decrypt(session) do
            {:ok, _} = ok -> report(:ok, ok)
            :error -> report(:unreadable)
          end
        end
    end
  end

  @doc "Resolve a remote token without exporting any credentials."
  def remote_lookup(token) when is_binary(token) and byte_size(token) <= 128 do
    remote_read(from(s in Session, where: s.token_hash == ^hash(token)), fn row, session ->
      %{
        "authorization" => row.id,
        "expires_at" => DateTime.to_iso8601(session.expires_at),
        "policy" => Atom.to_string(session.unmatched_host_policy),
        "patterns" => Enum.map(session.rules, & &1.pattern),
        "receipt" =>
          Phoenix.Token.sign(FountainWeb.Endpoint, "remote-broker-log-v1", session.meta)
      }
    end)
  end

  @doc "Admit a remote request under a row lock shared with deletion and credential refresh."
  def remote_authorize(id, host, port) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      remote_read(from(s in Session, where: s.id == ^id), fn _row, session ->
        # Only credentials for this destination cross the control plane. The
        # proxy applies path matching, substitution and its private-IP guard.
        rules =
          Enum.filter(
            session.rules,
            &Managoat.Broker.Injector.host_matches?(&1.pattern, host, port)
          )

        %{"rules" => Jason.decode!(encode_rules(Enum.map(rules, &remote_rule/1)))}
      end)
    else
      _ -> {:error, :denied}
    end
  end

  # A custom header rule historically retains the entire brokered map.
  # Export only variables referenced by its templates, never unrelated keys.
  defp remote_rule(%Rule{scheme: :custom, template: template, credential: values} = rule) do
    keys =
      Enum.flat_map(Map.values(template), fn text ->
        Regex.scan(~r/\{\{\s*([A-Z][A-Z0-9_]*)\s*\}\}/, text, capture: :all_but_first)
        |> List.flatten()
      end)

    %{rule | credential: Map.take(values, keys)}
  end

  defp remote_rule(rule), do: rule

  defp remote_read(query, fun) do
    Repo.transaction(
      fn ->
        case Repo.one(from(s in query, lock: "FOR SHARE"), timeout: 2_000) do
          %Session{} = row ->
            if DateTime.compare(row.expires_at, DateTime.utc_now()) != :gt do
              Repo.rollback(:denied)
            end

            case decrypt(row) do
              {:ok, session} -> fun.(row, session)
              :error -> Repo.rollback(:unavailable)
            end

          nil ->
            Repo.rollback(:denied)
        end
      end,
      timeout: 3_000
    )
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # Every lookup counted by result (#1170). A sandbox whose token does not
  # resolve gets a 407, which inside the sandbox looks like the network
  # itself being broken, so a storm of these has to be visible without
  # reading logs.
  defp report(result, reply \\ :error) do
    :telemetry.execute([:fountain, :broker, :session_lookup], %{count: 1}, %{result: result})
    reply
  end

  @doc """
  Rewrite the rules of every live session of a conversation, keeping each
  token (#1736). A sandbox process holds its token in its environment for as
  long as it runs, and an idle ACP peer runs across turns, so a new session
  (a new token) reaches nothing already running. An edited or rotated secret
  reaches the proxy this way instead: the next `lookup/1` on any of the
  conversation's tokens decrypts the new rules. Returns how many rows
  changed; zero means every session had expired, and the caller mints one.
  """
  @spec update_rules(String.t(), String.t(), [Rule.t()], map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_rules(conversation_id, user_id, rules, meta)
      when is_binary(conversation_id) and is_binary(user_id) and is_list(rules) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      now = DateTime.utc_now()
      ciphertext = Crypto.encrypt(encode_rules(rules), dek, @aad)

      {n, _} =
        Repo.update_all(
          from(s in Session,
            where: s.conversation_id == ^conversation_id and s.expires_at >= ^now
          ),
          set: [rules_ciphertext: ciphertext, meta: meta, updated_at: now]
        )

      {:ok, n}
    end
  end

  @doc "Revoke one worker's token without touching a replacement's sessions."
  @spec release_session(String.t(), String.t(), String.t()) :: :ok
  def release_session(user_id, conversation_id, token)
      when is_binary(user_id) and is_binary(conversation_id) and is_binary(token) do
    token_hash = hash(token)

    Repo.delete_all(
      from s in Session,
        where:
          s.user_id == ^user_id and s.conversation_id == ^conversation_id and
            s.token_hash == ^token_hash
    )

    :ok
  end

  @doc "Delete every session of a conversation. Its tokens stop working at once."
  @spec release(String.t()) :: :ok
  def release(conversation_id) when is_binary(conversation_id) do
    Repo.delete_all(from(s in Session, where: s.conversation_id == ^conversation_id))
    :ok
  end

  @doc "Delete sessions past their end. Returns how many."
  @spec sweep_expired() :: non_neg_integer()
  def sweep_expired do
    now = DateTime.utc_now()
    {n, _} = Repo.delete_all(from(s in Session, where: s.expires_at < ^now))
    n
  end

  defp decrypt(%Session{} = s) do
    with {:ok, rules} <- rules(s) do
      {:ok,
       %Managoat.Broker.Session{
         rules: rules,
         unmatched_host_policy: String.to_existing_atom(s.unmatched_host_policy),
         expires_at: s.expires_at,
         meta: s.meta
       }}
    else
      other ->
        Logger.warning(
          "broker: session #{s.id} for conv #{s.conversation_id} is unreadable: #{inspect(other)}"
        )

        :error
    end
  end

  defp rules(%Session{} = s) do
    with {:ok, dek} <- Crypto.load_tenant_key(s.user_id),
         {:ok, json} <- Crypto.decrypt(s.rules_ciphertext, dek, @aad) do
      decode_rules(json)
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)

  # The rules as JSON. Schemes are strings and a basic credential's
  # `{user, pass}` pair is a tagged object, so the round trip is exact.
  defp encode_rules(rules) do
    rules
    |> Enum.map(fn %Rule{} = r ->
      %{
        "name" => r.name,
        "pattern" => r.pattern,
        "scheme" => Atom.to_string(r.scheme),
        "credential" => encode_credential(r.credential),
        "header" => r.header,
        "prefix" => r.prefix,
        "template" => r.template,
        "placeholder" => r.placeholder
      }
    end)
    |> Jason.encode!()
  end

  defp encode_credential({user, pass}) when is_binary(user) and is_binary(pass),
    do: %{"basic" => [user, pass]}

  defp encode_credential(other), do: other

  defp decode_rules(json) do
    with {:ok, list} when is_list(list) <- Jason.decode(json) do
      {:ok, Enum.map(list, &decode_rule/1)}
    else
      _ -> {:error, :bad_rules}
    end
  end

  defp decode_rule(map) do
    %Rule{
      name: map["name"],
      pattern: map["pattern"],
      scheme: Map.fetch!(@schemes, map["scheme"]),
      credential: decode_credential(map["credential"]),
      header: map["header"],
      prefix: map["prefix"] || "",
      template: map["template"] || %{},
      placeholder: map["placeholder"]
    }
  end

  defp decode_credential(%{"basic" => [user, pass]}), do: {user, pass}
  defp decode_credential(other), do: other
end
