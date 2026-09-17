defmodule Fountain.Test.ConversationMessagePeer do
  @moduledoc false
  use GenServer

  alias Fountain.Conversations
  alias Fountain.Conversations.{ConversationServer, ExecutionGuard, Lifecycle, Termination}

  # Runs only in disposable peer VMs. The real client and receiver communicate
  # over distribution; the database fence is the observation point, so this
  # contract test requires no provider or shared SQL Sandbox connection.
  def receiver do
    GenServer.start(__MODULE__, %{conversation_id: "conversation", sandbox_id: "sandbox"})
  end

  def caller(actor) do
    GenServer.start(__MODULE__, {:caller, actor})
  end

  def request_termination(caller, opts) do
    GenServer.call(caller, {:request_termination, opts})
  end

  def fence, do: :persistent_term.get({__MODULE__, :fence})

  defp start_mimic(modules) do
    ExUnit.start(autorun: false)
    {:ok, _} = Application.ensure_all_started(:mimic)
    Enum.each(modules, &Mimic.copy/1)
    Mimic.set_mimic_global()
  end

  @impl true
  def init({:caller, actor}) do
    start_mimic([Fountain.Repo, ExecutionGuard, Horde.Registry])
    Mimic.stub(Fountain.Repo, :in_transaction?, fn -> false end)
    Mimic.stub(ExecutionGuard, :_unsafe_interrupt, fn "conversation" -> {:ok, :unbounded} end)

    Mimic.stub(Horde.Registry, :lookup, fn Fountain.ConversationRegistry, "conversation" ->
      [{actor, nil}]
    end)

    {:ok, :caller}
  end

  # The receiver's terminate goes through `Machine.detach/2` since ADR 0058
  # stage 8b, which reads the row as a `%Sandbox{}` and asks the repo whether a
  # transaction is open before it reaches the fence; both are stubbed here as
  # the caller's side already stubs its own repo question.
  def init(state) do
    start_mimic([Conversations, Lifecycle, Fountain.Repo])
    Mimic.stub(Fountain.Repo, :in_transaction?, fn -> false end)

    Mimic.stub(Conversations, :_unsafe_get_sandbox, fn id ->
      %Fountain.Conversations.Sandbox{id: id, status: "ready"}
    end)

    # `put` is last-write-wins, so this records WHAT reached the fence and not
    # HOW MANY times: a duplicate fence call is invisible here, and the
    # assertions on this term are about the arguments only (round 1, behaviour
    # review). Counting belongs in a test with a draining receiver.
    Mimic.stub(Lifecycle, :fence_sandbox_for_teardown, fn sandbox, opts ->
      :persistent_term.put({__MODULE__, :fence}, {sandbox.id, opts})
      {:error, :sandbox_unavailable}
    end)

    {:ok, state}
  end

  @impl true
  def handle_call({:request_termination, opts}, _from, :caller) do
    {:reply, Termination.terminate_conversation("conversation", opts), :caller}
  end

  def handle_call(message, from, state),
    do: ConversationServer.handle_call(message, from, state)
end
