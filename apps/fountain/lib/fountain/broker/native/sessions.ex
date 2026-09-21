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

  ## A session that may use a managed ChatGPT grant

  That lookup-once rule is the whole story for an ordinary session and not
  for one whose conversation runs on a managed ChatGPT grant (ADR 0052
  decisions 5 and 6, built by ADR 0060 stage 3). Such a session carries
  **which** grant as authorization data (`managed_*` columns, never a rule
  and never a bearer), and `lookup/1` answers it with three things set on the
  `Managoat.Broker.Session`: an `authorization` reference naming this row,
  `http_only: true`, and the `protected` policy for the grant's account
  (`Fountain.Broker.Native.ProtectedCompiler.policy/1`). The proxy then calls
  `authorize/2` before **every** request, inside an open tunnel too:

    * a request to the Codex backend is admitted only while the row is live
      and unrevoked **and** the grant row still says the same owner, the same
      generation, `active` and the same account
      (`Fountain.ChatGPTAccounts.protected_credential/2`). The bearer is
      decrypted for that one request and handed to the library as a
      `Managoat.Broker.ProtectedCredential`; it is in no rule, no `meta` and
      no row of this table.
    * any other request gets the session's ordinary rules, read fresh. A
      fenced grant closes the Codex backend and nothing else.

  The reference carries no authority: it names the row, and the grant id and
  generation are read from the row each time, so a copied reference or a
  copied rule set opens nothing. A failed read is `:unavailable`, never a
  cached success. No lock is taken, so nothing is held across the upstream
  response: a request admitted before a disconnect commits is in flight and
  may finish, and the next one is refused.

  `create/1` is the issuance fence, `revoke_grant/2` the invalidation a
  grant's own lifecycle transaction runs, and `update_rules/4` never writes a
  `managed_*` column, so a delayed rule rewrite cannot restore a grant or move
  a session onto a newer generation. **Not built:** closing tunnels that are
  already open on other nodes, and revoking the token upstream. Correctness
  does not wait on either, because nothing is cached per tunnel.

  A session is not tenant-editable state and is not audited: it is
  provisioning machinery, created and deleted with the sandbox it serves,
  and the audit trail records the conversation's lifecycle instead.
  """

  @behaviour Managoat.Broker.Store

  import Ecto.Query

  alias Fountain.Broker
  alias Fountain.Broker.Native.{ProtectedCompiler, Session}
  alias Fountain.ChatGPTAccounts
  alias Fountain.Crypto
  alias Fountain.Repo
  alias Managoat.Broker.{ProtectedCredential, Rule}

  require Logger

  @aad "fountain.broker.rules"

  # Every read `authorize/2` makes, the tenant key's included: it runs for
  # every egress request of a managed session, so none of them may wait on
  # the database without a bound. A read that runs out raises, and that is
  # `:unavailable`.
  @request_read [timeout: 5_000]
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

  With `:managed` (a `t:Fountain.ChatGPTAccounts.grant_ref/0`) the session may
  use that grant, and issuance is fenced: the grant row is locked and re-read
  in the transaction that inserts the session
  (`Fountain.ChatGPTAccounts.lock_active_grant/1`), so a grant disconnected,
  replaced or revoked since it was selected mints nothing, and one being
  disconnected right now either refuses this or revokes the row this writes.
  The account id stored beside the pin comes from that read, not from the
  caller. A user's grant rides only that user's own session. Refusals are
  `{:error, {:broker, :session, :managed_grant_inactive | :invalid_managed_identity}}`.
  """
  @spec create(%{
          required(:conversation_id) => String.t(),
          required(:user_id) => String.t(),
          required(:rules) => [Rule.t()],
          required(:ttl_seconds) => pos_integer(),
          optional(:unmatched_host_policy) => :passthrough | :deny,
          optional(:meta) => map(),
          optional(:managed) => ChatGPTAccounts.grant_ref() | nil
        }) :: {:ok, Broker.session()} | {:error, term()}
  def create(%{conversation_id: _, user_id: user_id} = attrs) do
    sweep_expired()

    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      case Map.get(attrs, :managed) do
        nil -> insert(attrs, dek, %{})
        %{} = ref -> create_managed(attrs, dek, ref)
      end
    end
  end

  defp create_managed(%{user_id: user_id} = attrs, dek, ref) do
    result =
      Repo.transaction(fn ->
        with {:ok, owner_id} <- session_owner(ref, user_id),
             {:ok, %{account_id: identity}} <- ChatGPTAccounts.lock_active_grant(ref),
             {:ok, _policy} <- ProtectedCompiler.policy(identity),
             {:ok, session} <-
               insert(attrs, dek, %{
                 managed_grant_id: ref.grant_id,
                 managed_grant_generation: ref.generation,
                 managed_grant_owner_id: owner_id,
                 managed_identity: identity
               }) do
          session
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, session} -> {:ok, session}
      {:error, {:broker, :session, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:broker, :session, reason}}
    end
  end

  # The deployment's grant has no owner; a user's is that user's, and the
  # session it rides is theirs too.
  defp session_owner(%{owner: :platform}, _user_id), do: {:ok, nil}
  defp session_owner(%{owner: {:user, user_id}}, user_id), do: {:ok, user_id}
  defp session_owner(_ref, _user_id), do: {:error, :managed_grant_inactive}

  defp insert(%{conversation_id: conv_id, user_id: user_id} = attrs, dek, managed) do
    token = "fb_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), attrs.ttl_seconds, :second)

    changeset =
      Session.changeset(
        %Session{},
        Map.merge(managed, %{
          token_hash: hash(token),
          conversation_id: conv_id,
          user_id: user_id,
          rules_ciphertext: Crypto.encrypt(encode_rules(attrs.rules), dek, @aad),
          unmatched_host_policy:
            Atom.to_string(Map.get(attrs, :unmatched_host_policy, :passthrough)),
          meta: Map.get(attrs, :meta, %{}),
          expires_at: expires_at
        })
      )

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

  # Every lookup counted by result (#1170). A sandbox whose token does not
  # resolve gets a 407, which inside the sandbox looks like the network
  # itself being broken, so a storm of these has to be visible without
  # reading logs.
  defp report(result, reply \\ :error) do
    :telemetry.execute([:fountain, :broker, :session_lookup], %{count: 1}, %{result: result})
    reply
  end

  @doc """
  Admit one request of a session that may use a managed grant (see the
  moduledoc). `{:ok, %ProtectedCredential{}}` for a request the proxy marked
  `protected: true`, `{:ok, rules}` for any other, `{:error, :denied}` when
  the session or the grant no longer authorizes it, `{:error, :unavailable}`
  when that could not be established. The request is never logged: its
  target may carry a credential.
  """
  @impl Managoat.Broker.Store
  def authorize({:managed, session_id}, request) when is_binary(session_id) do
    now = DateTime.utc_now()

    case Repo.one(
           from(s in Session, where: s.id == ^session_id and s.expires_at >= ^now),
           @request_read
         ) do
      nil -> {:error, :denied}
      %Session{} = session -> admit(session, Map.get(request, :protected) == true)
    end
  rescue
    error -> unavailable(session_id, inspect(error.__struct__))
  catch
    kind, _reason -> unavailable(session_id, to_string(kind))
  end

  def authorize(_reference, _request), do: {:error, :denied}

  defp admit(%Session{managed_grant_id: nil}, _protected?), do: {:error, :denied}
  defp admit(%Session{managed_revoked_at: %DateTime{}}, true), do: {:error, :denied}

  defp admit(%Session{} = session, true) do
    ref = %{
      owner:
        if(session.managed_grant_owner_id,
          do: {:user, session.managed_grant_owner_id},
          else: :platform
        ),
      grant_id: session.managed_grant_id,
      generation: session.managed_grant_generation
    }

    case ChatGPTAccounts.protected_credential(ref, session.managed_identity) do
      {:ok, %ChatGPTAccounts.Grant{access_token: bearer, source: %{account_id: identity}}} ->
        {:ok, %ProtectedCredential{bearer: bearer, identity: identity}}

      {:error, :denied} ->
        {:error, :denied}

      {:error, :unavailable} ->
        unavailable(session.id, "the grant's credential could not be read")
    end
  end

  defp admit(%Session{} = session, false) do
    case rules(session, &Crypto.load_tenant_key(&1, @request_read)) do
      {:ok, rules} -> {:ok, rules}
      _ -> unavailable(session.id, "the session's rules could not be read")
    end
  end

  # By session id and cause only. Never the request, and never an exception's
  # message: a database error can quote the statement and its parameters.
  defp unavailable(session_id, cause) do
    Logger.warning("broker: authorization for session #{session_id} is unavailable: #{cause}")
    {:error, :unavailable}
  end

  @doc """
  Revoke every live session's authority to use grant `grant_id`, at one
  `generation` or, with `:all`, at any. Returns how many rows it marked.

  Runs **inside** the transaction that disconnects, replaces, revokes or
  deletes the grant (`Fountain.ChatGPTAccounts`), so the fence and the
  invalidation commit together. The rows stay: the conversation's other
  egress keeps working, and only the Codex backend is closed to it. This is
  the fast path and not the authority; `authorize/2` denies from the grant
  row's generation and status whether or not this ever ran.
  """
  @spec revoke_grant(Ecto.UUID.t(), Ecto.UUID.t() | :all) :: non_neg_integer()
  def revoke_grant(grant_id, generation) when is_binary(grant_id) do
    query =
      from(s in Session, where: s.managed_grant_id == ^grant_id and is_nil(s.managed_revoked_at))

    query =
      case generation do
        :all ->
          query

        generation when is_binary(generation) ->
          from(s in query, where: s.managed_grant_generation == ^generation)
      end

    now = DateTime.utc_now()
    {n, _} = Repo.update_all(query, set: [managed_revoked_at: now, updated_at: now])
    n
  end

  @doc """
  Rewrite the rules of every live session of a conversation, keeping each
  token (#1736). A sandbox process holds its token in its environment for as
  long as it runs, and an idle ACP peer runs across turns, so a new session
  (a new token) reaches nothing already running. An edited or rotated secret
  reaches the proxy this way instead: the next `lookup/1` on any of the
  conversation's tokens decrypts the new rules. Returns how many rows
  changed; zero means every session had expired, and the caller mints one.

  It writes the rules and `meta` and nothing else. The `managed_*` columns are
  not in its `set:`, so a rewrite that was delayed past a disconnect or a
  reconnect can neither restore the old grant's authority nor move the session
  onto the new generation (ADR 0052 decision 5).
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
    with {:ok, rules} <- rules(s),
         {:ok, managed} <- managed_fields(s) do
      {:ok,
       struct(
         %Managoat.Broker.Session{
           rules: rules,
           unmatched_host_policy: String.to_existing_atom(s.unmatched_host_policy),
           expires_at: s.expires_at,
           meta: s.meta
         },
         managed
       )}
    else
      other ->
        Logger.warning(
          "broker: session #{s.id} for conv #{s.conversation_id} is unreadable: #{inspect(other)}"
        )

        :error
    end
  end

  # `authorize/2` bounds the key's read; `lookup/1` reads it as it always has.
  defp rules(%Session{} = s, load_key \\ &Crypto.load_tenant_key/1) do
    with {:ok, dek} <- load_key.(s.user_id),
         {:ok, json} <- Crypto.decrypt(s.rules_ciphertext, dek, @aad) do
      decode_rules(json)
    end
  end

  # What opts a session into `authorize/2`. The reference names the row and
  # nothing else; the grant is read from the row on every request.
  defp managed_fields(%Session{managed_grant_id: nil}), do: {:ok, %{}}

  defp managed_fields(%Session{} = s) do
    with {:ok, policy} <- ProtectedCompiler.policy(s.managed_identity) do
      {:ok, %{authorization: {:managed, s.id}, http_only: true, protected: policy}}
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
