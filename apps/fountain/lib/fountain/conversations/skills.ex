defmodule Fountain.Conversations.Skills do
  @moduledoc """
  The skills a conversation's machine carries, kept in step with its agent.

  A fresh provision mounts them (`Fountain.SandboxSkills.mount_fresh/3`). A
  wake reconciles them with `mount/3`, because the agent's skill selection can
  change while its conversation sleeps: a skill the agent no longer names is
  removed, and a new one is installed. The record of what the disk carries is
  the machine's `applied_skills_by_runtime`, written through its owner
  (`Fountain.Machines.Machine.record_skills/3`).
  """

  import Ecto.Query

  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Machine
  alias Fountain.{Conversations, Repo}

  @doc """
  Reconcile the machine's skills with the conversation's current selection,
  then record what is now on it.

  Both halves are the conversation's own runtime's: its skills root on the
  disk, and its entry in `applied_skills_by_runtime`. Another runtime sharing
  the machine keeps its root and its record (#2514).

  Run on every wake. A machine built before the manifest existed gets one on
  its first pass. The recorded set is only advanced when the reconciliation
  succeeded, so a failed pass leaves the next one the same work rather than a
  wrong picture of the disk.
  """
  @spec mount(Managoat.Sandbox.Handle.t(), map(), map() | nil) :: :ok | {:error, term()}
  def mount(handle, conv, agent) do
    # ownership: conv came from the tenant-scoped API fetch or its own server.
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    skills = (agent && agent.skills) || []
    runtime = runtime(conv, agent)

    with :ok <-
           Fountain.SandboxSkills.reconcile(
             handle,
             runtime,
             skills,
             Sandbox.applied_skills(sandbox, runtime) || previous_skills(conv)
           ),
         {:ok, _} <- Machine.record_skills(sandbox.id, runtime, skills) do
      :ok
    end
  end

  @doc """
  The skills the conversation's recorded Agent version named.

  The seed for a disk that predates the manifest: it is the selection that
  was installed when the machine was built, so it is the best available
  answer to "which entries under the skills root are ours". Missing history
  returns `nil`, not an empty selection: absence cannot establish ownership.
  """
  @spec previous_skills(map()) :: [map()] | nil
  def previous_skills(%{agent_version_id: nil}), do: nil

  def previous_skills(conv) do
    # The conversation's own version; ownership was checked at the API door.
    case Repo.one(
           from v in Fountain.Agents.AgentVersion,
             where: v.id == ^conv.agent_version_id and v.user_id == ^conv.user_id
         ) do
      nil -> nil
      version -> version.config["skills"] || []
    end
  end

  # The runtime whose skills root, and whose record, a conversation's skills
  # are: its own, which is validated-required and outlives its agent.
  defp runtime(conv, agent), do: conv.runtime || (agent && agent.runtime) || "claude"
end
