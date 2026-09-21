defmodule Fountain.Workers.ChatGPTLinkAttempt do
  @moduledoc """
  Drives one ChatGPT link attempt (ADR 0060 decision 3, stage 4): each run is
  one `Fountain.ChatGPTAccounts.poll_attempt_for_user/3`, and a run that
  leaves the attempt pending snoozes for as long as that asked, which is the
  auth server's own interval or its backoff. The job is inserted in the
  transaction that inserts the attempt, scheduled one interval out: nobody
  approves a code sooner than that.

  The args are the attempt's id and its owner's, and nothing else (0052
  decision 2, "jobs carry ids, never tokens"). The owner's id is there so the
  first read is scoped by it. Everything the auth server said stays inside
  the context's call.

  No process holds an attempt, so nothing here is lost with a node: a run
  that dies is retried by Oban and asks the row where things stand. An
  attempt that is gone, cancelled, finished or past its time is `:ok` without
  a request to anybody, and its fifteen minutes bound how long the job can
  keep snoozing. A snooze does not spend one of `max_attempts`; those are for
  a run that raised.

  A snooze does raise the job's `attempt`, though, and Oban's default backoff
  grows with it: after a few minutes of snoozing, one exception would put the
  retry past the attempt's fifteen minutes, and after an hour's worth, days
  out. So `backoff/1` is a constant. A run that raises is asked again in ten
  seconds however long the job has been polling, ten times, and the row's
  own `expires_at` is what stops it.

  Unique per attempt while a job for it is incomplete, so a retried insert
  cannot start a second poller against one device code.

  A job can still be lost: discarded after its last raise, or deleted by an
  operator. `ensure_enqueued/1` is what the attempt's readers call for a
  pending attempt in time, and it inserts the job again when no incomplete
  one names the attempt. A job orphaned in `executing` by a killed node is
  incomplete, so this does not replace it, and `Oban.Plugins.Lifeline`
  rescues it only after the attempt has run out (ADR 0060, "Stage 4a as
  built", known limitations).
  """

  use Oban.Worker,
    queue: :chatgpt,
    max_attempts: 10,
    unique: [keys: [:attempt_id], period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.LinkAttempt
  alias Fountain.Repo

  @retry_seconds 10

  @impl Oban.Worker
  def backoff(%Oban.Job{}), do: @retry_seconds

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attempt_id" => attempt_id, "user_id" => user_id}}) do
    case ChatGPTAccounts.poll_attempt_for_user(attempt_id, user_id) do
      :done -> :ok
      {:again, seconds} -> {:snooze, seconds}
    end
  end

  @doc "Enqueue the poller for `attempt`, first run one poll interval from now."
  @spec enqueue(LinkAttempt.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%LinkAttempt{id: id, user_id: user_id, poll_interval: interval}) do
    %{attempt_id: id, user_id: user_id}
    |> new(schedule_in: interval)
    |> Oban.insert()
  end

  @doc """
  Put `attempt`'s poller back if it has none. One indexed read when it has
  one, which is every time but the rare one; the insert is the unique one, so
  two readers that both find nothing still start one poller.
  """
  @spec ensure_enqueued(LinkAttempt.t()) :: :ok
  def ensure_enqueued(%LinkAttempt{id: id} = attempt) do
    states = Enum.map(Oban.Job.unique_states(:incomplete), &Atom.to_string/1)

    polled? =
      Repo.exists?(
        from(j in Oban.Job,
          where: j.worker == ^inspect(__MODULE__) and j.state in ^states,
          where: fragment("? @> ?", j.args, ^%{"attempt_id" => id})
        )
      )

    unless polled?, do: enqueue(attempt)
    :ok
  end
end
