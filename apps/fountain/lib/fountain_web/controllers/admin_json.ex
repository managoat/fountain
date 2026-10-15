defmodule FountainWeb.AdminJSON do
  @moduledoc false

  alias Fountain.Accounts.User
  alias Fountain.Audit.Event
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

  defp user_data(%User{} = u, sandbox_counts) do
    %{
      id: u.id,
      email: u.email,
      role: u.role,
      email_verified: not is_nil(u.email_verified_at),
      email_verified_at: u.email_verified_at,
      active_sandboxes: Map.get(sandbox_counts, u.id, 0),
      last_activity_at: Map.get(u, :last_activity_at),
      inserted_at: u.inserted_at
    }
  end

  # Metadata only, deliberately. An admin
  # can see that a sandbox exists and who owns it, never what ran inside it.
  defp sandbox_data(%Sandbox{} = s) do
    %{
      id: s.id,
      machine_name: s.machine_name,
      # Deprecated duplicate of machine_name, dropped with the Fountain-name
      # aliases (#2776).
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

  # The shape `admin_events` had when it was its own table, kept for clients
  # of GET /api/admin/users/:id: the actor and target are read back from the
  # unified row's `actor` and resource (ADR 0013, 2026-10-15 addendum).
  defp admin_event_data(%Event{} = e) do
    %{
      id: e.id,
      inserted_at: e.inserted_at,
      event_type: e.action,
      actor_user_id: admin_actor_id(e.actor),
      target_user_id: if(e.resource_type == "user", do: e.resource_id),
      metadata: e.metadata
    }
  end

  defp admin_actor_id("admin:" <> id), do: id
  defp admin_actor_id(_actor), do: nil
end
