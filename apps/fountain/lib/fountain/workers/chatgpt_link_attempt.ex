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

  Unique per attempt while a job for it is incomplete, so a retried insert
  cannot start a second poller against one device code.
  """

  use Oban.Worker,
    queue: :chatgpt,
    max_attempts: 5,
    unique: [keys: [:attempt_id], period: :infinity, states: :incomplete]

  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.LinkAttempt

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
end
