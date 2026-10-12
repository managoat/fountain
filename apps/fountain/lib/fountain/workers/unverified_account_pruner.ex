defmodule Fountain.Workers.UnverifiedAccountPruner do
  @moduledoc """
  Deletes accounts that registered and never verified their email (#258).

  An unverified account can authenticate but reaches nothing: the session is
  held on `/auth/verify-pending`, and the API refuses to mint or accept a key
  (#533). So after the grace period they are rows, not users. They are not free rows
  either: each carries a wrapped DEK, they distort every metric that counts
  `users`, and 158 of them were briefly mistaken for a 159-person legacy
  cohort of the subscription era (#258). The steady inflow is drive-by/bot
  registration (#259).

  Deletion goes through `Accounts.Deletion.delete_user/2` — the same teardown
  as self-serve and admin deletion (sprites, audit row) — never a bare
  `DELETE`. An unverified account holds no credit (the opening grant lands at
  verification), so there is nothing to refund.

  Config:

    * `:unverified_prune_after_days` — grace period, default 30. An account
      that verifies at any point is never touched; the window only has to be
      longer than "signed up, verified a while later". `0` disables the sweep.
    * `:unverified_prune_exempt` — substrings; an email containing any of
      them is never pruned, case-insensitively. For operator/test accounts
      that deliberately stay unverified.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Fountain.Accounts.{Deletion, User}
  alias Fountain.Repo

  require Logger

  # Bounds one run; the sweep is daily, so a backlog larger than this drains
  # over a few days rather than making one giant run.
  @batch 100

  @impl Oban.Worker
  def perform(_job) do
    case prune_after_days() do
      0 ->
        :ok

      days ->
        {deleted, skipped} = sweep(days)

        if deleted > 0 or skipped > 0 do
          Logger.info(
            "unverified-account pruner: deleted #{deleted}, skipped #{skipped} " <>
              "(exempt or deletion failed)"
          )
        end

        :ok
    end
  end

  defp sweep(days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)
    exempt = exempt_substrings()

    # Suspended accounts are excluded even when unverified: suspension marks
    # an abuse investigation, and pruning would destroy the evidence (#287).
    User
    |> where(
      [u],
      is_nil(u.email_verified_at) and u.inserted_at < ^cutoff and is_nil(u.suspended_at)
    )
    |> order_by([u], asc: u.inserted_at)
    |> limit(@batch)
    |> Repo.all()
    |> Enum.reduce({0, 0}, fn user, {deleted, skipped} ->
      cond do
        exempt?(user.email, exempt) ->
          {deleted, skipped + 1}

        match?({:ok, _}, Deletion.delete_user(user, actor: "system:unverified_pruner")) ->
          {deleted + 1, skipped}

        true ->
          # delete_user logged the reason; a Stripe refusal aborts before any
          # destruction, so leaving it for the next run is safe.
          {deleted, skipped + 1}
      end
    end)
  end

  defp exempt?(_email, []), do: false

  defp exempt?(email, substrings) do
    downcased = String.downcase(email)
    Enum.any?(substrings, &String.contains?(downcased, String.downcase(&1)))
  end

  defp prune_after_days do
    Application.get_env(:fountain, :unverified_prune_after_days, 30)
  end

  defp exempt_substrings do
    Application.get_env(:fountain, :unverified_prune_exempt, [])
  end
end
