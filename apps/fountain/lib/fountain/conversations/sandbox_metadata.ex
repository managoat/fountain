defmodule Fountain.Conversations.SandboxMetadata do
  @moduledoc """
  Operator inventory for the legacy sandbox metadata rollout (#2102).

  Database presence is evidence about recorded metadata, not about the disk.
  In particular, `applied_skills_by_runtime` does not prove a managed skill
  manifest is still present. `applied_skills_recorded` means a record exists
  for at least one runtime. This inventory does not inspect or wake provider machines.
  """

  import Ecto.Query

  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo

  @doc "Read-only cross-tenant inventory for release tasks and system operators."
  @spec _unsafe_inventory() :: map()
  def _unsafe_inventory do
    sandboxes =
      Repo.all(
        from s in Sandbox,
          where: s.status != "terminated",
          order_by: [asc: s.id],
          select: %{
            sandbox_id: s.id,
            user_id: s.user_id,
            status: s.status,
            provider: s.provider,
            mode: s.mode,
            build_fingerprint_recorded: not is_nil(s.build_fingerprint),
            applied_skills_recorded: not is_nil(s.applied_skills_by_runtime)
          }
      )

    %{
      disk_skill_manifests: :unverified,
      counts: %{
        retained: length(sandboxes),
        missing_build_fingerprint: Enum.count(sandboxes, &(not &1.build_fingerprint_recorded)),
        missing_applied_skills: Enum.count(sandboxes, &(not &1.applied_skills_recorded))
      },
      sandboxes: sandboxes
    }
  end
end
