defmodule Fountain.Workers.ChatGPTKeepaliveSweep do
  @moduledoc """
  Schedules idle user grants in pages of at most 100 (ADR 0052).

  Each page transaction inserts per-grant jobs and its continuation together.
  Replayed pages reuse incomplete jobs. Jobs carry only owner/grant/generation
  IDs and receive up to five minutes of jitter; this sweep does no decryption
  or provider I/O. The daily run starts from the beginning so grants inserted
  behind a running cursor are picked up on the next sweep.

  The six-day default comes from the existing platform setting and remains
  provisional until the provider's idle-lifetime measurement is completed.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  alias Fountain.ChatGPTAccounts
  alias Fountain.Repo
  alias Fountain.Workers.ChatGPTGrantKeepalive

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, cursor} <- cursor(args) do
      grants = ChatGPTAccounts._unsafe_due_user_grants(cursor, @batch_size)

      case Repo.transaction(fn -> enqueue_page(grants) end) do
        {:ok, :ok} -> :ok
        {:error, _} -> {:error, :enqueue_failed}
      end
    end
  end

  defp enqueue_page(grants) do
    for grant <- grants do
      grant
      |> ChatGPTGrantKeepalive.new(schedule_in: :rand.uniform(300))
      |> insert!()
    end

    if length(grants) == @batch_size do
      %{after_id: List.last(grants).grant_id}
      |> new(schedule_in: 1)
      |> insert!()
    end

    :ok
  end

  # Oban.insert_all does not enforce job uniqueness. Use the unique insertion
  # path, with a fixed bound on both queries and writes in this transaction.
  defp insert!(changeset) do
    case Oban.insert(changeset) do
      {:ok, %Oban.Job{id: id} = job} when is_integer(id) -> job
      # A contended Oban uniqueness lock can return an unsaved conflict job
      # with no ID. Do not advance a page on an insertion that isn't durable.
      _ -> Repo.rollback(:enqueue_failed)
    end
  end

  defp cursor(args) when map_size(args) == 0, do: {:ok, nil}

  defp cursor(%{"after_id" => id} = args) when map_size(args) == 1 do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:cancel, :invalid_args}
    end
  end

  defp cursor(_), do: {:cancel, :invalid_args}
end
