defmodule FountainWeb.AdminJSON do
  @moduledoc false

  alias Fountain.Accounts.User
  alias Fountain.Audit.{AdminEvent, Event}
  alias Fountain.Conversations.Sandbox

  def index_users(%{
        users: users,
        sandbox_counts: counts,
        page: page,
        per_page: per_page,
        total: total
      }) do
    %{
      data: Enum.map(users, &user_data(&1, counts)),
      meta: %{page: page, per_page: per_page, total: total}
    }
  end

  def show_user(%{user: user, sandbox_counts: counts, admin_events: events}) do
    %{
      data:
        user
        |> user_data(counts)
        |> Map.put(:admin_events, Enum.map(events, &admin_event_data/1))
    }
  end

  def create_user(%{user: user, sandbox_counts: counts, api_key: raw}),
    do: %{data: user_data(user, counts), api_key: raw}

  def index_sandboxes(%{sandboxes: sandboxes}),
    do: %{data: Enum.map(sandboxes, &sandbox_data/1)}

  def index_audit(%{events: events}), do: %{data: Enum.map(events, &audit_event_data/1)}

  def index_admin_events(%{events: events}), do: %{data: Enum.map(events, &admin_event_data/1)}

  defp user_data(%User{} = u, sandbox_counts) do
    %{
      id: u.id,
      email: u.email,
      role: u.role,
      email_verified: not is_nil(u.email_verified_at),
      email_verified_at: u.email_verified_at,
      suspended: not is_nil(u.suspended_at),
      suspended_at: u.suspended_at,
      # The cap actually enforced, keeping the field's old name and meaning
      # for anything reading this API, plus the override that produced it —
      # null when the cap is simply the configured ceiling.
      max_concurrent_sandboxes: Fountain.Quotas.sandbox_limit_for(u),
      sandbox_limit_override: u.sandbox_limit_override,
      active_sandboxes: Map.get(sandbox_counts, u.id, 0),
      last_activity_at: Map.get(u, :last_activity_at),
      inserted_at: u.inserted_at
    }
  end

  # Metadata only, deliberately — the ConversationDetail principle. An admin
  # can see that a sandbox exists and who owns it, never what ran inside it.
  defp sandbox_data(%Sandbox{} = s) do
    %{
      id: s.id,
      sprite_name: s.machine_name,
      provider: s.provider,
      status: s.status,
      user_id: s.user_id,
      user_email: s.user && s.user.email,
      conversation_count: length(s.conversations || []),
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end

  defp audit_event_data(%Event{} = e) do
    %{
      id: e.id,
      inserted_at: e.inserted_at,
      user_id: e.user_id,
      actor: e.actor,
      action: e.action,
      resource_type: e.resource_type,
      resource_id: e.resource_id,
      metadata: e.metadata,
      request_ip: e.request_ip
    }
  end

  defp admin_event_data(%AdminEvent{} = e) do
    %{
      id: e.id,
      inserted_at: e.inserted_at,
      event_type: e.event_type,
      actor_user_id: e.actor_user_id,
      target_user_id: e.target_user_id,
      metadata: e.metadata
    }
  end
end
