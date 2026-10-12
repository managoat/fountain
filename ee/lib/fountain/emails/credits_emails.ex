defmodule Fountain.Emails.CreditsEmails do
  @moduledoc """
  Swoosh templates for the credit emails (EE).

  Split out of `Fountain.Emails.UserEmails` in #475: account mail
  (verification, password reset, suspension, deletion, email change) is core;
  everything here only makes sense on an instance with billing enabled.

  Sends:
  - Credits low and credits exhausted (from `Workers.CreditsEmail`, after a
    burn crosses the threshold or zero)

  Shares `UserEmails.from_address/0` and `UserEmails.support_phrase/0` so the
  whole mail surface keeps one sender and one support-contact policy.
  """

  import Swoosh.Email

  alias Fountain.Accounts.User
  alias Fountain.Emails.UserEmails
  alias Fountain.Mailer

  defp brand, do: UserEmails.brand()

  @doc """
  The prepaid balance is under the runway line (ADR 0030 decision 6).
  """
  @spec deliver_credits_low_email(User.t(), integer()) :: {:ok, term()} | {:error, term()}
  def deliver_credits_low_email(%User{} = user, balance_cents) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"
    balance = Fountain.Credits.format_cents(balance_cents)

    new()
    |> from(UserEmails.from_address())
    |> to({user.email, user.email})
    |> subject("Your #{brand()} credit is running low")
    |> html_body(credits_html("Your credit is running low", balance, billing_url, false))
    |> text_body(credits_text("Your credit is running low", balance, billing_url, false))
    |> Mailer.deliver()
  end

  @doc """
  The prepaid balance is at or below zero: new work is refused until it is
  positive again (`Credits.gate/1`). Only sent while billing is on.
  """
  @spec deliver_credits_exhausted_email(User.t(), integer()) :: {:ok, term()} | {:error, term()}
  def deliver_credits_exhausted_email(%User{} = user, balance_cents) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"
    balance = Fountain.Credits.format_cents(balance_cents)

    new()
    |> from(UserEmails.from_address())
    |> to({user.email, user.email})
    |> subject("Your #{brand()} credit has run out")
    |> html_body(credits_html("Your credit has run out", balance, billing_url, true))
    |> text_body(credits_text("Your credit has run out", balance, billing_url, true))
    |> Mailer.deliver()
  end

  defp credits_consequence(true),
    do:
      "New conversations and new turns are paused until the balance is positive again. Anything already running finishes."

  defp credits_consequence(false),
    do: "Top up now so your agents keep working when it runs out."

  defp credits_html(title, balance, billing_url, exhausted?) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>#{title}</h2>
      <p>Your prepaid balance is <strong>#{balance}</strong>.</p>
      <p>#{credits_consequence(exhausted?)}</p>
      <p style="margin: 32px 0;">
        <a href="#{billing_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Buy credits
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Credits you buy never expire and are spent after any credit that does.
      </p>
    </body>
    </html>
    """
  end

  defp credits_text(title, balance, billing_url, exhausted?) do
    """
    #{title}

    Your prepaid balance is #{balance}.

    #{credits_consequence(exhausted?)}

    Buy credits: #{billing_url}

    Credits you buy never expire and are spent after any credit that does.
    """
  end
end
