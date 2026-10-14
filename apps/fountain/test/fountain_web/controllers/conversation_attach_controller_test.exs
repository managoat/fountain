defmodule FountainWeb.ConversationAttachControllerTest do
  # `sandbox_id` on POST /api/conversations (ADR 0023 gate 3), at the door.
  use FountainWeb.ConnCase, async: true
  use Mimic

  import Ecto.Query, only: [from: 2]

  alias Fountain.Repo

  setup do
    user = insert_active_user()
    {_key_record, raw_key} = insert_api_key(user)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        agent_id: agent.id,
        environment_id: env.id
      )

    first = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    {:ok, user: user, raw_key: raw_key, agent: agent, sandbox: sandbox, first: first}
  end

  defp create(ctx, body) do
    ctx.conn
    |> authed_with_key(ctx.raw_key)
    |> post_json("/api/conversations", Map.merge(%{"agent_id" => ctx.agent.id}, body))
  end

  test "attaches: 201, idle, on the named sandbox", ctx do
    data =
      ctx
      |> create(%{"sandbox_id" => ctx.sandbox.id})
      |> json_response(201)
      |> Map.fetch!("data")

    assert data["sandbox_id"] == ctx.sandbox.id
    assert data["status"] == "idle"
    assert data["sandbox"]["agent_id"] == ctx.agent.id
  end

  test "with a prompt, the request's client_request_id goes with it (#1406)", ctx do
    test = self()

    stub(Fountain.Conversations.ConversationServer, :send_prompt, fn _id, "hello", _, opts ->
      send(test, {:prompt_opts, opts})
      :ok
    end)

    ctx
    |> create(%{
      "sandbox_id" => ctx.sandbox.id,
      "prompt" => "hello",
      "client_request_id" => "plan-7-step-1"
    })
    |> json_response(201)

    assert_received {:prompt_opts, opts}
    assert opts[:client_request_id] == "plan-7-step-1"
    # Beside the attribution, not instead of it.
    assert opts[:actor]
  end

  # This door hands the whole merged `params` map to the launch, and the
  # request schema validates the body alone: an id that only ever appeared in
  # the query string was never checked against the bound this field declares.
  # The prompts route reads the body for the same reason (#1406).
  test "an id supplied only in the query string is not read (#1406)", ctx do
    test = self()

    stub(Fountain.Conversations.ConversationServer, :send_prompt, fn _id, "hello", _, opts ->
      send(test, {:prompt_opts, opts})
      :ok
    end)

    # An id that looks perfectly ordinary, so nothing downstream would drop it
    # on its own: if the door read the query string, this would reach the turn.
    ctx.conn
    |> authed_with_key(ctx.raw_key)
    |> post_json("/api/conversations?client_request_id=from-the-query", %{
      "agent_id" => ctx.agent.id,
      "sandbox_id" => ctx.sandbox.id,
      "prompt" => "hello"
    })
    |> json_response(201)

    assert_received {:prompt_opts, opts}
    assert is_nil(opts[:client_request_id])
  end

  test "with a prompt, the first turn goes through the wake path", ctx do
    # A `ready` machine with no server: the prompt probes it and starts a
    # server, exactly as prompting a parked conversation does.
    stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:ok, %{status: :running, raw: %{}}} end)
    stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

    data =
      ctx
      |> create(%{"sandbox_id" => ctx.sandbox.id, "prompt" => "hello"})
      |> json_response(201)
      |> Map.fetch!("data")

    assert data["sandbox_id"] == ctx.sandbox.id
  end

  test "an unknown or foreign sandbox is a 404", ctx do
    foreign = insert_sandbox(user_id: insert_active_user().id, status: "ready")

    for id <- [foreign.id, Ecto.UUID.generate()] do
      assert %{"error" => "sandbox_not_found"} =
               ctx |> create(%{"sandbox_id" => id}) |> json_response(404)
    end
  end

  test "a terminated sandbox is a 409 that names its state", ctx do
    {:ok, _} = update_sandbox(ctx.sandbox, %{status: "terminated"})

    assert %{"error" => "sandbox_not_attachable", "status" => "terminated"} =
             ctx |> create(%{"sandbox_id" => ctx.sandbox.id}) |> json_response(409)
  end

  test "a different identity is a 422", ctx do
    vault = insert_vault(user_id: ctx.user.id)

    assert %{"error" => "sandbox_identity_mismatch"} =
             ctx
             |> create(%{"sandbox_id" => ctx.sandbox.id, "vault_id" => vault.id})
             |> json_response(422)
  end

  # Mixed-runtime guests were removed (#2676): another agent never attaches,
  # whatever its runtime or the caller's scope.
  test "another agent's conversation is a 422, of any runtime", ctx do
    for runtime <- ["claude", "codex"] do
      other =
        insert_agent(
          user_id: ctx.user.id,
          runtime: runtime,
          environment_id: ctx.agent.environment_id
        )

      assert %{"error" => "sandbox_identity_mismatch"} =
               ctx
               |> create(%{"agent_id" => other.id, "sandbox_id" => ctx.sandbox.id})
               |> json_response(422)
    end
  end

  test "sandbox_mode=persistent lands every launch of an identity on one home", ctx do
    stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

    first =
      ctx
      |> create(%{"sandbox_mode" => "persistent"})
      |> json_response(201)
      |> Map.fetch!("data")

    assert first["sandbox"]["mode"] == "persistent"

    # Still provisioning: a second launch is told to retry, not given a
    # second machine.
    assert %{"error" => "provisioning"} =
             ctx |> create(%{"sandbox_mode" => "persistent"}) |> json_response(503)

    {:ok, _} =
      update_sandbox(
        Fountain.Conversations._unsafe_get_sandbox!(first["sandbox_id"]),
        %{status: "ready"}
      )

    second =
      ctx
      |> create(%{"sandbox_mode" => "persistent"})
      |> json_response(201)
      |> Map.fetch!("data")

    assert second["sandbox_id"] == first["sandbox_id"]
    assert second["status"] == "idle"

    # Refused at the door — the spec's enum, before the context sees it.
    assert ctx |> create(%{"sandbox_mode" => "sometimes"}) |> json_response(422)
  end

  test "a one-at-a-time runtime at capacity is a 409 when a prompt comes with it", ctx do
    agent = ctx.agent |> Ecto.Changeset.change(runtime: "gemini") |> Fountain.Repo.update!()
    {:ok, _} = Fountain.Conversations.update_conversation(ctx.first, %{runtime: "gemini"})

    insert_turn(ctx.first, %{
      status: "running",
      prompt: "busy",
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    ctx = %{ctx | agent: agent}

    assert %{"error" => "sandbox_at_capacity"} =
             ctx
             |> create(%{"sandbox_id" => ctx.sandbox.id, "prompt" => "hello"})
             |> json_response(409)

    # Nothing was created by the refusal.
    assert length(Fountain.Conversations.list_conversations(ctx.user.id)) == 1
  end

  test "attachment audits its own creation and leaves the first conversation alone", ctx do
    data =
      ctx |> create(%{"sandbox_id" => ctx.sandbox.id}) |> json_response(201) |> Map.fetch!("data")

    assert Repo.reload!(ctx.first).status == "idle"
    assert Repo.reload!(ctx.sandbox).status == "ready"
    assert [_event] = Enum.filter(creation_events(ctx.user.id), &(&1.resource_id == data["id"]))
  end

  defp creation_events(user_id) do
    Repo.all(
      from e in Fountain.Audit.Event,
        where:
          e.user_id == ^user_id and
            e.action == "conversation.created"
    )
  end
end
