defmodule Fountain.ChatGPTAccounts.RefreshSupervisor do
  @moduledoc false
  use Supervisor

  alias Fountain.ChatGPTAccounts.RefreshCoordinator

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Leave room for the platform refresher and ordinary queries. The user
    # coordinator rejects excess work rather than parking it in the DB pool.
    pool_size = Keyword.get(Fountain.Repo.config(), :pool_size, 10)
    concurrency = min(4, max(1, pool_size - 2))

    children = [
      {Task.Supervisor, name: Fountain.ChatGPTAccounts.RefreshTasks, max_children: concurrency},
      {RefreshCoordinator,
       task_supervisor: Fountain.ChatGPTAccounts.RefreshTasks, max_concurrency: concurrency}
    ]

    # A coordinator restart must kill its old workers before admitting more.
    Supervisor.init(children, strategy: :one_for_all)
  end
end
