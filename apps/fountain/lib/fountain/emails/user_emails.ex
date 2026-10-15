defmodule Fountain.Emails.UserEmails do
  @moduledoc """
  Swoosh templates for account email — the mail any instance needs.

  Sends:
  - Email verification (24 h token, from `Workers.VerificationEmail`)
  - Password reset (1 h token)
  - Account deleted (from `Workers.AccountEmail`)
  """

  import Swoosh.Email

  alias Fountain.Accounts.User
  alias Fountain.Mailer

  @doc """
  Build and deliver a verification email.

  `token` is a `Phoenix.Token`-signed string encoding the user id.
  The recipient must click the link within 24 hours.
  """
  @spec deliver_verification_email(User.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_verification_email(%User{} = user, token) do
    base_url = Fountain.PublicUrl.base()
    verify_url = "#{base_url}/users/confirm/#{token}"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Verify your #{brand()} account")
    |> html_body(verification_html(verify_url))
    |> text_body(verification_text(verify_url))
    |> Mailer.deliver()
  end

  @doc """
  Build and deliver a password-reset email.

  `token` is a `Phoenix.Token`-signed string. The link expires in 1 hour.
  """
  @spec deliver_password_reset_email(User.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_password_reset_email(%User{} = user, token) do
    base_url = Fountain.PublicUrl.base()
    reset_url = "#{base_url}/auth/reset/#{token}"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Reset your #{brand()} password")
    |> html_body(reset_html(reset_url))
    |> text_body(reset_text(reset_url))
    |> Mailer.deliver()
  end

  @doc """
  Warn an owner that vault secrets are about to expire.

  Sent by `Workers.SecretExpirySweeper`, once per recorded expiry, listing
  every due secret the owner has in one mail. Names vaults and keys only —
  the values never leave the vault, expiring or not.

  It links no page: the console has no vault pages (ADR 0076). Each entry
  carries the CLI command that replaces the value, and the mail names the
  API call that records the new expiry, which `fountain vault set-secret`
  keeps as it was.
  """
  @spec deliver_vault_secrets_expiring_email(User.t(), [map()]) ::
          {:ok, term()} | {:error, term()}
  def deliver_vault_secrets_expiring_email(%User{} = user, [_ | _] = entries) do
    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject(secrets_expiring_subject(entries))
    |> html_body(secrets_expiring_html(entries))
    |> text_body(secrets_expiring_text(entries))
    |> Mailer.deliver()
  end

  defp secrets_expiring_subject([%{key: key} = entry]) do
    if expired?(entry),
      do: "Your vault secret #{key} has expired",
      else: "Your vault secret #{key} expires soon"
  end

  defp secrets_expiring_subject(entries) do
    if Enum.any?(entries, &expired?/1),
      do: "#{length(entries)} of your vault secrets have expired or expire soon",
      else: "#{length(entries)} of your vault secrets expire soon"
  end

  defp expired?(%{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :lt

  @doc """
  Confirm an account deletion (#450).

  Takes a raw address, not a `User` — by send time the row is gone. Honest
  about the thing that survives: backups age out on their own schedule.
  """
  @spec deliver_account_deleted_email(String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_account_deleted_email(email) when is_binary(email) do
    new()
    |> from(from_address())
    |> to({email, email})
    |> subject("Your #{brand()} account has been deleted")
    |> html_body(account_deleted_html())
    |> text_body(account_deleted_text())
    |> Mailer.deliver()
  end

  ## Private helpers

  # The deployment's brand (PRODUCT_NAME), which is what every subject line and
  # body calls the service.
  @doc false
  def brand, do: Fountain.Brand.name()

  @doc false
  def from_address do
    # The fallback only ever renders in dev/test (the Local mailbox) and under
    # EMAIL_DELIVERY=none, where nothing is sent: prod refuses to boot with a
    # real adapter and no EMAIL_FROM (config/runtime.exs).
    addr = Application.get_env(:fountain, :email_from, "noreply@localhost")
    {addr, addr}
  end

  # "contact us at x@y" when SUPPORT_EMAIL is configured; a from-address that
  # starts with noreply@ makes "reply to this email" a lie, so without it the
  # copy stays vague rather than pointing somewhere replies go to die.
  # Public for the same reason as from_address/0.
  @doc false
  def support_phrase do
    case Application.get_env(:fountain, :support_email) do
      addr when is_binary(addr) and addr != "" -> "contact us at #{addr}"
      _ -> "contact support"
    end
  end

  defp secrets_expiring_html(entries) do
    rows =
      Enum.map_join(entries, "\n", fn e ->
        "<li><strong>#{Plug.HTML.html_escape(e.key)}</strong> in vault <strong>#{Plug.HTML.html_escape(e.vault_name)}</strong> — expires #{expiry_date(e.expires_at)}<br>" <>
          "<code>#{Plug.HTML.html_escape(rotate_command(e))}</code></li>"
      end)

    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Vault secrets expiring soon</h2>
      <p>
        You recorded an expiry date on these vault secrets, and it is close:
      </p>
      <ul>
        #{rows}
      </ul>
      <p>
        Nothing stops on that date on #{brand()}'s side — but an agent handed an
        expired credential fails mid-conversation, which is a worse place to
        find out. Rotate the value with the command under each key, then
        record the new expiry with
        <code>PATCH /api/vaults/&lt;vault-id&gt;/secrets/&lt;key&gt;</code> and
        <code>{"expires_at": "…"}</code>; replacing the value keeps the old date.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        You get this notice once per recorded expiry. If this looks wrong,
        #{support_phrase()}.
      </p>
    </body>
    </html>
    """
  end

  defp secrets_expiring_text(entries) do
    rows =
      Enum.map_join(entries, "\n", fn e ->
        "  - #{e.key} in vault #{e.vault_name} — expires #{expiry_date(e.expires_at)}\n" <>
          "      #{rotate_command(e)}"
      end)

    """
    Vault secrets expiring soon

    You recorded an expiry date on these vault secrets, and it is close:

    #{rows}

    Nothing stops on that date on #{brand()}'s side — but an agent handed an
    expired credential fails mid-conversation, which is a worse place to
    find out. Rotate the value with the command under each key, then record
    the new expiry with PATCH /api/vaults/<vault-id>/secrets/<key> and
    {"expires_at": "…"}; replacing the value keeps the old date.

    You get this notice once per recorded expiry. If this looks wrong,
    #{support_phrase()}.
    """
  end

  # The CLI takes a vault by name or id. The name is quoted for a shell
  # because a vault name may hold spaces; the value is left for the reader.
  defp rotate_command(%{vault_name: vault_name, key: key}),
    do: ~s(fountain vault set-secret "#{vault_name}" #{key} <new-value>)

  defp expiry_date(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()

  defp account_deleted_html do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your #{brand()} account has been deleted</h2>
      <p>
        This confirms your #{brand()} account and its data — agents,
        environments, vaults, conversations and stored secrets — have been
        permanently deleted.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Database backups that predate the deletion age out on their own
        retention schedule.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you did not request this, #{support_phrase()} immediately.
      </p>
    </body>
    </html>
    """
  end

  defp account_deleted_text do
    """
    Your #{brand()} account has been deleted

    This confirms your #{brand()} account and its data — agents, environments,
    vaults, conversations and stored secrets — have been permanently deleted.

    Database backups that predate the deletion age out on their own retention
    schedule.

    If you did not request this, #{support_phrase()} immediately.
    """
  end

  defp verification_html(url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Verify your #{brand()} account</h2>
      <p>Click the button below to verify your email address. This link expires in 24 hours.</p>
      <p style="margin: 32px 0;">
        <a href="#{url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Verify email address
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{url}" style="color: #3b82f6;">#{url}</a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you didn't sign up for #{brand()}, you can safely ignore this email.
      </p>
    </body>
    </html>
    """
  end

  defp verification_text(url) do
    """
    Verify your #{brand()} account

    Click the link below to verify your email address.
    This link expires in 24 hours.

    #{url}

    If you didn't sign up for #{brand()}, you can safely ignore this email.
    """
  end

  defp reset_html(url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Reset your #{brand()} password</h2>
      <p>Someone requested a password reset for your account. Click the button below to set a new password. This link expires in 1 hour.</p>
      <p style="margin: 32px 0;">
        <a href="#{url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Reset password
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{url}" style="color: #3b82f6;">#{url}</a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you didn't request a password reset, you can safely ignore this email.
        Your password has not been changed.
      </p>
    </body>
    </html>
    """
  end

  defp reset_text(url) do
    """
    Reset your #{brand()} password

    Someone requested a password reset for your account.
    Click the link below to set a new password.
    This link expires in 1 hour.

    #{url}

    If you didn't request a password reset, you can safely ignore this email.
    Your password has not been changed.
    """
  end
end
