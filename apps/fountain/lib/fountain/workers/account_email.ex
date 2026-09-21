defmodule Fountain.Workers.AccountEmail do
  @moduledoc """
  Account-state notifications (#450): suspended, unsuspended, deleted.

  Separate from the credit emails (`Workers.CreditsEmail`, ee) because these
  are not about money and their guards don't fit — a suspension can happen to
  an account at any balance, and a deletion has no user row left to guard on
  at all.

  State-dependent kinds re-check at send time: a suspension lifted before the
  queue drained must not then be announced. The `"deleted"` kind carries the
  address itself (captured before the row delete) and sends unconditionally —
  there is nothing left to check against. Verification is enforced where the
  user row still exists: the worker skips unverified accounts, and the
  deletion path only enqueues for verified ones, so no kind ever confirms an
  unverified address exists.
  """

  use Oban.Worker,
    queue: :mailer,
    max_attempts: 5,
    unique: [period: 300, fields: [:worker, :args]]

  require Logger

  alias Fountain.{Accounts, Emails.UserEmails}

  @doc "Enqueue the suspension notice for `user`."
  def enqueue_suspended(%Accounts.User{id: id}) do
    %{user_id: id, kind: "suspended"} |> new() |> Oban.insert()
  end

  @doc "Enqueue the suspension-lifted notice for `user`."
  def enqueue_unsuspended(%Accounts.User{id: id}) do
    %{user_id: id, kind: "unsuspended"} |> new() |> Oban.insert()
  end

  @doc """
  Enqueue the deletion confirmation for a raw address — call BEFORE the row
  delete commits is fine (the job only carries the string), but the caller
  must have already established the address was verified.

  `chatgpt_subscriptions: n` is how many ChatGPT subscriptions the account
  had linked, counted before the delete (ADR 0060 stage 5). It is a number
  in the args and only when there were any, so the email can say that their
  sign-ins were not revoked at OpenAI.
  """
  def enqueue_deleted(email, opts \\ []) when is_binary(email) do
    args =
      case Keyword.get(opts, :chatgpt_subscriptions, 0) do
        count when is_integer(count) and count > 0 ->
          %{email: email, kind: "deleted", chatgpt_subscriptions: count}

        _ ->
          %{email: email, kind: "deleted"}
      end

    args |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "deleted", "email" => email} = args}) do
    subscriptions = Map.get(args, "chatgpt_subscriptions", 0)

    deliver("deleted", email, fn ->
      UserEmails.deliver_account_deleted_email(email, chatgpt_subscriptions: subscriptions)
    end)
  end

  def perform(%Oban.Job{args: %{"kind" => kind, "user_id" => user_id}})
      when kind in ["suspended", "unsuspended"] do
    case Accounts.get_user(user_id) do
      nil ->
        Logger.info("account_email: user #{user_id} no longer exists")
        :ok

      %{email_verified_at: nil} ->
        # Never confirm an unverified address exists, whatever the state.
        :ok

      user ->
        maybe_send(user, kind)
    end
  end

  # Send only while the state the email describes still holds.
  defp maybe_send(%{suspended_at: %DateTime{}} = user, "suspended"),
    do: deliver("suspended", user.id, fn -> UserEmails.deliver_account_suspended_email(user) end)

  defp maybe_send(%{suspended_at: nil} = user, "unsuspended"),
    do:
      deliver("unsuspended", user.id, fn ->
        UserEmails.deliver_account_unsuspended_email(user)
      end)

  defp maybe_send(user, kind) do
    Logger.info("account_email: skipping #{kind} for #{user.id}, state has moved on")
    :ok
  end

  defp deliver(kind, ref, fun) do
    case fun.() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("account_email: #{kind} delivery failed for #{ref}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
