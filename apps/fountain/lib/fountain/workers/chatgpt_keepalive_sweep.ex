defmodule Fountain.Workers.ChatGPTKeepaliveSweep do
  @moduledoc """
  The daily keepalive for users' ChatGPT grants (ADR 0060 decision 5, stage
  5): queues one `Fountain.Workers.ChatGPTGrantKeepalive` for every grant
  nobody has renewed for `ChatGPTAccounts.platform_keepalive_days/0`, so a
  subscription its owner has not used for a week does not lapse at the auth
  server's idle window. It closes the gap stage 1 recorded.

  It reads ids and writes jobs. It decrypts nothing, loads no key and calls
  no provider. The scan is `ChatGPTAccounts._unsafe_due_user_grants/2`, in
  keyset pages of at most a hundred; a page's jobs and its continuation are
  inserted in one transaction, and a replayed page finds its jobs already
  there. Each daily run starts from the beginning, so a grant linked behind
  a running cursor is picked up the next day, a day inside the margin.

  **The rate toward `auth.openai.com`.** Every renewal leaves from this
  server's address, so the jobs are spread rather than sent at once: each is
  scheduled at a uniformly random second of a window sized from how many
  grants are due, `due x 5 s`, no shorter than five minutes and no longer
  than six hours. That is about one request every five seconds however many
  grants there are, until the cap; past 4,320 due grants the rate rises with
  the count, and the queue's two slots per node are what bound it then. The
  count is read once, by the first page, and carried to the continuations
  so every page spreads over the same window. `:chatgpt_keepalive_spacing_ms`
  is the five seconds (application config; no environment variable).

  The six days are the platform grant's, and provisional with them: ADR
  0047's measurement 5, the auth server's real idle lifetime, is not
  recorded yet.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  alias Fountain.ChatGPTAccounts
  alias Fountain.Repo
  alias Fountain.Workers.ChatGPTGrantKeepalive

  @batch_size 100
  @min_window_seconds 300
  @max_window_seconds 6 * 60 * 60

  # A retry is a replay of one page; nothing here snoozes, and three attempts
  # never reach a long wait. Bounded anyway, as its jobs' is.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(600, 30 * max(attempt, 1))

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, cursor, due} <- page(args) do
      # ownership: none is claimed. A system sweep across every tenant, which
      # reads ids only; each job re-reads its grant scoped by the owner.
      grants = ChatGPTAccounts._unsafe_due_user_grants(cursor, @batch_size)

      case Repo.transaction(fn -> enqueue_page(grants, due) end) do
        {:ok, :ok} -> :ok
        {:error, _} -> {:error, :enqueue_failed}
      end
    end
  end

  @doc """
  The seconds a sweep of `due` grants spreads its jobs over:
  `min(6 h, max(300 s, due x spacing))`.
  """
  @spec window_seconds(non_neg_integer()) :: pos_integer()
  def window_seconds(due) when is_integer(due) and due >= 0 do
    spacing_ms = Application.get_env(:fountain, :chatgpt_keepalive_spacing_ms, 5_000)

    (due * spacing_ms)
    |> div(1000)
    |> max(@min_window_seconds)
    |> min(@max_window_seconds)
  end

  defp enqueue_page(grants, due) do
    window = window_seconds(due)

    for grant <- grants do
      grant
      |> ChatGPTGrantKeepalive.new(schedule_in: :rand.uniform(window))
      |> insert!()
    end

    if length(grants) == @batch_size do
      %{after_id: List.last(grants).grant_id, due: due}
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

  # The first page, which the cron inserts with no args, counts what is due
  # and says so once; a continuation carries that count and its cursor.
  defp page(args) when map_size(args) == 0 do
    # ownership: none is claimed; a count across every tenant, for the jitter.
    due = ChatGPTAccounts._unsafe_due_user_grant_count()
    :telemetry.execute([:fountain, :chatgpt, :keepalive, :sweep], %{due: due}, %{})
    {:ok, nil, due}
  end

  defp page(%{"after_id" => id, "due" => due} = args)
       when map_size(args) == 2 and is_integer(due) and due >= 0 do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id, due}
      :error -> {:cancel, :invalid_args}
    end
  end

  defp page(_), do: {:cancel, :invalid_args}
end
