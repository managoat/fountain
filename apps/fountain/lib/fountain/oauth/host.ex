defmodule Fountain.OAuth.Host do
  @moduledoc """
  What `Managoat.OAuth` asks of Fountain (ADR 0037, #1343): the three things
  the grant state machine needs from the platform and cannot decide itself.

    * a subject is a `user_id`, and it may collect a key when the account
      is neither suspended nor unverified — the check `poll_device_grant/2`
      makes before consuming a grant. The console's approval page sits
      behind `require_authenticated_user`, which turns away both, so this is
      belt-and-braces for state that changed between approval and poll.
    * a token is an API key: `oauth:<client_id>` with the library's
      thirty-day expiry for a code exchange, `CLI login — <date>` with none
      for a device grant, mirroring `POST /api/auth/token` which the device
      grant replaces for accounts without a password.
    * the audit trail is `Fountain.Audit`, and the three library events map
      onto the actions the trail has always carried: `oauth.authorized`,
      `oauth.device_approved`, `oauth.device_denied`. The library cannot
      complete any of the three mutations without calling `audit/3`, which
      is what keeps them audited by construction (ADR 0013) now that the
      recording no longer sits in a Fountain context.

  `opts` is the attribution keyword the controllers and `DeviceLive` pass
  (`actor`, `request_ip`), untouched by the library. The defaults are the
  ones the recording had before it moved: `"ui"` for a consent or a decision
  in the console, `"self"` for a code exchange, `"api"` for a device poll.
  """

  @behaviour Managoat.OAuth.Host

  alias Fountain.{Accounts, Audit, OAuth}

  @impl true
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

  @impl true
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

  @impl true
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
