defmodule Fountain.Emails.UserEmails do
  @moduledoc """
  Swoosh templates for account email — the mail any instance needs.

  Sends:
  - Email verification (24 h token, from `Workers.VerificationEmail`)
  - Password reset (1 h token)
  - Account suspended / unsuspended / deleted (from `Workers.AccountEmail`)
  - Email-change confirmation + notice (from `Workers.EmailChangeEmail`)

  The welcome and the credit emails (credits low, exhausted) live
  in `Fountain.Emails.CreditsEmails` under ee/ (#475) — it borrows
  `from_address/0` and `support_phrase/0` from here so the whole mail
  surface keeps one sender and one support-contact policy.
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
  Tell a user their account was suspended (#450).

  Before this the only signal was a generic "account currently unavailable"
  at the next login attempt — no explanation, no route to appeal. Deliberately
  does not say *why*: the reason lives in the admin audit trail, and an email
  template can't know it. Points at support instead.
  """
  @spec deliver_account_suspended_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_account_suspended_email(%User{} = user) do
    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Your #{brand()} account has been suspended")
    |> html_body(account_suspended_html())
    |> text_body(account_suspended_text())
    |> Mailer.deliver()
  end

  @doc "The counterpart: the suspension was lifted; sign in again (#450)."
  @spec deliver_account_unsuspended_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_account_unsuspended_email(%User{} = user) do
    login_url = "#{Fountain.PublicUrl.base()}/auth/login"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Your #{brand()} account is available again")
    |> html_body(account_unsuspended_html(login_url))
    |> text_body(account_unsuspended_text(login_url))
    |> Mailer.deliver()
  end

  @doc """
  Tell an owner that a webhook endpoint was switched off (#700).

  Sent once, by `Workers.WebhookEmail`, when consecutive delivery failures
  cross the threshold. Names the host and the reason and nothing else: the
  URL path is tenant-chosen and the response body is in the delivery log,
  behind the console's auth, where it belongs.
  """
  @spec deliver_webhook_disabled_email(User.t(), String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_webhook_disabled_email(%User{} = user, host, reason) do
    url = "#{Fountain.PublicUrl.base()}/account/webhooks"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Your #{brand()} webhook to #{host} was switched off")
    |> html_body(webhook_disabled_html(host, reason, url))
    |> text_body(webhook_disabled_text(host, reason, url))
    |> Mailer.deliver()
  end

  @doc """
  Warn an owner that vault secrets are about to expire.

  Sent by `Workers.SecretExpirySweeper`, once per recorded expiry, listing
  every due secret the owner has in one mail. Names vaults and keys only —
  the values never leave the vault, expiring or not.
  """
  @spec deliver_vault_secrets_expiring_email(User.t(), [map()]) ::
          {:ok, term()} | {:error, term()}
  def deliver_vault_secrets_expiring_email(%User{} = user, [_ | _] = entries) do
    url = "#{Fountain.PublicUrl.base()}/vaults"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject(secrets_expiring_subject(entries))
    |> html_body(secrets_expiring_html(entries, url))
    |> text_body(secrets_expiring_text(entries, url))
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
  about the two things that survive: Stripe keeps the invoices (financial
  records), and backups age out on their own schedule.
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

  @doc """
  The email-change confirmation, sent to the NEW address (#448).

  Clicking the link is what performs the change; until then nothing happens,
  and the copy says so — the recipient may never have heard of Fountain.
  """
  @spec deliver_email_change_confirmation(String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_email_change_confirmation(new_email, token) when is_binary(new_email) do
    confirm_url = "#{Fountain.PublicUrl.base()}/account/email/confirm/#{token}"

    new()
    |> from(from_address())
    |> to({new_email, new_email})
    |> subject("Confirm your new #{brand()} email address")
    |> html_body(email_change_html(confirm_url))
    |> text_body(email_change_text(confirm_url))
    |> Mailer.deliver()
  end

  @doc """
  Tell the OLD address its account's email changed (#448). This is the
  account-takeover tripwire: the old address can no longer sign in, so the
  copy points at support rather than at a login form.
  """
  @spec deliver_email_changed_notice(String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_email_changed_notice(old_email, new_email) do
    new()
    |> from(from_address())
    |> to({old_email, old_email})
    |> subject("Your #{brand()} email address was changed")
    |> html_body(email_changed_notice_html(new_email))
    |> text_body(email_changed_notice_text(new_email))
    |> Mailer.deliver()
  end

  ## Private helpers

  defp email_change_html(url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Confirm your new #{brand()} email address</h2>
      <p>
        A #{brand()} account asked to change its email address to this one.
        Click the button below to confirm — the change only happens when you
        do. The link expires in 24 hours.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Confirm new address
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{url}" style="color: #3b82f6;">#{url}</a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you didn't request this, you can safely ignore this email — nothing
        changes unless the link is clicked.
      </p>
    </body>
    </html>
    """
  end

  defp email_change_text(url) do
    """
    Confirm your new #{brand()} email address

    A #{brand()} account asked to change its email address to this one. Open
    the link below to confirm — the change only happens when you do. The link
    expires in 24 hours.

    #{url}

    If you didn't request this, you can safely ignore this email — nothing
    changes unless the link is clicked.
    """
  end

  defp email_changed_notice_html(new_email) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your #{brand()} email address was changed</h2>
      <p>
        The email address on your #{brand()} account was changed to
        <strong>#{new_email}</strong>. This address can no longer be used to
        sign in.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you made this change, no action is needed. If you did not,
        #{support_phrase()} immediately — do not wait.
      </p>
    </body>
    </html>
    """
  end

  defp email_changed_notice_text(new_email) do
    """
    Your #{brand()} email address was changed

    The email address on your #{brand()} account was changed to #{new_email}.
    This address can no longer be used to sign in.

    If you made this change, no action is needed. If you did not,
    #{support_phrase()} immediately — do not wait.
    """
  end

  # The deployment's brand (PRODUCT_NAME), which is what every subject line and
  # body calls the service. Public: CreditsEmails (ee/) shares it too.
  @doc false
  def brand, do: Fountain.Brand.name()

  # Public (not defp): Fountain.Emails.CreditsEmails (ee/) shares the sender
  # and support-contact policy rather than duplicating it.
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

  defp webhook_disabled_html(host, reason, url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>A webhook endpoint was switched off</h2>
      <p>
        #{brand()} stopped delivering events to <strong>#{host}</strong> after
        repeated failures. The last one was: #{reason}.
      </p>
      <p>
        Nothing else changed. Your agents and conversations carry on; only the
        callbacks to this URL have stopped. Fix the receiver, then switch the
        endpoint back on and send a test event.
      </p>
      <p><a href="#{url}">#{url}</a></p>
      <p style="color: #71717a; font-size: 13px;">
        Every attempt, with its status and response, is on that page. If this
        looks wrong, #{support_phrase()}.
      </p>
    </body>
    </html>
    """
  end

  defp webhook_disabled_text(host, reason, url) do
    """
    A webhook endpoint was switched off

    #{brand()} stopped delivering events to #{host} after repeated failures.
    The last one was: #{reason}.

    Nothing else changed. Your agents and conversations carry on; only the
    callbacks to this URL have stopped. Fix the receiver, then switch the
    endpoint back on and send a test event.

    #{url}

    Every attempt, with its status and response, is on that page.
    If this looks wrong, #{support_phrase()}.
    """
  end

  defp secrets_expiring_html(entries, url) do
    rows =
      Enum.map_join(entries, "\n", fn e ->
        "<li><strong>#{Plug.HTML.html_escape(e.key)}</strong> in vault <strong>#{Plug.HTML.html_escape(e.vault_name)}</strong> — expires #{expiry_date(e.expires_at)}</li>"
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
        find out. Rotate the value and record the new expiry.
      </p>
      <p><a href="#{url}">#{url}</a></p>
      <p style="color: #71717a; font-size: 13px;">
        You get this notice once per recorded expiry. If this looks wrong,
        #{support_phrase()}.
      </p>
    </body>
    </html>
    """
  end

  defp secrets_expiring_text(entries, url) do
    rows =
      Enum.map_join(entries, "\n", fn e ->
        "  - #{e.key} in vault #{e.vault_name} — expires #{expiry_date(e.expires_at)}"
      end)

    """
    Vault secrets expiring soon

    You recorded an expiry date on these vault secrets, and it is close:

    #{rows}

    Nothing stops on that date on #{brand()}'s side — but an agent handed an
    expired credential fails mid-conversation, which is a worse place to
    find out. Rotate the value and record the new expiry.

    #{url}

    You get this notice once per recorded expiry. If this looks wrong,
    #{support_phrase()}.
    """
  end

  defp expiry_date(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()

  defp account_suspended_html do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your #{brand()} account has been suspended</h2>
      <p>
        Your account has been suspended: existing sessions are signed out, API
        keys stop working, and running conversations have been stopped.
      </p>
      <p>
        <strong>Nothing is deleted.</strong> Your agents, environments, vaults and
        conversation history stay exactly as they are, and your credit balance is
        not changed by a suspension.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you believe this is an error, #{support_phrase()}.
      </p>
    </body>
    </html>
    """
  end

  defp account_suspended_text do
    """
    Your #{brand()} account has been suspended

    Your account has been suspended: existing sessions are signed out, API
    keys stop working, and running conversations have been stopped.

    Nothing is deleted. Your agents, environments, vaults and conversation
    history stay exactly as they are, and your credit balance is not changed
    by a suspension.

    If you believe this is an error, #{support_phrase()}.
    """
  end

  defp account_unsuspended_html(login_url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your #{brand()} account is available again</h2>
      <p>
        The suspension on your account has been lifted. Sign in to pick up
        where you left off — everything is as you left it.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{login_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Sign in
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{login_url}" style="color: #3b82f6;">#{login_url}</a>
      </p>
    </body>
    </html>
    """
  end

  defp account_unsuspended_text(login_url) do
    """
    Your #{brand()} account is available again

    The suspension on your account has been lifted. Sign in to pick up where
    you left off — everything is as you left it:

    #{login_url}
    """
  end

  defp account_deleted_html do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your #{brand()} account has been deleted</h2>
      <p>
        This confirms your #{brand()} account and its data — agents,
        environments, vaults, conversations and stored secrets — have been
        permanently deleted. Nothing recurs, so nothing was cancelled; you
        will not be charged again.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Past invoices remain available from Stripe, as financial records.
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
    Nothing recurs, so nothing was cancelled; you will not be charged again.

    Past invoices remain available from Stripe, as financial records. Database
    backups that predate the deletion age out on their own retention schedule.

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
