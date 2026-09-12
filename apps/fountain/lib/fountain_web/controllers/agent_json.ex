defmodule FountainWeb.AgentJSON do
  @moduledoc false
  alias Fountain.Agents.Agent

  def index(%{agents: agents}), do: %{data: Enum.map(agents, &data/1)}
  def show(%{agent: agent}), do: %{data: data(agent)}

  def data(%Agent{} = a) do
    %{
      id: a.id,
      name: a.name,
      description: a.description,
      system: a.system,
      model: a.model,
      runtime: a.runtime,
      # The command the acp runtime launches, and null on every other one
      # (#1634).
      runtime_command: a.runtime_command,
      # Derived, never stored: whether this agent's runtime speaks ACP, and so
      # whether a client outside the server can render its output as protocol
      # rather than as one of the four proprietary dialects. `fountain acp`
      # asks this before it opens a session (#702) — the alternative was a
      # hardcoded runtime list in the Go CLI, which would go stale the day a
      # held-back runtime is converted.
      acp: Fountain.RuntimeDispatch.acp_enabled?(a.runtime),
      sandbox_provider: a.sandbox_provider,
      sandbox_mode: a.sandbox_mode,
      environment_id: a.environment_id,
      skills: a.skills,
      mcp_servers: a.mcp_servers,
      metadata: a.metadata,
      allowed_vault_ids: a.allowed_vault_ids,
      allowed_environment_ids: a.allowed_environment_ids,
      inference_credential_id: a.inference_credential_id,
      allowed_inference_credential_ids: a.allowed_inference_credential_ids,
      permission_policy: a.permission_policy,
      conversation_count: a.conversation_count,
      avatar_media_type: a.avatar_media_type,
      inserted_at: a.inserted_at,
      updated_at: a.updated_at
    }
  end
end
