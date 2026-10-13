defmodule Fountain.Workers.AccountEmail do
  @moduledoc """
  Account-state notifications (#450): suspended, unsuspended, deleted.

  A deletion has no user row left to guard on at all, which is why the kinds
  carry what they need.

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
  """
  def enqueue_deleted(email) when is_binary(email) do
    %{email: email, kind: "deleted"} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "deleted", "email" => email}}) do
    deliver("deleted", email, fn -> UserEmails.deliver_account_deleted_email(email) end)
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
