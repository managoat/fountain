defmodule Fountain.OAuth.Host do
  @moduledoc """
  The platform side of the OAuth grant state machine (`Managoat.OAuth.Codes`,
  `Managoat.OAuth.Device`; ADR 0037): the three things the state machine
  needs to know and cannot decide itself, kept apart from it so the grant
  logic names no API key and no audit action.

    * `subject_allowed?/1`: a subject is a `user_id`, and it may collect a
      key when the account exists and its email is verified. The device poll
      asks **before** consuming a grant. The console approval page sits
      behind `require_authenticated_user`, so this is belt-and-braces for
      state that changed between approval and poll.
    * `issue_token/3`: a token is an API key. `grant` says which kind:

          %{type: :authorization_code, id: code_id, client_id: "spa", expires_at: %DateTime{}}
          %{type: :device, id: grant_id, client_id: nil, expires_at: nil}

      A code exchange mints `oauth:<client_id>` with the thirty-day expiry
      the state machine set; a device grant mints `CLI login — <date>` with
      none, mirroring `POST /api/auth/token`, which the device grant replaces
      for accounts without a password. Any `{:error, _}` reaches the client
      as `server_error`.
    * `audit/3`: the trail is `Fountain.Audit`, and the three grant events
      map onto `oauth.authorized`, `oauth.device_approved` and
      `oauth.device_denied`. The state machine cannot complete any of the
      three mutations without calling it, which keeps them audited by
      construction (ADR 0013).

  `opts` is the attribution keyword the controllers and `DeviceLive` pass
  (`actor`, `request_ip`), untouched by the state machine. The defaults are
  `"ui"` for a consent or a decision in the console, `"self"` for a code
  exchange, `"api"` for a device poll.
  """

  alias Fountain.{Accounts, Audit, OAuth}

  @type grant :: %{
          type: :authorization_code | :device,
          id: binary(),
          client_id: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @doc "Whether `user_id` may collect a key right now."
  @spec subject_allowed?(binary()) :: :ok | {:error, :unknown_subject | :not_eligible}
  def subject_allowed?(user_id) do
    case Accounts.get_user(user_id) do
      nil ->
        {:error, :unknown_subject}

      user ->
        if is_nil(user.email_verified_at),
          do: {:error, :not_eligible},
          else: :ok
    end
  end

  @doc "Mint the API key for a consumed grant."
  @spec issue_token(binary(), grant(), keyword()) ::
          {:ok, %{access_token: String.t(), token: Accounts.ApiKey.t()}} | {:error, term()}
  def issue_token(user_id, %{type: :authorization_code} = grant, opts) do
    mint(user_id, "oauth:#{grant.client_id}", "self", grant.expires_at, opts)
  end

  def issue_token(user_id, %{type: :device}, opts) do
    mint(user_id, "CLI login — #{Date.utc_today()}", "api", nil, opts)
  end

  defp mint(user_id, name, default_actor, expires_at, opts) do
    case Accounts.create_api_key(user_id, name,
           expires_at: expires_at,
           actor: Keyword.get(opts, :actor, default_actor),
           request_ip: Keyword.get(opts, :request_ip)
         ) do
      {:ok, {api_key, raw_key}} -> {:ok, %{access_token: raw_key, token: api_key}}
      {:error, _} = err -> err
    end
  end

  @doc "Record a grant event in the audit trail. Always `:ok`."
  @spec audit(:authorized | :device_approved | :device_denied, map(), keyword()) :: :ok
  def audit(:authorized, meta, opts) do
    # A tenant-registered client is a row, so the trail can point at it. A
    # configured one is not, and stays a client_id in the metadata.
    resource_id =
      case OAuth.get_client(meta.client_id) do
        %{record_id: id} when is_binary(id) -> id
        _ -> nil
      end

    Audit.record(%{
      user_id: meta.subject_id,
      action: "oauth.authorized",
      resource_type: "oauth_client",
      resource_id: resource_id,
      actor: Keyword.get(opts, :actor, "ui"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{"client_id" => meta.client_id, "redirect_uri" => meta.redirect_uri}
    })

    :ok
  end

  def audit(event, meta, opts) when event in [:device_approved, :device_denied] do
    Audit.record(%{
      user_id: meta.subject_id,
      action: "oauth.#{event}",
      resource_type: "oauth_device_grant",
      resource_id: meta.grant_id,
      actor: Keyword.get(opts, :actor, "ui"),
      request_ip: Keyword.get(opts, :request_ip)
    })

    :ok
  end
end
