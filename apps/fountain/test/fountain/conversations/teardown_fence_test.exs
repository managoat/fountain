defmodule Fountain.Conversations.TeardownFenceTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Audit, Conversations}

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)

    home =
      insert_sandbox(user_id: user.id, agent_id: agent.id, mode: "persistent", status: "ready")

    %{user: user, agent: agent, home: home}
  end

  test "records the first fence after commit with caller attribution", ctx do
    reject(Managoat.Sandbox.Sprites, :destroy, 1)

    expect(Audit, :record, fn attrs ->
      refute Repo.in_transaction?()
      assert Repo.reload!(ctx.home).reset_requested_at
      Mimic.call_original(Audit, :record, [attrs])
    end)

    assert {:ok, fenced} =
             Conversations._unsafe_fence_sandbox_for_teardown(ctx.home,
               actor: "ui",
               request_ip: "192.0.2.1",
               reason: "agent_deleted"
             )

    assert fenced.status == "ready"
    assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 1
    assert [event] = events(ctx)
    assert event.actor == "ui"
    assert event.request_ip == "192.0.2.1"
    assert event.resource_type == "sandbox"
    assert event.resource_id == ctx.home.id
    assert event.metadata == %{"reason" => "agent_deleted", "provider" => ctx.home.provider}

    assert {:ok, repeated} = Conversations._unsafe_fence_sandbox_for_teardown(ctx.home)
    assert repeated.reset_requested_at == fenced.reset_requested_at
    assert [^event] = events(ctx)
  end

  for status <- ["terminated", "failed"] do
    test "a #{status} sandbox needs no new fence or request event", ctx do
      ctx.home |> Ecto.Changeset.change(status: unquote(status)) |> Repo.update!()
      reject(Audit, :record, 1)
      reject(Managoat.Sandbox.Sprites, :destroy, 1)

      assert {:ok, retired} = Conversations._unsafe_fence_sandbox_for_teardown(ctx.home)
      assert retired.status == unquote(status)
      refute retired.reset_requested_at
      assert events(ctx) == []
    end
  end

  test "an existing reset fence keeps its timestamp without another request event", ctx do
    requested_at = DateTime.add(DateTime.utc_now(), -60)
    ctx.home |> Ecto.Changeset.change(reset_requested_at: requested_at) |> Repo.update!()
    reject(Audit, :record, 1)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)

    assert {:ok, fenced} = Conversations._unsafe_fence_sandbox_for_teardown(ctx.home)
    assert fenced.reset_requested_at == requested_at
    assert events(ctx) == []
  end

  test "a missing sandbox returns an error without an audit or provider call", ctx do
    Repo.delete!(ctx.home)
    reject(Audit, :record, 1)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    assert {:error, :not_found} = Conversations._unsafe_fence_sandbox_for_teardown(ctx.home)
    assert events(ctx) == []
  end

  test "an enclosing transaction cannot create a fence or audit event", ctx do
    reject(Audit, :record, 1)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)

    assert {:ok, {:error, :provider_transaction_open}} =
             Repo.transaction(fn ->
               Conversations._unsafe_fence_sandbox_for_teardown(ctx.home)
             end)

    refute Repo.reload!(ctx.home).reset_requested_at
    assert events(ctx) == []
  end

  test "agent deletion forwards attribution to its home teardown request", ctx do
    expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> :ok end)
    assert {:ok, _} = Agents.delete_agent(ctx.agent, actor: "ui", request_ip: "192.0.2.2")
    assert [event] = events(ctx)
    assert event.actor == "ui"
    assert event.request_ip == "192.0.2.2"
    assert event.metadata["reason"] == "agent_deleted"
  end

  defp events(ctx) do
    Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.teardown_requested")
  end
end
