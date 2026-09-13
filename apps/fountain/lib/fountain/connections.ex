defmodule Fountain.Connections do
  @moduledoc """
  Provider accounts a tenant has signed in to once, whose credentials
  Fountain holds (#1178). This is how a managed-agent platform does
  connectors: the platform runs the OAuth flow, keeps the refresh token, and
  hands an agent a capability rather than a credential.

  Where the tokens come from is a `Fountain.Connections.Provider` (#1186):
  a platform provider with Fountain's own OAuth client (Google, Microsoft,
  Slack — `Fountain.Connections.Platform`, #1299), or a provider the tenant
  defined — their own app registration at a service (`oauth2`), or a remote
  MCP server whose authorization server Fountain discovered and registered
  with (`mcp`). One OAuth client (`Fountain.Connections.OAuth`) serves
  every kind.

  A connection reaches an agent three ways, all only on a deployment that
  brokers egress (`Fountain.Broker.configured?/0`):

    * **A Fountain-served MCP server.** An agent's `mcp_servers` names a
      Google connection (`%{"gmail" => %{"connection" => id}}`) and the
      conversation gets `POST /api/mcp/gmail/:conversation_id/:connection_id`,
      authenticated by its own callback token. The token never leaves the
      server.
    * **A remote MCP server the tenant supplies.** The entry carries a URL
      and a connection (`%{"type" => "http", "url" => ..., "connection" => id}`);
      at spawn it becomes the same server with a placeholder bearer, and the
      broker attaches the real token to that host.
    * **A brokered secret.** The access token is a synthetic secret under
      `env_key` (`GOOGLE_ACCESS_TOKEN`, `GITHUB_ACCESS_TOKEN`…), brokered like
      an inference key: the sandbox holds a placeholder, the broker attaches
      the value to requests for the provider's `token_hosts`, and a binding of
      the tenant's own on the same name sends it to a server they run
      instead. Rotated tokens are re-uploaded by
      `Fountain.Conversations.ConversationServer` at each turn.

  Every read of a token goes through `access_token/1`, which refreshes near
  expiry, marks the connection `revoked` when the provider refuses the grant
  (`invalid_grant`), and `expired` when the token lapses with no refresh
  token to renew it. Both stay listed so the console can say why the tools
  stopped working; reconnecting replaces them.

  Audit: `connection.created` / `connection.revoked` / `connection.expired`
  carry provider, scopes and the account label, and
  `connection_provider.created` / `.updated` / `.deleted` the slug and kind —
  never a token or a client secret (ADR 0013).
  """

  import Ecto.Query, warn: false

  alias Fountain.{Audit, Crypto, Repo}
  alias Fountain.Connections.{Connection, OAuth, Platform, Provider}
  alias Managoat.McpAuth

  @doc """
  Whether this account may **add** a connection, a provider or a credential
  binding.

  Two things have to be true. This deployment brokers egress (ADR 0019) —
  without a broker a token would have to enter a sandbox in the clear. And
  the `connections` rollout flag is on for them. Gate every door that
  creates something on this one, and nothing else: see
  `manageable_for?/0` for the rest.
  """
  @spec enabled_for?(String.t()) :: boolean()
  def enabled_for?(user_id) do
    Fountain.Broker.configured?() and
      Fountain.FeatureFlags.enabled?(:connections, user_id)
  end

  @doc """
  Whether this account's existing connections and bindings may be listed,
  revoked and deleted.

  The broker alone, deliberately, because that is what the runtime paths which
  attach a token gate on (`Fountain.Conversations.Egress`). A tenant whose
  rollout flag goes off keeps every credential that is already brokered into
  their sandboxes, so the doors that take one away have to stay open. Behind
  the creation gate, revocation answered 404 while the token kept flowing, and
  the account had no way to turn off a credential that was still in use
  (#1693).

  A tenant with no rows gets an empty list rather than a 404, which is the
  price of never having to ask "do they still hold one?" before answering.

  It took a `user_id` while brokerage was a per-tenant ratchet (ADR 0019 §9).
  The ratchet retired, the broker is the deployment's, and an argument the
  answer does not depend on would make every call site read as though it
  still did.
  """
  @spec manageable_for?() :: boolean()
  def manageable_for?, do: Fountain.Broker.configured?()

  # How close to expiry a token is considered stale. A turn may run for a
  # while on the token it started with, so refresh well ahead.
  @refresh_margin_seconds 300

  # Advisory-lock namespace for per-connection refresh serialization.
  # (Quotas holds 4315 for sandbox reservations.)
  @refresh_lock_namespace 4331

  # ── providers ─────────────────────────────────────────────────────────────

  @doc "The tenant's own providers, by name."
  @spec list_providers(String.t()) :: [Provider.t()]
  def list_providers(user_id) when is_binary(user_id) do
    Repo.all(from p in Provider, where: p.user_id == ^user_id, order_by: [asc: p.name])
  end

  @doc "Every provider the tenant can connect: the platform ones first, then their own."
  @spec all_providers(String.t()) :: [Provider.t()]
  def all_providers(user_id) when is_binary(user_id),
    do: Platform.all() ++ list_providers(user_id)

  @doc """
  A provider by id: a platform slug (`"google"`, `"microsoft"`, `"slack"`)
  is the platform provider, anything else a tenant row. Nil for a row that
  is not the tenant's.
  """
  @spec get_provider(String.t(), String.t()) :: Provider.t() | nil
  def get_provider(id, user_id) when is_binary(id) and is_binary(user_id) do
    Platform.get(id) || if valid_uuid?(id), do: Repo.get_by(Provider, id: id, user_id: user_id)
  end

  @doc """
  The provider a connection's tokens come from. A platform connection has
  no provider row — its `provider` slug names the registry entry.
  """
  @spec provider_for(Connection.t()) :: Provider.t()
  def provider_for(%Connection{provider_id: nil, provider: slug}), do: Platform.get(slug)

  # Ownership established by the connection, which was fetched tenant-scoped.
  def provider_for(%Connection{provider_id: id}), do: Repo.get!(Provider, id)

  @doc """
  The provider with its plaintext client secret on the virtual field, which
  is what `Fountain.Connections.OAuth` drives. The platform provider carries
  it from config already.
  """
  @spec unlock_provider(Provider.t()) :: {:ok, Provider.t()} | {:error, term()}
  def unlock_provider(%Provider{user_id: nil} = p), do: {:ok, p}
  def unlock_provider(%Provider{client_secret_ciphertext: nil} = p), do: {:ok, p}

  def unlock_provider(%Provider{} = p) do
    with {:ok, dek} <- Crypto.load_tenant_key(p.user_id),
         {:ok, secret} <- decrypt(p.client_secret_ciphertext, dek) do
      {:ok, %{p | client_secret: secret}}
    end
  end

  @doc "Where the provider sends the browser back. Shown in the console to paste into the app registration."
  @spec redirect_uri(Provider.t() | String.t()) :: String.t()
  def redirect_uri(%Provider{id: id}), do: redirect_uri(id)

  def redirect_uri(id) when is_binary(id),
    do: Fountain.PublicUrl.base() <> "/connections/#{id}/callback"

  @doc """
  Define an `oauth2` provider from the tenant's own app registration. The
  client secret is encrypted with the tenant key on the way in.
  """
  @spec create_provider(String.t(), map(), keyword()) ::
          {:ok, Provider.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_provider(user_id, attrs, opts \\ []) when is_binary(user_id) and is_map(attrs) do
    attrs = attrs |> string_keys() |> Map.put("user_id", user_id) |> Map.put_new("kind", "oauth2")

    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      %Provider{}
      |> Provider.changeset(attrs, dek)
      |> Repo.insert()
      |> audited_provider("connection_provider.created", opts)
    end
  end

  @doc """
  Define an `mcp` provider from a remote MCP server's URL: discover its
  authorization server, register a client there when it offers RFC 7591
  registration, and store the result. Every provider registers its own
  client — the redirect URI is derived from the provider id, so a client
  registered for one provider carries the wrong callback for any other.
  `attrs` may carry a `client_id` / `client_secret` for a server without
  registration, and a `name`, `slug` or `scopes` to override what
  discovery found.
  """
  @spec discover_provider(String.t(), String.t(), map(), keyword()) ::
          {:ok, Provider.t()} | {:error, term()}
  def discover_provider(user_id, mcp_url, attrs \\ %{}, opts \\ [])
      when is_binary(user_id) and is_binary(mcp_url) do
    id = Ecto.UUID.generate()
    attrs = attrs |> string_keys() |> Map.merge(%{"user_id" => user_id, "kind" => "mcp"})

    with {:ok, dek} <- Crypto.load_tenant_key(user_id),
         {:ok, discovered} <- discovered_attrs(user_id, mcp_url, redirect_uri(id), attrs) do
      %Provider{id: id}
      |> Provider.changeset(Map.merge(discovered, attrs), dek)
      |> Repo.insert()
      |> audited_provider("connection_provider.created", opts)
    end
  end

  @doc "Run discovery again on an `mcp` provider, keeping its client where the server still names the same issuer."
  @spec rediscover_provider(Provider.t(), keyword()) :: {:ok, Provider.t()} | {:error, term()}
  def rediscover_provider(%Provider{kind: "mcp"} = p, opts \\ []) do
    with {:ok, dek} <- Crypto.load_tenant_key(p.user_id),
         {:ok, discovered} <-
           discovered_attrs(p.user_id, p.mcp_url, redirect_uri(p), %{
             "client_id" => p.client_id,
             "client_source" => p.client_source,
             "issuer" => p.issuer
           }) do
      p
      |> Provider.changeset(discovered, dek)
      |> Repo.update()
      |> audited_provider("connection_provider.updated", opts)
    end
  end

  # What discovery contributes to the provider row. A client is taken, in
  # order: one the tenant typed; the provider's own DCR client where the
  # issuer is unchanged (rediscovery); a fresh registration; else none, and
  # the row is saved without a client so the console can ask for one. A
  # registration is never shared between providers: it names one redirect
  # URI, this provider's, and a conforming AS refuses any other.
  defp discovered_attrs(_user_id, mcp_url, redirect_uri, attrs) do
    with {:ok, md} <- McpAuth.discover(mcp_url) do
      host = URI.parse(mcp_url).host
      manual? = present?(attrs["client_id"]) and attrs["client_source"] != "dcr"

      client =
        cond do
          manual? ->
            {:ok,
             %{
               "client_source" => "manual",
               "token_endpoint_auth" => attrs["token_endpoint_auth"] || "client_secret_post"
             }}

          attrs["client_source"] == "dcr" and attrs["issuer"] == md["issuer"] and
              present?(attrs["client_id"]) ->
            {:ok, %{}}

          is_binary(md["registration_endpoint"]) ->
            McpAuth.register(md, redirect_uri,
              client_name: "Fountain",
              client_uri: Fountain.PublicUrl.base()
            )

          true ->
            {:ok, %{"client_source" => nil}}
        end

      with {:ok, client_attrs} <- client do
        {:ok,
         %{
           "mcp_url" => mcp_url,
           "issuer" => md["issuer"],
           "authorize_url" => md["authorization_endpoint"],
           "token_url" => md["token_endpoint"],
           "revoke_url" => md["revocation_endpoint"],
           "scopes" => attrs["scopes"] || md["scopes"] || [],
           "token_hosts" => [host],
           "pkce" => true,
           "mcp_metadata" => md
         }
         |> Map.merge(client_attrs)}
      end
    end
  end

  @doc "Edit a provider. A blank `client_secret` keeps the stored one."
  @spec update_provider(Provider.t(), map(), keyword()) ::
          {:ok, Provider.t()} | {:error, Ecto.Changeset.t() | term()}
  def update_provider(%Provider{user_id: uid} = p, attrs, opts \\ []) when is_binary(uid) do
    attrs = attrs |> string_keys() |> Map.drop(["user_id", "kind"])

    with {:ok, dek} <- Crypto.load_tenant_key(uid) do
      changeset = Provider.changeset(p, attrs, dek)

      changeset
      |> update_provider_and_connections()
      |> audited_provider(
        "connection_provider.updated",
        Keyword.put(opts, :metadata, Audit.changed_fields(changeset))
      )
    end
  end

  # `connections.provider` denormalizes the slug, so a rename must carry the
  # rows with it in the same transaction — a connection left under the old
  # slug reads as another provider's everywhere the slug is shown. (The
  # audit stays outside the transaction, ADR 0013.)
  defp update_provider_and_connections(changeset) do
    slug_change = Ecto.Changeset.get_change(changeset, :slug)

    Repo.transaction(fn ->
      case Repo.update(changeset) do
        {:ok, updated} ->
          if is_binary(slug_change) do
            Repo.update_all(
              from(c in Connection, where: c.provider_id == ^updated.id),
              set: [provider: updated.slug]
            )
          end

          updated

        {:error, failed} ->
          Repo.rollback(failed)
      end
    end)
  end

  @doc "Delete a provider and, with it, every connection on it (revoked at the provider first, best effort)."
  @spec delete_provider(Provider.t(), keyword()) :: {:ok, Provider.t()} | {:error, term()}
  def delete_provider(%Provider{user_id: uid} = p, opts \\ []) when is_binary(uid) do
    Repo.all(from c in Connection, where: c.provider_id == ^p.id and c.status == "active")
    |> Enum.each(&revoke(&1, opts))

    p
    |> Repo.delete()
    |> audited_provider("connection_provider.deleted", opts)
  end

  # ── reads ─────────────────────────────────────────────────────────────────

  @spec list_connections(String.t()) :: [Connection.t()]
  def list_connections(user_id) when is_binary(user_id) do
    Repo.all(
      from c in Connection,
        where: c.user_id == ^user_id,
        order_by: [asc: c.provider, asc: c.account_email]
    )
  end

  @spec get_connection(String.t(), String.t()) :: Connection.t() | nil
  def get_connection(id, user_id) when is_binary(id) and is_binary(user_id) do
    if valid_uuid?(id), do: Repo.get_by(Connection, id: id, user_id: user_id)
  end

  @doc "The tenant's active connections only — what a sandbox may be handed."
  @spec active_connections(String.t()) :: [Connection.t()]
  def active_connections(user_id) when is_binary(user_id) do
    Repo.all(
      from c in Connection,
        where: c.user_id == ^user_id and c.status == "active",
        order_by: [asc: c.env_key]
    )
  end

  # ── writes ────────────────────────────────────────────────────────────────

  @doc """
  Store a fresh grant on `provider`. One connection per (provider, account):
  signing the same account in again replaces its tokens and reactivates it.
  `grant` is what `Fountain.Connections.OAuth.exchange_code/4` returns; a
  grant with no account label is named after the provider.
  """
  @spec connect(String.t(), Provider.t() | String.t(), map(), keyword()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t() | atom()}
  def connect(user_id, provider, grant, opts \\ [])

  def connect(user_id, slug, grant, opts) when is_binary(slug),
    do:
      connect(
        user_id,
        Platform.get(slug) || raise("unknown platform provider #{slug}"),
        grant,
        opts
      )

  def connect(user_id, %Provider{} = provider, grant, opts)
      when is_binary(user_id) and is_map(grant) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      label = grant[:account_email] || opts[:account_label] || provider.name
      provider_id = if Provider.platform?(provider), do: nil, else: provider.id

      # Keyed on the provider row, not its slug: the slug is editable and
      # denormalized, and a lookup through a stale one would miss the
      # existing connection and duplicate it on reconnect. Platform
      # connections have no row, so their (reserved) slug is the key.
      existing = existing_connection(user_id, provider_id, provider.slug, label)

      attrs = %{
        user_id: user_id,
        provider: provider.slug,
        provider_id: provider_id,
        account_email: label,
        scopes: grant[:scopes] || provider.scopes,
        env_key: (existing && existing.env_key) || free_env_key(user_id, provider),
        refresh_token: grant[:refresh_token],
        access_token: grant[:access_token],
        expires_at: grant[:expires_at]
      }

      (existing || %Connection{})
      |> Connection.changeset(attrs, dek)
      |> Repo.insert_or_update()
      |> audited("connection.created", Keyword.delete(opts, :account_label))
    end
  end

  # A platform provider has no row: its connections carry a null
  # `provider_id` (which `Repo.get_by` cannot express) and are told apart
  # by slug — the same label on two platform providers is two connections.
  defp existing_connection(user_id, nil, slug, label) do
    Repo.one(
      from c in Connection,
        where:
          c.user_id == ^user_id and is_nil(c.provider_id) and c.provider == ^slug and
            c.account_email == ^label
    )
  end

  defp existing_connection(user_id, provider_id, _slug, label) do
    Repo.get_by(Connection, user_id: user_id, provider_id: provider_id, account_email: label)
  end

  @doc """
  Revoke a connection: the provider is told to forget the grant (best
  effort), and the row is marked `revoked` so every door says why. The next
  MCP tool call on it fails with `connection revoked`, not a 401 from the
  provider.
  """
  @spec revoke(Connection.t(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def revoke(%Connection{} = conn, opts \\ []) do
    if conn.status == "active", do: revoke_at_provider(conn)

    conn
    |> Connection.revoke_changeset()
    |> Repo.update()
    |> audited("connection.revoked", opts)
  end

  # RFC 7009 takes the refresh token where there is one (it revokes the
  # access tokens with it) and the access token otherwise.
  defp revoke_at_provider(conn) do
    with {:ok, dek} <- Crypto.load_tenant_key(conn.user_id),
         {:ok, provider} <- unlock_provider(provider_for(conn)) do
      case decrypt(conn.refresh_token_ciphertext, dek) do
        {:ok, refresh} ->
          OAuth.revoke(provider, refresh)

        _ ->
          case decrypt(conn.access_token_ciphertext, dek) do
            {:ok, access} -> OAuth.revoke(provider, access)
            _ -> :ok
          end
      end
    end
  end

  @doc "Delete a connection outright. Revokes at the provider first."
  @spec delete(Connection.t(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def delete(%Connection{} = conn, opts \\ []) do
    with {:ok, conn} <- revoke(conn, opts) do
      Repo.delete(conn)
    end
  end

  # Marks the connection revoked because the provider refused the grant.
  # A system event, not the tenant's: attributed to the refresher.
  defp mark_refused(%Connection{} = conn) do
    conn
    |> Connection.revoke_changeset()
    |> Repo.update()
    |> audited("connection.revoked",
      actor: "system:connection_refresh",
      metadata: %{"reason" => "invalid_grant"}
    )
  end

  # The access token lapsed and the provider gave no refresh token.
  defp mark_expired(%Connection{} = conn) do
    conn
    |> Connection.expire_changeset()
    |> Repo.update()
    |> audited("connection.expired",
      actor: "system:connection_refresh",
      metadata: %{"reason" => "no_refresh_token"}
    )
  end

  # ── tokens ────────────────────────────────────────────────────────────────

  @doc """
  A valid access token for the connection, refreshing when it is within
  #{@refresh_margin_seconds}s of expiry. `{:error, :revoked}` for a revoked
  connection, including one the provider has just refused; `{:error,
  :expired}` for one whose token lapsed with no refresh token.
  """
  @spec access_token(Connection.t()) :: {:ok, String.t()} | {:error, term()}
  def access_token(%Connection{status: "revoked"}), do: {:error, :revoked}
  def access_token(%Connection{status: "expired"}), do: {:error, :expired}

  def access_token(%Connection{} = conn) do
    with {:ok, dek} <- Crypto.load_tenant_key(conn.user_id) do
      cond do
        fresh?(conn) -> decrypt(conn.access_token_ciphertext, dek)
        is_nil(conn.refresh_token_ciphertext) -> expire(conn, dek)
        true -> refresh_token(conn, dek)
      end
    end
  end

  # No refresh token: the cached token is served until it has really
  # expired (the margin is for refreshing, not for cutting off), then the
  # connection goes `expired`.
  defp expire(conn, dek) do
    if lapsed?(conn) do
      _ = mark_expired(conn)
      {:error, :expired}
    else
      decrypt(conn.access_token_ciphertext, dek)
    end
  end

  @doc """
  The synthetic secrets a tenant's active connections contribute to a
  sandbox: `%{"GOOGLE_ACCESS_TOKEN" => token}`. A connection whose refresh
  fails is left out, and the sandbox runs without it; the console says why.
  """
  @spec synthetic_secrets(String.t()) :: %{String.t() => String.t()}
  def synthetic_secrets(user_id) when is_binary(user_id) do
    user_id
    |> active_connections()
    |> Enum.reduce(%{}, fn conn, acc ->
      case access_token(conn) do
        {:ok, token} -> Map.put(acc, conn.env_key, token)
        _ -> acc
      end
    end)
  end

  @doc "The env var names a tenant's connections are brokered under (for the bindings catalog)."
  @spec env_keys(String.t()) :: [String.t()]
  def env_keys(user_id) when is_binary(user_id) do
    Repo.all(from c in Connection, where: c.user_id == ^user_id, select: c.env_key)
  end

  @doc """
  The hosts a connection `env_key`'s token is implicitly bound to as a
  bearer — the provider's `token_hosts` — or `[]` for a key that is not a
  connection's. A second account of the same provider is
  `GOOGLE_ACCESS_TOKEN_2`, and binds the same way.
  """
  @spec implicit_hosts(String.t(), String.t()) :: [String.t()]
  def implicit_hosts(user_id, key) when is_binary(user_id) and is_binary(key) do
    case Repo.get_by(Connection, user_id: user_id, env_key: key) do
      nil -> []
      conn -> provider_for(conn).token_hosts
    end
  end

  # The first account of a provider takes the bare key; each further one
  # takes the next numbered key, so every connection is addressable by name
  # in a binding and none shadows another.
  defp free_env_key(user_id, %Provider{env_key: base}) do
    taken = MapSet.new(env_keys(user_id))

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}_#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp fresh?(%Connection{access_token_ciphertext: nil}), do: false
  # No expiry known: the provider said nothing, and the token stands until
  # the provider refuses it.
  defp fresh?(%Connection{expires_at: nil}), do: true

  defp fresh?(%Connection{expires_at: at}) do
    DateTime.diff(at, DateTime.utc_now(), :second) > @refresh_margin_seconds
  end

  defp lapsed?(%Connection{expires_at: %DateTime{} = at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp lapsed?(_), do: false

  # Refreshes are serialized per connection under an advisory lock, and the
  # row is re-read under it. Without both, two conversations refreshing the
  # same stale connection race: the first rotates the refresh token, the
  # second replays the stale one, and a provider that rotates strictly
  # answers `invalid_grant` — which would revoke a freshly valid connection.
  # The lock spans the provider round-trip, so a waiter can sit for one HTTP
  # timeout before its own; the transaction timeout allows for both.
  defp refresh_token(conn, dek) do
    outcome =
      Repo.transaction(
        fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
            @refresh_lock_namespace,
            :erlang.phash2(conn.id)
          ])

          case Repo.get(Connection, conn.id) do
            nil -> {:error, :no_token}
            current -> locked_refresh(current, dek)
          end
        end,
        timeout: Application.get_env(:fountain, :connections_timeout_ms, 15_000) * 2 + 5_000
      )

    # The status writes that follow a refusal audit, and an audit must not
    # run inside a transaction (ADR 0013), so they happen out here.
    case outcome do
      {:ok, {:refused, current}} ->
        _ = mark_refused(current)
        {:error, :revoked}

      {:ok, {:no_refresh_token, current}} ->
        expire(current, dek)

      {:ok, result} ->
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A concurrent refresh may have finished while we waited on the lock: the
  # re-read row can already be fresh (serve it), revoked or expired (say so),
  # or reconnected without a refresh token. Only a row still stale under the
  # lock goes to the provider — with the refresh token the row holds *now*.
  defp locked_refresh(current, dek) do
    cond do
      current.status == "revoked" -> {:error, :revoked}
      current.status == "expired" -> {:error, :expired}
      fresh?(current) -> decrypt(current.access_token_ciphertext, dek)
      is_nil(current.refresh_token_ciphertext) -> {:no_refresh_token, current}
      true -> do_refresh(current, dek)
    end
  end

  defp do_refresh(current, dek) do
    with {:ok, refresh} <- decrypt(current.refresh_token_ciphertext, dek),
         {:ok, provider} <- unlock_provider(provider_for(current)) do
      case OAuth.refresh(provider, refresh) do
        {:ok, %{access_token: access} = fresh} ->
          case current |> Connection.refresh_changeset(fresh, dek) |> Repo.update() do
            {:ok, _} -> {:ok, access}
            {:error, changeset} -> {:error, changeset}
          end

        {:error, :invalid_grant} ->
          {:refused, current}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp decrypt(nil, _dek), do: {:error, :no_token}

  defp decrypt(blob, dek) do
    case Crypto.decrypt(blob, dek) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :undecryptable}
    end
  end

  # `dump/1`, not `cast/1`: cast reads any 16-byte binary as a uuid, so a
  # sixteen-character name passed this guard and raised at the query anyway
  # (#1679).
  defp valid_uuid?(id), do: match?({:ok, _}, Ecto.UUID.dump(id))

  defp present?(v), do: is_binary(v) and v != ""

  defp string_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # Provider, scopes and the label name the connection; no token is ever
  # in the trail (ADR 0013).
  defp audited({:ok, %Connection{} = conn} = ok, action, opts) do
    metadata = %{
      "provider" => conn.provider,
      "provider_id" => conn.provider_id,
      "account_email" => conn.account_email,
      "scopes" => conn.scopes,
      "env_key" => conn.env_key
    }

    opts = Keyword.update(opts, :metadata, metadata, &Map.merge(metadata, &1))
    Audit.record_resource(action, "connection", conn, opts)
    ok
  end

  defp audited(other, _action, _opts), do: other

  # Slug, kind and name; never the client secret. An update names the
  # fields that changed.
  # The plaintext secret does not travel on the returned struct either.
  defp audited_provider({:ok, %Provider{} = p}, action, opts) do
    metadata = %{"slug" => p.slug, "kind" => p.kind, "name" => p.name, "env_key" => p.env_key}
    opts = Keyword.update(opts, :metadata, metadata, &Map.merge(metadata, &1))
    Audit.record_resource(action, "connection_provider", p, opts)
    {:ok, %{p | client_secret: nil}}
  end

  defp audited_provider(other, _action, _opts), do: other
end
