defmodule Fountain.RuntimeDispatch do
  @moduledoc """
  Host dispatch for the three packaged runtimes and the one that is Fountain's.

  Only the runtimes `Fountain.Agents.Agent.packaged_runtimes/0` names are
  dispatched, though `Managoat.Runtimes` still ships an `opencode` adapter.
  Fountain removed that runtime in 2026-10; an agent row written before then
  still carries it, and `for_agent/1` refuses it with a message that says what
  to change, rather than running a runtime nothing here supports any more.

  `Fountain.CommandRuntime` is the `acp` runtime (#1634): the agent names a
  command, Fountain launches it inside the sandbox and speaks the protocol to
  it. It is generally available rather than account-restricted, and it is the
  one runtime whose command is not a property of the runtime name, which is
  why `command/2` takes the agent.
  """

  alias Fountain.Agents.Agent
  alias Fountain.CommandRuntime
  alias Managoat.Runtimes
  alias Managoat.Runtimes.ACP
  alias Managoat.Runtimes.Model

  def for_agent(%{runtime: "acp"}), do: {:ok, CommandRuntime}

  def for_agent(%{runtime: runtime}) do
    if runtime in Agent.packaged_runtimes(),
      do: Runtimes.for_runtime(runtime),
      else: {:error, "unsupported runtime: #{runtime}; change the agent's runtime"}
  end

  def acp_enabled?(%{runtime: runtime}), do: acp_enabled?(runtime)
  def acp_enabled?("acp"), do: true
  def acp_enabled?(runtime), do: ACP.enabled?(runtime)

  @doc """
  Argv for the process a turn spawns.

  Takes the agent as well as the runtime because the `acp` runtime's argv is
  the agent's own `runtime_command`. The match is total by the time a spawn
  asks: `Fountain.Conversations.TurnMachine.open/4` refuses a turn whose
  agent has no command, before a turn row exists.
  """
  def command(runtime, agent \\ nil)

  def command("acp", agent) do
    {:ok, argv} = CommandRuntime.argv(agent)
    argv
  end

  def command(runtime, _agent), do: ACP.command(runtime)

  def bootstrap_command(runtime, cmd, args), do: ACP.bootstrap_command(runtime, cmd, args)

  def cwd(runtime), do: ACP.cwd(runtime)

  def concurrency(runtime), do: ACP.concurrency(runtime)

  def install(_handle, "acp", _env), do: :ok
  def install(handle, runtime, env), do: ACP.install(handle, runtime, env)

  @doc """
  The model id to pin on the ACP session, or nil to leave the runtime's own.

  Always nil for `acp`. A model is optional there and nothing reads it, so
  pinning one could only fail. That closes the pin path, which is where the
  `model`/`failed` stage comes from for the runtimes that do drive a model.
  """
  def acp_model("acp", _model), do: nil
  def acp_model(runtime, model), do: Model.acp_model(runtime, model)

  @doc """
  Whether this runtime needs a `model` on the agent.

  Only `acp` does not. Every other runtime is a model driving something, and
  an agent with no model there runs whatever that thing defaults to, which is
  the defect `Agent.changeset/2`'s provider check exists to prevent.
  """
  def model_required?("acp"), do: false
  def model_required?(_runtime), do: true

  @doc """
  Whether this runtime takes a `runtime_command`.

  Only `acp`. On any other runtime the field would be stored, shown in the
  console and never run, which reads as configuration and is not.
  """
  def command_required?("acp"), do: true
  def command_required?(_runtime), do: false
end
