defmodule Fountain.Conversations.WakePolicyTest do
  # The wake policy for a parked home (ADR 0023, decided 2026-08-24): a
  # prompt to any conversation on the machine wakes it, for that
  # conversation alone. A co-tenant's server comes back on its own first
  # prompt, and that prompt attaches to the machine that is already awake
  # rather than resuming it again.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.Wake

  defp parked_home do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")

    sandbox =
      insert_sandbox(user_id: user.id, machine_name: "test-sprite-home", mode: "persistent")

    {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "suspended"})
    a = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    b = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    %{sandbox: sandbox, a: a, b: b}
  end

  # The wake starts a server through Horde; here only *which* conversation
  # got one matters, so record the child spec and start nothing.
  defp record_server_starts do
    test = self()

    stub_server_start(fn _supervisor, child_spec ->
      send(test, {:server_started, inspect(child_spec)})
      {:ok, spawn(fn -> :ok end)}
    end)
  end

  defp stub_parked_sprite do
    stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
      {:ok, %{status: :suspended, raw: %{name: "test-sprite-home"}}}
    end)

    stub(Managoat.Sandbox.Sprites, :resume, fn handle -> {:ok, handle} end)
  end

  test "a prompt to one conversation wakes the parked home for that conversation alone" do
    %{sandbox: sandbox, a: a, b: b} = parked_home()
    stub_parked_sprite()
    record_server_starts()

    assert {:ok, woken} = Wake.wake_conversation(b.id)
    assert woken.sandbox_id == sandbox.id
    assert Repo.reload(sandbox).status == "ready"

    assert_receive {:server_started, spec}
    assert spec =~ b.id
    refute_receive {:server_started, _}
    assert Repo.reload(a).status == "idle"
  end

  test "a co-tenant's first prompt attaches to the awake machine without a second resume" do
    %{sandbox: sandbox, a: a, b: b} = parked_home()
    stub_parked_sprite()
    record_server_starts()

    assert {:ok, _} = Wake.wake_conversation(b.id)
    assert_receive {:server_started, _}
    assert Repo.reload(sandbox).status == "ready"

    # The machine is up. Waking A must reuse it: no resume, no new row.
    reject(&Managoat.Sandbox.Sprites.resume/1)
    stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:ok, %{status: :running, raw: %{}}} end)

    assert {:ok, woken} = Wake.wake_conversation(a.id)
    assert woken.sandbox_id == sandbox.id
    assert_receive {:server_started, spec}
    assert spec =~ a.id
  end
end
