defmodule Fountain.OAuth do
  @moduledoc """
  Fountain as the OAuth 2.0 authorization server for its own first-party
  apps — the standalone conversations client on another origin
  (#818) and the CLI's device login (#1305).

  The problem it solves: those apps authenticate every API call with a
  bearer API key, and until now the key had to be pasted in. This turns a
  Fountain *session* (however it was opened — password or GitHub) into an
  API key for the app, with the user's consent, without the app ever seeing
  credentials.

  The grant is **authorization code + PKCE (S256), public clients only** —
  what a browser app can do safely — plus the device grant for a terminal
  that cannot hold a password. There is no client secret; the redirect URI
  allowlist and the PKCE verifier are what bind a code to the app that
  started the flow.

  This module owns the client registry and request validation. The grant
  state machine is `Managoat.OAuth.Codes` (code + PKCE) and
  `Managoat.OAuth.Device` (device grant), folded back from the
  `managoat_oauth` library (ADR 0037). What the state machine asks of the
  platform is `Fountain.OAuth.Host`: whether a user may hold a key, minting
  the key, and the audit trail.

  ## Clients

  Two registries. Application config holds the operator's — `config :fountain,
  Fountain.OAuth, clients: [%{id, name, redirect_uris}]`, which runtime.exs
  reads from `OAUTH_CLIENTS` as JSON — and the `oauth_clients` table holds
  the ones a tenant registers for itself (#1125). Config wins on a collision,
  so a row can never shadow a first-party client.

  **Development mode is the security boundary, not the redirect allowlist.**
  A row starts unpublished, and an unpublished client authorizes only its
  owner: every other account is rendered an error page, never redirected.
  That is what makes a self-chosen redirect URI safe — the only account such
  a client can capture belongs to the person who registered it — and it is
  why its owner may name any HTTPS redirect or an HTTP loopback one.
  `published` is an operator flip with no self-serve path, and a published
  client is an ordinary first-party client on config's terms.

  Redirect URIs match **exactly**, except that an unpublished loopback
  redirect matches on any port (RFC 8252 §7.3), because the port a local dev
  server lands on is not a fact anybody registered.

  `redirect_registered?/2` is the **only** redirect gate in the server.
  `Managoat.OAuth.Codes.authorize/4` stores the redirect URI it is handed
  without checking it again, so loosening the check here loosens everything;
  there is nothing behind it.

  ## Tokens are API keys

  A successful exchange mints an ordinary API key (`Accounts.create_api_key/3`)
  named `oauth:<client_id>`, full scope, with an expiry — so it lists and
  revokes under Account → API keys, `TenantAPIAuth` needs no change, and the
  audit trail already knows the shape. No refresh tokens (yet): the app
  signs in again when the key expires.
  """

  import Ecto.Query, warn: false

  alias Fountain.{Accounts, Audit, Repo}
  alias Fountain.OAuth.Client
  alias Managoat.OAuth.{Codes, Device}

  # An abuse ceiling, not an allowance: every row here will widen the
  # deployment's CORS allowlist (ADR 0021), so registration must not be
  # unbounded.
  @max_clients_per_account 25

  @type client :: %{
          id: String.t(),
          name: String.t(),
          redirect_uris: [String.t()],
          published: boolean(),
          owner_id: String.t() | nil,
          record_id: String.t() | nil
        }

  @doc """
  Operator-configured clients, treated as published.

  Configuration is still the authority for first-party apps. It wins over a
  database row with the same id, so a tenant cannot shadow an operator app.
  """
  @spec config_clients() :: [client()]
  def config_clients do
    clients = :fountain |> Application.get_env(__MODULE__, []) |> Keyword.get(:clients)
    Enum.map(clients || [], &config_client/1)
  end

  # `OAUTH_CLIENTS` is JSON, so an entry may be string-keyed; `name` falls
  # back to `id`. Read on every call: runtime.exs sets the list after compile.
  defp config_client(entry) do
    id = to_string(config_field(entry, :id))

    %{
      id: id,
      name: to_string(config_field(entry, :name) || id),
      redirect_uris: Enum.map(config_field(entry, :redirect_uris) || [], &to_string/1),
      published: true,
      owner_id: nil,
      record_id: nil
    }
  end

  defp config_field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp config_field(kw, key) when is_list(kw), do: Keyword.get(kw, key)

  @doc "The client with `id`, or nil. Operator configuration wins."
  @spec get_client(term()) :: client() | nil
  def get_client(id) when is_binary(id) do
    Enum.find(config_clients(), &(&1.id == id)) || db_client(id)
  end

  def get_client(_), do: nil

  defp db_client(id) do
    case Repo.get_by(Client, client_id: id) do
      nil -> nil
      %Client{} = row -> to_client(row)
    end
  end

  defp to_client(%Client{} = row) do
    %{
      id: row.client_id,
      name: row.name,
      redirect_uris: row.redirect_uris,
      published: row.published,
      owner_id: row.user_id,
      record_id: row.id
    }
  end

  @doc """
  Validate the client, the development-mode boundary, the redirect and PKCE.
  `{:ok, client}` or `{:error, reason}`: `:unknown_client`,
  `:development_mode`, `:redirect_uri_mismatch`,
  `:unsupported_code_challenge_method` or `:invalid_code_challenge`.

  An error here must render, never redirect: a redirect to an unregistered
  URI is exactly the open redirector the allowlist exists to prevent.

  The owner check deliberately comes before redirect matching. A different
  account learns only that the client is in development mode, never which
  redirects its owner registered. With no signed-in user (`nil`), a
  development-mode client fails closed.
  """
  @spec validate_request(map(), String.t() | nil) :: {:ok, client()} | {:error, atom()}
  def validate_request(params, user_id \\ nil) when is_map(params) do
    with %{} = client <- get_client(params["client_id"]) || {:error, :unknown_client},
         true <- authorizable_by?(client, user_id) || {:error, :development_mode},
         true <-
           redirect_registered?(client, params["redirect_uri"]) ||
             {:error, :redirect_uri_mismatch},
         true <-
           (params["code_challenge_method"] || "S256") == "S256" ||
             {:error, :unsupported_code_challenge_method},
         true <- valid_challenge?(params["code_challenge"]) || {:error, :invalid_code_challenge} do
      {:ok, client}
    end
  end

  # 43..128 chars of the base64url alphabet; an S256 challenge is 43.
  defp valid_challenge?(c) when is_binary(c), do: Regex.match?(~r/^[A-Za-z0-9._~-]{43,128}$/, c)
  defp valid_challenge?(_), do: false

  @doc "Whether a subject may authorize through a client."
  @spec authorizable_by?(client(), String.t() | nil) :: boolean()
  def authorizable_by?(%{published: true}, _user_id), do: true

  def authorizable_by?(%{owner_id: owner_id}, user_id)
      when is_binary(owner_id) and is_binary(user_id),
      do: owner_id == user_id

  def authorizable_by?(_client, _user_id), do: false

  defp redirect_registered?(client, uri) when is_binary(uri) do
    cond do
      uri in client.redirect_uris -> true
      client.published -> false
      true -> Enum.any?(client.redirect_uris, &loopback_match?(&1, uri))
    end
  end

  defp redirect_registered?(_client, _uri), do: false

  defp loopback_match?(registered, requested) do
    registered = URI.parse(registered)
    requested = URI.parse(requested)

    Client.loopback?(registered.host) and Client.loopback?(requested.host) and
      registered.scheme == requested.scheme and
      String.downcase(registered.host) == String.downcase(requested.host) and
      registered.userinfo == requested.userinfo and registered.path == requested.path and
      registered.query == requested.query and registered.fragment == requested.fragment
  end

  @doc """
  The subject consented: validate the request as `subject` and issue a code.
  `{:ok, raw_code}` for the redirect, or the `validate_request/2` error.
  Audits `oauth.authorized`.
  """
  @spec authorize(String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, atom() | Ecto.Changeset.t()}
  def authorize(subject, params, opts \\ []) when is_binary(subject) and is_map(params) do
    with {:ok, client} <- validate_request(params, subject) do
      Codes.authorize(subject, client.id, params, opts)
    end
  end

  @doc "Exchange a code for an API key. See `Managoat.OAuth.Codes.exchange/2`."
  defdelegate exchange(params, opts \\ []), to: Codes

  @doc "Seconds a key minted by a code exchange lives."
  defdelegate token_ttl_seconds(), to: Codes

  @doc "Start a device grant. See `Managoat.OAuth.Device.start/1`."
  defdelegate start_device_grant(opts \\ []), to: Device, as: :start

  @doc "The pending grant behind a typed user code, for the approval page."
  defdelegate get_device_grant_for_approval(user_code), to: Device, as: :get_for_approval

  @doc "Approve the grant behind a typed user code. Audits `oauth.device_approved`."
  defdelegate approve_device_grant(user_code, user_id, opts \\ []), to: Device, as: :approve

  @doc "Deny the grant behind a typed user code. Audits `oauth.device_denied`."
  defdelegate deny_device_grant(user_code, user_id, opts \\ []), to: Device, as: :deny

  @doc "Poll a device grant. See `Managoat.OAuth.Device.poll/2`."
  defdelegate poll_device_grant(device_code, opts \\ []), to: Device, as: :poll

  @doc ~S(Format a stored user code for humans: "BCDFGHJK" → "BCDF-GHJK".)
  defdelegate format_user_code(code), to: Device

  @doc """
  The one redirect origin the consent response's `form-action` may name.

  Derived from the request's validated `redirect_uri` rather than from the
  registration, because a loopback client's port varies legally (RFC 8252):
  a header naming the registered port would have Chrome block a redirect the
  server had already approved.
  """
  @spec form_action_origins(String.t()) :: [String.t()]
  def form_action_origins(redirect_uri) do
    case Client.origin_of(redirect_uri) do
      nil -> []
      origin -> [origin]
    end
  end

  @doc """
  Revoke the token (an API key) presented by an app that is signing out.

  Fountain's own, not the library's: the library never learns what a token
  is, so revoking one is revoking an API key.
  """
  @spec revoke(Accounts.ApiKey.t(), keyword()) ::
          {:ok, Accounts.ApiKey.t()} | {:error, :not_found}
  def revoke(%Accounts.ApiKey{} = key, opts \\ []) do
    Accounts.revoke_api_key(key.user_id, key.id, opts)
  end

  @doc "A tenant's registered clients, newest first."
  @spec list_clients(String.t()) :: [Client.t()]
  def list_clients(user_id) when is_binary(user_id) do
    # `id` breaks the tie: timestamps are second-precision, so two clients
    # registered in the same second would otherwise come back in whatever
    # order the planner chose, and the console list would reorder itself.
    Repo.all(
      from c in Client,
        where: c.user_id == ^user_id,
        order_by: [desc: c.inserted_at, desc: c.id]
    )
  end

  @doc "One tenant-owned client by record id, or nil."
  @spec get_client_record(String.t(), String.t()) :: Client.t() | nil
  def get_client_record(id, user_id) when is_binary(id) and is_binary(user_id) do
    # A path segment is whatever the caller typed. Casting a non-UUID to
    # :binary_id raises, which phoenix_ecto turns into a 400 -- so the
    # documented 404 would never reach a client that mistyped an id.
    if valid_uuid?(id), do: Repo.get_by(Client, id: id, user_id: user_id)
  end

  @doc """
  Register an unpublished client for a tenant.

  The ceiling is per account rather than per deployment, and it is reported as
  an ordinary changeset error so every surface says the same thing.
  """
  @spec create_client(String.t(), map(), keyword()) ::
          {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def create_client(user_id, attrs, opts \\ []) when is_binary(user_id) and is_map(attrs) do
    changeset = Client.changeset(%Client{}, attrs, user_id)

    if client_count(user_id) >= @max_clients_per_account do
      {:error,
       changeset
       |> Ecto.Changeset.add_error(
         :base,
         "at most #{@max_clients_per_account} apps per account"
       )
       |> Map.put(:action, :insert)}
    else
      changeset |> Repo.insert() |> audited("oauth_client.created", opts)
    end
  end

  @doc """
  Rename a client or replace its redirect URIs.

  A call that moves no field succeeds and records nothing.

  `client_id`, the owner and `published` are dropped rather than rejected:
  they are not the caller's to set, and a surface that hands back what it read
  should not fail for sending a field it was given.
  """
  @spec update_client(Client.t(), map(), keyword()) ::
          {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def update_client(%Client{} = client, attrs, opts \\ []) when is_map(attrs) do
    changeset =
      client
      |> Client.changeset(Map.drop(attrs, ["user_id", "client_id", "published"]))
      |> prevent_published_update(client)

    if changeset.valid? and changeset.changes == %{} do
      # A request that moves nothing is not a change. Recording it would put a
      # row in the trail whose `changed` list is empty, which is the "logs
      # attempts as changes" shape ADR 0013 rules out. `Repo.update/1` would
      # not issue a statement here either.
      {:ok, client}
    else
      changeset
      |> Repo.update()
      |> audited(
        "oauth_client.updated",
        Keyword.put(opts, :metadata, Audit.changed_fields(changeset))
      )
    end
  end

  @doc """
  Delete a tenant-owned client.

  Refused once the client is published, for the reason `update_client/3` is:
  publication moved the trust boundary to every account, and deleting the row
  would break sign-in for all of them with a `client_id` nobody can recreate.
  """
  @spec delete_client(Client.t(), keyword()) ::
          {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def delete_client(%Client{} = client, opts \\ []) do
    if client.published do
      {:error,
       client
       |> Ecto.Changeset.change()
       |> Ecto.Changeset.add_error(
         :base,
         "published clients can only be removed by an operator"
       )
       |> Map.put(:action, :delete)}
    else
      client |> Repo.delete() |> audited("oauth_client.deleted", opts)
    end
  end

  @doc """
  Whether an origin belongs to an operator or a tenant client.

  CORS still requires a bearer key. This predicate grants no account access;
  it only lets a browser present a key it already holds from an origin some
  client registered.
  """
  @spec registered_origin?(term()) :: boolean()
  def registered_origin?(origin) when is_binary(origin) do
    case Client.origin_key(origin) do
      nil -> false
      key -> key in config_origin_keys() or Repo.exists?(origin_key_query(key))
    end
  end

  def registered_origin?(_), do: false

  defp origin_key_query(key) do
    from c in Client, where: fragment("? @> ?", c.origin_keys, ^[key])
  end

  defp config_origin_keys do
    config_clients()
    |> Enum.flat_map(& &1.redirect_uris)
    |> Client.origins_of()
    |> Enum.map(&Client.origin_key/1)
    |> Enum.reject(&is_nil/1)
  end

  defp client_count(user_id) do
    Repo.aggregate(from(c in Client, where: c.user_id == ^user_id), :count)
  end

  defp valid_uuid?(id), do: match?({:ok, _}, Ecto.UUID.cast(id))

  # Publishing changes the trust boundary from owner-only to every account.
  # The owner must not be able to change that operator-approved registration
  # afterward. An operator can unpublish it before handing control back.
  defp prevent_published_update(changeset, %Client{published: true}) do
    Ecto.Changeset.add_error(
      changeset,
      :base,
      "published clients can only be changed by an operator"
    )
  end

  defp prevent_published_update(changeset, _client), do: changeset

  # The trail names the client and where it sends people, never a secret:
  # there is none here, and the redirect URIs are what an operator reading the
  # trail actually needs (ADR 0013).
  defp audited({:ok, %Client{} = client} = ok, action, opts) do
    metadata =
      %{"client_id" => client.client_id, "redirect_uris" => client.redirect_uris}
      |> Map.merge(Keyword.get(opts, :metadata, %{}))

    Audit.record_resource(action, "oauth_client", client, Keyword.put(opts, :metadata, metadata))
    ok
  end

  defp audited(other, _action, _opts), do: other
end
