defmodule Fountain.Connections do
  @moduledoc """
  Connections (ADR 0085): a user's OAuth grant to one remote MCP server,
  named by the server's URL. Every read and write here takes the owner's
  user id, so a user-facing caller passes the signed-in user's and reaches
  nothing else.

  ## Connecting

  `create/3` discovers the server's authorization server, registers a
  client (`Fountain.Connections.OAuth.register/3`), stores a `pending` row
  with the PKCE verifier and a login nonce, and returns the URL to send the
  user to. The provider sends the browser back to `redirect_uri/0` with a
  `state` that is signed, lives ten minutes and names the connection, its
  user and the nonce; `complete/3` checks all three against the signed-in
  user and the row, checks `iss` where the server promised it (RFC 9207),
  exchanges the code and stores the grant. `authorize/3` starts another
  login on an existing connection (reconnect).

  ## Holding the tokens

  As `Fountain.ChatGPT` holds a subscription's: a refresh takes a short
  lease on the row by one conditional `UPDATE`, calls the token endpoint
  with no transaction open, and writes the rotated pair back by
  compare-and-swap on the lease and the spent refresh token, retrying the
  write. `invalid_grant` marks the row `revoked`. An access token that has
  lapsed with no refresh token to renew it marks the row `expired`.

  Whenever Managoat lets go of a grant it revokes it at the provider's
  `revocation_endpoint`, when there is one: on `delete/3`, for the grant a
  reconnect replaces, for tokens a login obtained but could not store, for a
  refresh's tokens that a reconnect or a delete overtook, and on account
  deletion. The call runs after the local write has committed, outside any
  transaction, and its failure never undoes that write.

  ## Delivery

  `token_for_session/2` is what a conversation's broker rule carries
  (`Fountain.Conversations.McpConnections`): the stored access token,
  refreshed first when it expires within ten minutes. A conversation's
  server makes that exchange in a task, never in its own process. The token itself
  never reaches a sandbox, an agent record, a transcript or a log.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.{Audit, Crypto, PublicUrl, Repo}
  alias Fountain.Connections.{Connection, OAuth}

  @refresh_margin_seconds 10 * 60
  @login_max_age 10 * 60
  @lease_seconds 60
  @store_backoff_ms [200, 1_000]
  @state_salt "connection login"
  @key_prefix "MANAGOAT_CONNECTION_"
  @max_authorize_params 20
  @reserved_params ~w(client_id redirect_uri response_type state code_challenge code_challenge_method resource scope)

  # ── reads ──────────────────────────────────────────────────────────────────

  @doc "The user's connections, newest first."
  @spec list(Ecto.UUID.t()) :: [Connection.t()]
  def list(user_id) when is_binary(user_id) do
    Repo.all(
      from c in Connection,
        where: c.user_id == ^user_id,
        order_by: [desc: c.inserted_at, asc: c.id]
    )
  end

  @doc "One of the user's connections, or nil."
  @spec get(term(), Ecto.UUID.t()) :: Connection.t() | nil
  def get(id, user_id) when is_binary(user_id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(Connection, id: id, user_id: user_id)
      :error -> nil
    end
  end

  # ── wiring ─────────────────────────────────────────────────────────────────

  @doc "Where every provider sends the browser back. One path for all connections, so a client ID metadata document and a pasted client can list it."
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: PublicUrl.base() <> "/connections/callback"

  @doc "The URL of Managoat's client ID metadata document, which is also the client id it names."
  @spec client_id_metadata_url() :: String.t()
  def client_id_metadata_url, do: PublicUrl.base() <> "/connections/client.json"

  @doc "The client ID metadata document served at `client_id_metadata_url/0`."
  @spec client_metadata() :: map()
  def client_metadata do
    %{
      "client_id" => client_id_metadata_url(),
      "client_name" => "Managoat",
      "client_uri" => PublicUrl.base(),
      "redirect_uris" => [redirect_uri()],
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    }
  end

  @doc """
  The env key a connection's token travels under to the broker. Reserved:
  no environment, vault or binding key may start with `#{@key_prefix}`.
  """
  @spec broker_key(Ecto.UUID.t()) :: String.t()
  def broker_key(id), do: @key_prefix <> (id |> String.replace("-", "") |> String.upcase())

  @doc "Whether a secret or binding key is in the range connections reserve."
  @spec reserved_key?(term()) :: boolean()
  def reserved_key?(key) when is_binary(key), do: String.starts_with?(key, @key_prefix)
  def reserved_key?(_), do: false

  @doc "Refuse a secret or binding key in the range connections reserve."
  @spec validate_unreserved_key(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_unreserved_key(changeset, field) do
    Ecto.Changeset.validate_change(changeset, field, fn ^field, key ->
      if reserved_key?(key),
        do: [{field, "must not start with #{@key_prefix}, which connections reserve"}],
        else: []
    end)
  end

  # ── connecting ─────────────────────────────────────────────────────────────

  @doc """
  Connect a remote MCP server by its URL: discover, register, store a
  `pending` row and return it with the URL to send the user to.

  `attrs` (string keys): `"url"`, and optionally `"client_id"` and
  `"client_secret"` (a client the user registered with the provider) and
  `"authorize_params"` (extra authorize parameters, such as Google's
  `access_type=offline` and `prompt=consent`). A pasted client wins over
  the other registrations.

  `{:error, reason}`: `:invalid_url`, `:invalid_authorize_params`,
  `{:connection_exists, id}`, `:client_required` (the server offers no
  registration Managoat can use, so a client must be pasted), or a discovery
  or registration failure (`error_message/1` words each).
  """
  @spec create(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Connection.t(), String.t()} | {:error, term()}
  def create(user_id, attrs, opts \\ []) when is_binary(user_id) and is_map(attrs) do
    with {:ok, url} <- url(attrs["url"]),
         {:ok, extra} <- authorize_params(attrs["authorize_params"]),
         {:ok, meta} <- OAuth.discover(url),
         :ok <- not_connected(user_id, meta.resource),
         {:ok, client} <- choose_client(meta, attrs),
         {:ok, conn, authorize_url} <- insert_pending(user_id, url, meta, client, extra) do
      audit(conn, "created", opts, %{
        "resource" => conn.resource,
        "registration" => conn.registration
      })

      {:ok, conn, authorize_url}
    end
  end

  defp url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> {:ok, url}
      _ -> {:error, :invalid_url}
    end
  end

  defp url(_), do: {:error, :invalid_url}

  defp authorize_params(nil), do: {:ok, %{}}

  defp authorize_params(params)
       when is_map(params) and map_size(params) <= @max_authorize_params do
    valid? =
      Enum.all?(params, fn {k, v} ->
        is_binary(k) and k != "" and byte_size(k) <= 100 and k not in @reserved_params and
          is_binary(v) and byte_size(v) <= 500
      end)

    if valid?, do: {:ok, params}, else: {:error, :invalid_authorize_params}
  end

  defp authorize_params(_), do: {:error, :invalid_authorize_params}

  defp not_connected(user_id, resource) do
    case Repo.one(
           from c in Connection,
             where: c.user_id == ^user_id and c.resource == ^resource,
             select: c.id
         ) do
      nil -> :ok
      id -> {:error, {:connection_exists, id}}
    end
  end

  defp choose_client(meta, attrs) do
    pasted = present(attrs["client_id"])

    cond do
      pasted ->
        OAuth.register(meta, {:pasted, pasted, present(attrs["client_secret"])})

      meta.client_id_metadata_document_supported and https_base?() ->
        OAuth.register(meta, :client_id_metadata_document,
          client_id_metadata_url: client_id_metadata_url()
        )

      is_binary(meta.registration_endpoint) ->
        OAuth.register(meta, :dynamic, redirect_uri: redirect_uri(), client_uri: PublicUrl.base())

      true ->
        {:error, :client_required}
    end
  end

  # A provider fetches the client ID metadata document itself, so it must be
  # reachable over https.
  defp https_base?, do: String.starts_with?(PublicUrl.base(), "https://")

  defp insert_pending(user_id, url, meta, client, extra) do
    id = Ecto.UUID.generate()
    nonce = nonce()
    verifier = OAuth.code_verifier()
    draft = %Connection{id: id, user_id: user_id}

    with {:ok, verifier_ct} <- seal(draft, :login_verifier, verifier),
         {:ok, secret_ct} <- seal_optional(draft, :client_secret, client.client_secret),
         {:ok, conn} <-
           draft
           |> Ecto.Changeset.change(%{
             url: url,
             resource: meta.resource,
             issuer: meta.issuer,
             authorization_endpoint: meta.authorization_endpoint,
             token_endpoint: meta.token_endpoint,
             revocation_endpoint: meta.revocation_endpoint,
             iss_parameter_supported: meta.iss_parameter_supported,
             scopes: meta.scopes,
             registration: client.registration,
             client_id: client.client_id,
             client_secret_ciphertext: secret_ct,
             token_endpoint_auth_method: client.token_endpoint_auth_method,
             authorize_params: extra,
             status: "pending",
             login_nonce: nonce,
             login_verifier_ciphertext: verifier_ct
           })
           |> Ecto.Changeset.unique_constraint([:user_id, :resource],
             name: :connections_user_id_resource_index
           )
           |> Repo.insert() do
      {:ok, conn, login_url(conn, nonce, verifier)}
    else
      {:error, %Ecto.Changeset{}} -> {:error, {:connection_exists, nil}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Start another login on one of the user's connections (reconnect): a new
  verifier and nonce, and the URL to send the user to. The grant the
  connection holds, if any, stays in use until the new one replaces it.
  Not audited: the grant a login produces is, when it lands.
  """
  @spec authorize(Ecto.UUID.t(), term()) :: {:ok, Connection.t(), String.t()} | {:error, term()}
  def authorize(user_id, id) do
    with %Connection{} = conn <- get(id, user_id) || {:error, :not_found},
         nonce = nonce(),
         verifier = OAuth.code_verifier(),
         {:ok, verifier_ct} <- seal(conn, :login_verifier, verifier),
         {:ok, conn} <-
           conn
           |> Ecto.Changeset.change(login_nonce: nonce, login_verifier_ciphertext: verifier_ct)
           |> Repo.update() do
      {:ok, conn, login_url(conn, nonce, verifier)}
    end
  end

  defp login_url(conn, nonce, verifier) do
    state =
      Phoenix.Token.sign(FountainWeb.Endpoint, @state_salt, %{
        "c" => conn.id,
        "u" => conn.user_id,
        "n" => nonce
      })

    OAuth.authorize_url(%{
      authorization_endpoint: conn.authorization_endpoint,
      client_id: conn.client_id,
      redirect_uri: redirect_uri(),
      state: state,
      verifier: verifier,
      resource: conn.resource,
      scopes: conn.scopes,
      extra: conn.authorize_params
    })
  end

  @doc """
  Finish a login from the callback's query parameters, for the signed-in
  user. The `state` must be one Managoat signed in the last ten minutes for
  this user and for the login the connection is waiting on; anything else is
  refused before the code is used, so nobody can hand their grant to
  another account.

  `{:error, reason}`: `:invalid_state`, `:not_found`, `:stale_login`,
  `{:provider, code}` (the provider sent back an error, `access_denied`
  when the user declined), `:issuer_mismatch`, or a token exchange failure.
  """
  @spec complete(Ecto.UUID.t(), map(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def complete(user_id, params, opts \\ []) when is_binary(user_id) and is_map(params) do
    with {:ok, id, nonce} <- verify_state(params["state"], user_id),
         %Connection{} = conn <- get(id, user_id) || {:error, :not_found},
         :ok <- current_login(conn, nonce),
         :ok <- provider_error(params),
         :ok <- check_iss(conn, params["iss"]),
         {:ok, code} <- code(params),
         {:ok, verifier} <- open(conn, :login_verifier),
         {:ok, endpoint} <- endpoint(conn),
         {:ok, tokens} <-
           OAuth.exchange_code(endpoint, code, verifier: verifier, redirect_uri: redirect_uri()) do
      link(conn, nonce, endpoint, tokens, opts)
    end
  end

  defp code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp code(_params), do: {:error, :no_code}

  defp verify_state(state, user_id) when is_binary(state) do
    case Phoenix.Token.verify(FountainWeb.Endpoint, @state_salt, state, max_age: @login_max_age) do
      {:ok, %{"c" => id, "u" => ^user_id, "n" => nonce}} -> {:ok, id, nonce}
      _ -> {:error, :invalid_state}
    end
  end

  defp verify_state(_state, _user_id), do: {:error, :invalid_state}

  defp current_login(%Connection{login_nonce: stored}, nonce)
       when is_binary(stored) and is_binary(nonce) do
    if Plug.Crypto.secure_compare(stored, nonce), do: :ok, else: {:error, :stale_login}
  end

  defp current_login(_conn, _nonce), do: {:error, :stale_login}

  defp provider_error(%{"error" => code}) when is_binary(code),
    do: {:error, {:provider, String.slice(code, 0, 64)}}

  defp provider_error(_), do: :ok

  # RFC 9207: a server that promised `iss` must send its own.
  defp check_iss(%Connection{iss_parameter_supported: true, issuer: issuer}, iss) do
    if OAuth.same_issuer?(iss, issuer), do: :ok, else: {:error, :issuer_mismatch}
  end

  defp check_iss(%Connection{issuer: issuer}, iss) when is_binary(iss) do
    if OAuth.same_issuer?(iss, issuer), do: :ok, else: {:error, :issuer_mismatch}
  end

  defp check_iss(_conn, _iss), do: :ok

  # Write the grant under a row lock, provided the login is still the one
  # this callback finished; then, outside the transaction, audit and end the
  # grant it replaced. Tokens that could not be stored are ended too.
  defp link(conn, nonce, endpoint, tokens, opts) do
    result =
      Repo.transaction(fn ->
        locked =
          Repo.one(
            from c in Connection,
              where: c.id == ^conn.id and c.user_id == ^conn.user_id,
              lock: "FOR UPDATE"
          )

        with %Connection{login_nonce: ^nonce} = locked <- locked,
             replaced = revocable(locked),
             {:ok, access_ct} <- seal(locked, :access_token, tokens.access_token),
             {:ok, refresh_ct} <- seal_optional(locked, :refresh_token, tokens.refresh_token),
             {:ok, linked} <-
               locked
               |> Ecto.Changeset.change(%{
                 status: "active",
                 revoked_reason: nil,
                 access_token_ciphertext: access_ct,
                 refresh_token_ciphertext: refresh_ct,
                 expires_at: tokens.expires_at,
                 last_refreshed_at: now(),
                 refresh_lease_until: nil,
                 login_nonce: nil,
                 login_verifier_ciphertext: nil
               })
               |> Repo.update() do
          {linked, replaced}
        else
          nil -> Repo.rollback(:not_found)
          %Connection{} -> Repo.rollback(:stale_login)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {linked, replaced}} ->
        audit(linked, "connected", opts, %{
          "resource" => linked.resource,
          "reconnect" => conn.status != "pending"
        })

        end_grant(linked.id, replaced, "replaced")
        {:ok, linked}

      {:error, reason} ->
        end_grant(conn.id, grant_of(endpoint, tokens), "discarded")
        {:error, reason}
    end
  end

  # ── disconnecting ──────────────────────────────────────────────────────────

  @doc """
  Remove one of the user's connections, then revoke its grant at the
  provider. `{:error, :not_found}` when the user has no such connection.
  The audit event says whether the provider confirmed the revocation.
  """
  @spec delete(Ecto.UUID.t(), term(), keyword()) :: :ok | {:error, :not_found}
  def delete(user_id, id, opts \\ []) do
    with %Connection{} = conn <- get(id, user_id) || {:error, :not_found} do
      grant = revocable(conn)

      case Repo.delete_all(
             from c in Connection, where: c.id == ^conn.id and c.user_id == ^user_id
           ) do
        {1, _} ->
          outcome = end_grant(conn.id, grant, "deleted")
          audit(conn, "deleted", opts, %{"resource" => conn.resource, "provider" => outcome})
          :ok

        {0, _} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  For account deletion, before the user row goes: each connection's grant,
  read while the key that decrypts it still exists. Pass the result to
  `end_grants_after_deletion/1` once the deletion has committed.
  """
  @spec grants_to_end(Ecto.UUID.t()) :: [{Ecto.UUID.t(), term()}]
  def grants_to_end(user_id) do
    for conn <- list(user_id), grant = revocable(conn), do: {conn.id, grant}
  end

  @doc "Revoke at their providers the grants `grants_to_end/1` read. Never raises."
  @spec end_grants_after_deletion([{Ecto.UUID.t(), term()}]) :: :ok
  def end_grants_after_deletion(grants) do
    Enum.each(grants, fn {id, grant} -> end_grant(id, grant, "account_deleted") end)
  end

  # ── delivery ───────────────────────────────────────────────────────────────

  @doc """
  Whether a turn may run on the connection: `:ok`, or
  `{:error, {:connection_reconnect_required, id}}` when it is pending,
  revoked, expired or gone. An active connection whose access token has
  lapsed with no refresh token is marked `expired` here.
  """
  @spec check_usable(Ecto.UUID.t(), term()) ::
          :ok | {:error, {:connection_reconnect_required, term()}}
  def check_usable(user_id, id) do
    case get(id, user_id) do
      %Connection{status: "active"} = conn ->
        if lapsed_for_good?(conn) and mark_expired(conn) == :expired,
          do: {:error, {:connection_reconnect_required, id}},
          else: :ok

      _ ->
        {:error, {:connection_reconnect_required, id}}
    end
  end

  @doc """
  The access token a turn's broker rule should carry, with its expiry.
  Refreshed first when it expires within ten minutes; a refresh that fails
  for a transient reason, or that another process is running, leaves the
  stored token in place. `{:error, :connection_reconnect_required}` when
  the connection is gone, not active, or cannot be renewed.

  `refresh: false` reads the stored token and never calls the provider. A
  conversation's server reads that way and leaves the exchange to a task
  (`Fountain.Conversations.McpConnections`), so a slow token endpoint never
  holds up its mailbox.
  """
  @spec token_for_session(Ecto.UUID.t(), term(), keyword()) ::
          {:ok, String.t(), DateTime.t() | nil} | {:error, :connection_reconnect_required}
  def token_for_session(user_id, id, opts \\ []) do
    renew = if Keyword.get(opts, :refresh, true), do: &refresh_if_expiring/1, else: & &1

    with %Connection{status: "active"} = conn <- get(id, user_id),
         %Connection{status: "active"} = conn <- renew.(conn),
         {:ok, token} <- open(conn, :access_token) do
      {:ok, token, conn.expires_at}
    else
      _ -> {:error, :connection_reconnect_required}
    end
  end

  @doc "When a token expiring at `at` should be refreshed: ten minutes before."
  @spec refresh_due_at(DateTime.t() | nil) :: DateTime.t() | nil
  def refresh_due_at(nil), do: nil
  def refresh_due_at(%DateTime{} = at), do: DateTime.add(at, -@refresh_margin_seconds)

  @doc "Whether a token expiring at `at` is due a refresh now."
  @spec refresh_due?(DateTime.t() | nil) :: boolean()
  def refresh_due?(nil), do: false
  def refresh_due?(%DateTime{} = at), do: DateTime.compare(refresh_due_at(at), now()) != :gt

  defp refresh_if_expiring(%Connection{expires_at: %DateTime{} = at} = conn) do
    cond do
      DateTime.diff(at, now()) > @refresh_margin_seconds ->
        conn

      is_nil(conn.refresh_token_ciphertext) ->
        if lapsed_for_good?(conn) do
          mark_expired(conn)
          nil
        else
          conn
        end

      true ->
        case refresh(conn) do
          {:ok, fresh} -> fresh
          {:error, :revoked} -> nil
          {:error, _transient} -> conn
        end
    end
  end

  defp refresh_if_expiring(conn), do: conn

  defp lapsed_for_good?(%Connection{refresh_token_ciphertext: nil, expires_at: %DateTime{} = at}),
    do: DateTime.compare(at, now()) != :gt

  defp lapsed_for_good?(_conn), do: false

  defp mark_expired(conn) do
    query =
      from c in Connection,
        where: c.id == ^conn.id and c.status == "active" and is_nil(c.refresh_token_ciphertext),
        select: c

    case Repo.update_all(query, set: [status: "expired", updated_at: now()]) do
      {1, [expired]} ->
        audit(expired, "expired", [actor: "system:connection_refresh"], %{
          "resource" => expired.resource
        })

        :expired

      _ ->
        :unchanged
    end
  end

  # ── refresh (as Fountain.ChatGPT) ──────────────────────────────────────────

  @doc """
  Exchange the connection's refresh token under a lease on the row; no
  transaction is open while the provider answers.

  `{:ok, conn}` with the row as it now is (refreshed here, or by whoever
  refreshed it since `conn` was read); `{:error, :locked}` when another
  process holds the lease; `{:error, :revoked}` when the provider refused
  the grant for good, which marks the row and audits it; `{:error, :gone}`;
  `{:error, :superseded}` when a reconnect or delete overtook the exchange,
  whose tokens are then revoked; `{:error, :store_failed}`. Any other error
  is transient and the row is unchanged.
  """
  @spec refresh(Connection.t()) :: {:ok, Connection.t()} | {:error, term()}
  def refresh(%Connection{id: id, last_refreshed_at: cutoff}) do
    case take_lease(id, cutoff) do
      {:leased, leased} -> exchange(leased)
      other -> other
    end
  end

  defp take_lease(id, cutoff) do
    query =
      from c in Connection,
        where:
          c.id == ^id and c.status == "active" and c.last_refreshed_at <= ^cutoff and
            not is_nil(c.refresh_token_ciphertext) and
            (is_nil(c.refresh_lease_until) or c.refresh_lease_until < fragment("now()")),
        update: [
          set: [
            refresh_lease_until: fragment("now() + make_interval(secs => ?)", ^@lease_seconds)
          ]
        ],
        select: c

    case Repo.update_all(query, []) do
      {1, [leased]} ->
        {:leased, leased}

      {0, _} ->
        case Repo.get(Connection, id) do
          %Connection{status: "active"} = conn ->
            if DateTime.compare(conn.last_refreshed_at, cutoff) == :gt,
              do: {:ok, conn},
              else: {:error, :locked}

          _ ->
            {:error, :gone}
        end
    end
  end

  defp exchange(leased) do
    with {:ok, refresh_token} <- open(leased, :refresh_token),
         {:ok, endpoint} <- endpoint(leased),
         {:ok, tokens} <- OAuth.refresh(endpoint, refresh_token) do
      store_refreshed(leased, endpoint, tokens)
    else
      {:error, {:terminal, code}} ->
        case attempt_write_back(leased, status: "revoked", revoked_reason: code) do
          {:ok, revoked} ->
            audit(revoked, "revoked", [actor: "system:connection_refresh"], %{
              "resource" => revoked.resource,
              "reason" => code
            })

            {:error, :revoked}

          :superseded ->
            {:error, :superseded}

          {:failed, reason} ->
            Logger.warning(
              "connection #{leased.id}: refused for good (#{code}), but marking it revoked " <>
                "failed (#{reason})"
            )

            {:error, :refresh_failed}
        end

      {:error, reason} ->
        Logger.warning("connection #{leased.id}: refresh failed: #{loggable(reason)}")
        release_lease(leased)
        {:error, :refresh_failed}
    end
  end

  defp store_refreshed(conn, endpoint, tokens) do
    with {:ok, access_ct} <- seal(conn, :access_token, tokens.access_token),
         {:ok, refresh_ct} <-
           if(tokens.refresh_token,
             do: seal(conn, :refresh_token, tokens.refresh_token),
             else: {:ok, conn.refresh_token_ciphertext}
           ) do
      changes = [
        access_token_ciphertext: access_ct,
        refresh_token_ciphertext: refresh_ct,
        expires_at: tokens.expires_at,
        last_refreshed_at: now()
      ]

      store(conn, grant_of(endpoint, tokens), changes, @store_backoff_ms)
    else
      {:error, reason} ->
        Logger.error(
          "connection #{conn.id}: refreshed, but the new tokens could not be sealed " <>
            "(#{loggable(reason)}); the owner will have to reconnect"
        )

        {:error, :store_failed}
    end
  end

  defp store(leased, grant, changes, backoff) do
    case attempt_write_back(leased, changes) do
      {:ok, conn} ->
        {:ok, conn}

      :superseded ->
        written = Keyword.fetch!(changes, :access_token_ciphertext)

        case safely(fn -> Repo.get(Connection, leased.id) end) do
          {:ok, %Connection{access_token_ciphertext: ^written} = conn} ->
            {:ok, conn}

          _ ->
            Logger.info(
              "connection #{leased.id}: reconnected or removed during a refresh; " <>
                "the refreshed tokens are revoked"
            )

            end_grant(leased.id, grant, "discarded")
            {:error, :superseded}
        end

      {:failed, reason} ->
        case backoff do
          [wait | rest] ->
            Logger.warning(
              "connection #{leased.id}: storing the refreshed tokens failed (#{reason}); retrying"
            )

            Process.sleep(wait)
            store(leased, grant, changes, rest)

          [] ->
            Logger.error(
              "connection #{leased.id}: refreshed, but the rotated tokens could not be stored " <>
                "(#{reason}); the owner will have to reconnect"
            )

            {:error, :store_failed}
        end
    end
  end

  defp attempt_write_back(leased, changes) do
    query =
      from c in Connection,
        where:
          c.id == ^leased.id and c.refresh_lease_until == ^leased.refresh_lease_until and
            c.refresh_token_ciphertext == ^leased.refresh_token_ciphertext,
        select: c

    set = Keyword.merge(changes, refresh_lease_until: nil, updated_at: now())

    case safely(fn -> Repo.update_all(query, set: set) end) do
      {:ok, {1, [conn]}} -> {:ok, conn}
      {:ok, {0, _}} -> :superseded
      {:error, reason} -> {:failed, reason}
    end
  end

  defp release_lease(leased) do
    safely(fn ->
      Repo.update_all(
        from(c in Connection,
          where: c.id == ^leased.id and c.refresh_lease_until == ^leased.refresh_lease_until
        ),
        set: [refresh_lease_until: nil]
      )
    end)

    :ok
  end

  # A database error as a value; the reason never carries a parameter.
  defp safely(fun) do
    {:ok, fun.()}
  rescue
    e in DBConnection.ConnectionError -> {:error, "connection: " <> e.message}
    e in Postgrex.Error -> {:error, "postgres " <> to_string(e.postgres[:code] || "error")}
  end

  # ── encryption ─────────────────────────────────────────────────────────────

  defp seal(%Connection{user_id: user_id, id: id}, field, value) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      {:ok, Crypto.encrypt(value, dek, aad(user_id, id, field))}
    end
  end

  defp seal_optional(_conn, _field, nil), do: {:ok, nil}
  defp seal_optional(conn, field, value), do: seal(conn, field, value)

  defp open(%Connection{} = conn, field) do
    blob =
      case field do
        :access_token -> conn.access_token_ciphertext
        :refresh_token -> conn.refresh_token_ciphertext
        :client_secret -> conn.client_secret_ciphertext
        :login_verifier -> conn.login_verifier_ciphertext
      end

    opened =
      with blob when is_binary(blob) <- blob,
           {:ok, dek} <- Crypto.load_tenant_key(conn.user_id) do
        Crypto.decrypt(blob, dek, aad(conn.user_id, conn.id, field))
      end

    case opened do
      {:ok, value} ->
        {:ok, value}

      _ ->
        Logger.warning(
          "connection #{conn.id}: the stored #{field} is missing or does not decrypt"
        )

        {:error, :undecryptable}
    end
  end

  defp aad(user_id, id, field), do: "fountain.connection:#{user_id}:#{id}:#{field}"

  # The token endpoint, the client and the revocation endpoint, with the
  # client secret decrypted.
  defp endpoint(%Connection{} = conn) do
    secret =
      if conn.client_secret_ciphertext, do: open(conn, :client_secret), else: {:ok, nil}

    with {:ok, secret} <- secret do
      {:ok,
       %{
         token_endpoint: conn.token_endpoint,
         revocation_endpoint: conn.revocation_endpoint,
         client_id: conn.client_id,
         client_secret: secret,
         token_endpoint_auth_method: conn.token_endpoint_auth_method,
         resource: conn.resource
       }}
    end
  end

  # ── ending a grant at the provider ─────────────────────────────────────────

  # What to revoke when Managoat lets go of `conn`: the refresh token when
  # there is one (revoking it ends the grant), else the access token. A row
  # the provider already refused holds nothing left to end.
  defp revocable(%Connection{status: status} = conn) when status in ["active", "expired"] do
    with {:ok, endpoint} <- endpoint(conn) do
      case open_quietly(conn, :refresh_token) do
        {:ok, refresh} ->
          {endpoint, refresh, "refresh_token"}

        :none ->
          case open_quietly(conn, :access_token) do
            {:ok, access} -> {endpoint, access, "access_token"}
            :none -> nil
          end
      end
    else
      _ -> nil
    end
  end

  defp revocable(_conn), do: nil

  defp open_quietly(conn, field) do
    blob =
      if field == :refresh_token,
        do: conn.refresh_token_ciphertext,
        else: conn.access_token_ciphertext

    if is_binary(blob) do
      case open(conn, field) do
        {:ok, value} -> {:ok, value}
        _ -> :none
      end
    else
      :none
    end
  end

  defp grant_of(endpoint, %{refresh_token: refresh}) when is_binary(refresh),
    do: {endpoint, refresh, "refresh_token"}

  defp grant_of(endpoint, %{access_token: access}), do: {endpoint, access, "access_token"}

  # After the write that let go of the grant has committed. Never raises,
  # never undoes that write, never logs the token. Returns what happened, for
  # an audit event's metadata.
  defp end_grant(_id, nil, _trigger), do: "nothing_to_revoke"

  defp end_grant(id, {endpoint, token, hint}, trigger) do
    result =
      try do
        OAuth.revoke(endpoint, token, hint)
      rescue
        e -> {:error, {:raised, inspect(e.__struct__)}}
      end

    case result do
      :ok ->
        "revoked"

      {:error, :no_revocation_endpoint} ->
        "no_revocation_endpoint"

      {:error, reason} ->
        Logger.warning(
          "connection #{id}: revoking the grant at the provider failed (#{trigger}): " <>
            loggable(reason)
        )

        "not_revoked"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  @doc "A sentence for a person, for each `create/3` and `complete/3` refusal."
  @spec error_message(term()) :: String.t()
  def error_message(:invalid_url), do: "Enter the MCP server's https URL."

  def error_message(:invalid_authorize_params),
    do: "Extra authorize parameters must be names and values, and cannot replace the flow's own."

  def error_message({:connection_exists, _}),
    do: "That server is already connected. Reconnect it instead."

  def error_message(:client_required),
    do:
      "This server does not let Managoat register itself. Register an app with the " <>
        "provider, with #{redirect_uri()} as its redirect URI, and paste its client ID " <>
        "and secret."

  def error_message({:unsafe_url, url, reason}),
    do: "#{url} #{Fountain.Connections.UrlGuard.message(reason)}."

  def error_message({:mcp_server, _}), do: "The MCP server could not be reached."

  def error_message(:no_resource_metadata),
    do: "The server publishes no OAuth protected-resource metadata, so it cannot be connected."

  def error_message(:resource_mismatch),
    do: "The server's metadata names a resource on another origin."

  def error_message(:no_authorization_server),
    do: "The server's metadata names no authorization server."

  def error_message(:no_authorization_server_metadata),
    do: "The authorization server publishes no metadata."

  def error_message(:issuer_mismatch),
    do: "The authorization server's issuer does not match the one the server named."

  def error_message(:incomplete_authorization_server_metadata),
    do: "The authorization server's metadata lacks an authorize or token endpoint."

  def error_message(:pkce_s256_unsupported),
    do: "The authorization server does not support PKCE with S256."

  def error_message({:registration, status, code}),
    do: "Registering a client was refused (#{status} #{code})."

  def error_message(:invalid_state),
    do: "The sign-in link has expired or belongs to another account. Connect again."

  def error_message(:stale_login),
    do: "A newer sign-in was started for this connection. Finish that one, or connect again."

  def error_message({:provider, "access_denied"}), do: "The provider's consent was declined."
  def error_message({:provider, code}), do: "The provider refused the sign-in (#{code})."
  def error_message(:no_code), do: "The provider sent no authorization code."
  def error_message({:terminal, code}), do: "The provider refused the code (#{code})."
  def error_message({:token, status, code}), do: "The token exchange failed (#{status} #{code})."
  def error_message(:not_found), do: "No such connection."
  def error_message(_), do: "The connection could not be completed."

  defp audit(conn, what, opts, metadata) do
    Audit.record(%{
      user_id: conn.user_id,
      action: "connection.#{what}",
      resource_type: "connection",
      resource_id: conn.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: metadata
    })

    :ok
  end

  defp loggable({:token, status, code}), do: "#{status} #{code}"
  defp loggable({:revoke, status, code}), do: "#{status} #{code}"
  defp loggable({:unsafe_url, _url, reason}), do: "unsafe url (#{reason})"
  defp loggable({:transport, message}) when is_binary(message), do: message
  defp loggable({:raised, what}), do: "raised #{what}"
  defp loggable(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      v -> v
    end
  end

  defp present(_), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
