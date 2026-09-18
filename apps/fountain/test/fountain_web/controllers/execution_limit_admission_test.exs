defmodule FountainWeb.ExecutionLimitAdmissionTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Ecto.Query, only: [from: 2]

  alias Fountain.{Conversations, Repo}
  alias Fountain.Accounts.User
  alias Fountain.Conversations.{Conversation, ExecutionAllowance, Sandbox}
  alias Fountain.Conversations.Launch

  setup do
    previous = Application.fetch_env(:fountain, :execution_limit_ceiling)
    Application.put_env(:fountain, :execution_limit_ceiling, %{})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fountain, :execution_limit_ceiling, value)
        :error -> Application.delete_env(:fountain, :execution_limit_ceiling)
      end
    end)

    user = insert_active_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 20)
    {_key, raw_key} = insert_api_key(user)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        environment_id: env.id,
        status: "ready"
      )

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: "idle",
        channel_id: "limits"
      )

    owner = self()

    stub_server_start(fn _, _ ->
      send(owner, :worker_started)
      {:ok, spawn(fn -> :ok end)}
    end)

    {:ok, user: user, raw_key: raw_key, agent: agent, sandbox: sandbox, conv: conv}
  end

  for path <- [:fresh, :attach, :resume, :rotate] do
    test "#{path} refuses unenforced limits before changing state", ctx do
      before_counts = counts()
      attrs = Map.put(attrs(ctx, unquote(path)), "execution_limits", %{"wall_time_seconds" => 60})
      response = request(ctx, attrs) |> json_response(422)
      assert response["error"] == "execution_limits_unsupported"
      assert response["message"] =~ "wall_time_seconds"
      assert counts() == before_counts
      assert Repo.reload!(ctx.conv).channel_id == "limits"
      refute_received :worker_started
    end
  end

  test "all allowlisted controls are refused until enforcement is integrated", ctx do
    for field <- Conversations.ExecutionLimits.keys() do
      params = Map.put(attrs(ctx, :fresh), "execution_limits", %{field => 1})

      assert %{"error" => "execution_limits_unsupported"} =
               request(ctx, params) |> json_response(422)
    end

    refute_received :worker_started
  end

  test "invalid limits fail with a stable error without echoing input", ctx do
    before_counts = counts()

    for limits <- [
          %{"secret" => "do-not-echo"},
          %{"wall_time_seconds" => "60"},
          %{"max_model_turns" => nil},
          []
        ] do
      params = Map.put(attrs(ctx, :fresh), "execution_limits", limits)
      response = request(ctx, params) |> json_response(422)
      assert response["error"] == "execution_limits_invalid"
      refute Jason.encode!(response) =~ "do-not-echo"
    end

    assert counts() == before_counts
    refute_received :worker_started
  end

  test "direct context callers cannot bypass fresh or attach admission", ctx do
    before_counts = counts()

    for path <- [:fresh, :attach] do
      params =
        attrs(ctx, path)
        |> Map.put("user_id", ctx.user.id)
        |> Map.put("execution_limits", %{max_model_turns: 1})

      assert {:error, {:execution_limits_unsupported, ["max_model_turns"]}} =
               Launch.start_conversation(params)
    end

    assert counts() == before_counts
    refute_received :worker_started
  end

  test "omitted and empty limits preserve ordinary admission", ctx do
    for limits <- [:omitted, nil, %{}], path <- [:fresh, :attach, :resume] do
      params = attrs(ctx, path)

      params =
        if limits == :omitted, do: params, else: Map.put(params, "execution_limits", limits)

      status = if path == :resume, do: 200, else: 201
      assert %{"data" => _} = request(ctx, params) |> json_response(status)
    end
  end

  test "a foreign agent remains hidden before limit validation", ctx do
    foreign = insert_agent(user_id: insert_active_user().id)
    params = %{"agent_id" => foreign.id, "execution_limits" => %{"max_model_turns" => 1}}
    assert %{"error" => "not_found"} = request(ctx, params) |> json_response(404)
    refute_received :worker_started
  end

  for path <- [:fresh, :attach, :resume, :rotate] do
    test "#{path} inherits the stored account ceiling even when the request omits it", ctx do
      save_ceiling(ctx.user, %{max_model_turns: 2})
      before_counts = counts()

      for request_limit <- [:omitted, nil, %{}] do
        params = Map.put(attrs(ctx, unquote(path)), "account_execution_limits", %{})

        params =
          if request_limit == :omitted,
            do: params,
            else: Map.put(params, "execution_limits", request_limit)

        assert %{"error" => "execution_limits_unsupported", "message" => message} =
                 request(ctx, params) |> json_response(422)

        assert message =~ "max_model_turns"
        assert counts() == before_counts
        assert Repo.reload!(ctx.conv).channel_id == "limits"
        refute_received :worker_started
      end
    end
  end

  test "every configured account control is inherited", ctx do
    for field <- Conversations.ExecutionLimits.keys() do
      save_ceiling(ctx.user, %{field => 1})

      assert %{"error" => "execution_limits_unsupported", "message" => message} =
               request(ctx, attrs(ctx, :fresh)) |> json_response(422)

      assert message =~ field
    end

    refute_received :worker_started
  end

  test "account ceilings are reread on each resume", ctx do
    assert request(ctx, attrs(ctx, :resume)) |> json_response(200)
    save_ceiling(ctx.user, %{wall_time_seconds: 30})

    assert %{"error" => "execution_limits_unsupported"} =
             request(ctx, attrs(ctx, :resume)) |> json_response(422)

    save_ceiling(ctx.user, nil)
    assert request(ctx, attrs(ctx, :resume)) |> json_response(200)
  end

  test "wider requests are rejected before runtime capability checks", ctx do
    save_ceiling(ctx.user, %{max_model_turns: 2})
    params = Map.put(attrs(ctx, :fresh), "execution_limits", %{"max_model_turns" => 3})

    assert %{
             "error" => "execution_limits_widen",
             "errors" => %{"execution_limits" => ["cannot widen max_model_turns"]}
           } =
             request(ctx, params) |> json_response(422)

    refute_received :worker_started
  end

  test "malformed account policy fails without exposing its contents", ctx do
    corrupt =
      ctx.user
      |> Ecto.Changeset.change(execution_limits: %{"private-field" => "private-value"})
      |> Repo.update!()
      |> Repo.reload!()

    response = request(ctx, attrs(ctx, :fresh)) |> json_response(422)
    assert response["error"] == "execution_limits_invalid"
    refute Jason.encode!(response) =~ "private-value"
    refute Jason.encode!(response) =~ "private-field"
    assert Repo.reload!(corrupt) == corrupt
    refute_received :worker_started
  end

  test "another account's ceiling is neither inherited nor disclosed", ctx do
    other = insert_active_user() |> save_ceiling(%{wall_time_seconds: 30})
    assert request(ctx, attrs(ctx, :fresh)) |> json_response(201)
    assert_received :worker_started

    save_ceiling(ctx.user, %{max_model_turns: 2})
    foreign = insert_agent(user_id: other.id)
    params = %{"agent_id" => foreign.id}
    assert %{"error" => "not_found"} = request(ctx, params) |> json_response(404)
    refute_received :worker_started
  end

  for path <- [:fresh, :attach, :resume, :rotate] do
    test "#{path} inherits host controls before any launch effects", ctx do
      Application.put_env(:fountain, :execution_limit_ceiling, %{"wall_time_seconds" => 30})
      before_counts = counts()

      for limit <- [:omitted, nil, %{}] do
        params = Map.put(attrs(ctx, unquote(path)), "execution_limit_ceiling", %{})

        params =
          if limit == :omitted, do: params, else: Map.put(params, "execution_limits", limit)

        assert %{"error" => "execution_limits_unsupported", "message" => message} =
                 request(ctx, params) |> json_response(422)

        assert message =~ "wall_time_seconds"
        assert counts() == before_counts
        assert Repo.reload!(ctx.conv).channel_id == "limits"
        refute_received :worker_started
      end
    end
  end

  test "launch requests cannot widen the stricter host or account ceiling", ctx do
    for {host, account} <- [{2, 10}, {10, 2}] do
      Application.put_env(:fountain, :execution_limit_ceiling, %{"max_model_turns" => host})
      save_ceiling(ctx.user, %{max_model_turns: account})
      params = Map.put(attrs(ctx, :fresh), "execution_limits", %{"max_model_turns" => 3})
      assert %{"error" => "execution_limits_widen"} = request(ctx, params) |> json_response(422)
    end

    refute_received :worker_started
  end

  test "host and account controls are both inherited", ctx do
    Application.put_env(:fountain, :execution_limit_ceiling, %{"max_estimated_cost_usd" => 0.25})
    save_ceiling(ctx.user, %{max_model_turns: 2})

    assert %{"error" => "execution_limits_unsupported", "message" => message} =
             request(ctx, attrs(ctx, :resume)) |> json_response(422)

    assert message =~ "max_model_turns"
    assert message =~ "max_estimated_cost_usd"
    refute_received :worker_started
  end

  test "invalid host config fails without revealing its contents", ctx do
    for policy <- [nil, [], %{"private-field" => "private-value"}] do
      Application.put_env(:fountain, :execution_limit_ceiling, policy)
      response = request(ctx, attrs(ctx, :fresh)) |> json_response(422)
      assert response["error"] == "execution_limits_invalid"
      refute Jason.encode!(response) =~ "private-value"
      refute Jason.encode!(response) =~ "private-field"
    end

    refute_received :worker_started
  end

  test "fresh allowance is committed before worker startup and its initial prompt", ctx do
    owner = self()

    stub_server_start(fn _, {_, opts} ->
      id = Keyword.fetch!(opts, :conversation_id)
      assert Repo.get!(ExecutionAllowance, id).limits == %{}
      refute Repo.in_transaction?()
      send(owner, {:admitted, id})
      {:ok, owner}
    end)

    stub(Fountain.Conversations.ConversationServer, :queue_initial_prompt, fn pid,
                                                                              prompt,
                                                                              images ->
      assert pid == owner
      assert prompt == "check the branch"
      assert images == []
      assert_received {:admitted, id}
      assert Repo.get!(ExecutionAllowance, id).limits == %{}
      send(owner, {:prompt_queued, id})
      :ok
    end)

    params = Map.put(attrs(ctx, :fresh), "prompt", "check the branch")
    assert %{"data" => %{"id" => id}} = request(ctx, params) |> json_response(201)
    assert_received {:prompt_queued, ^id}
    assert creation_audits(ctx.user.id) == 2
  end

  test "failed fresh allowance insert rolls back the sandbox and conversation", ctx do
    before_counts = counts()

    stub(ExecutionAllowance, :new_changeset, fn id, limits ->
      Mimic.call_original(ExecutionAllowance, :new_changeset, [id, limits])
      |> Ecto.Changeset.add_error(:limits, "fixture rejection")
    end)

    assert request(ctx, attrs(ctx, :fresh)) |> json_response(422)
    assert counts() == before_counts
    assert Repo.aggregate(ExecutionAllowance, :count) == 0
    assert creation_audits(ctx.user.id) == 0
    refute_received :worker_started
  end

  test "failed fresh conversation validation rolls back its sandbox reservation", ctx do
    before_counts = counts()

    params =
      attrs(ctx, :fresh)
      |> Map.put("user_id", ctx.user.id)
      |> Map.put("title", %{})

    assert {:error, %Ecto.Changeset{}} = Launch.start_conversation(params)
    assert counts() == before_counts
    assert creation_audits(ctx.user.id) == 0
    refute_received :worker_started
  end

  test "fresh admission rechecks a ceiling changed after early preflight", ctx do
    before_counts = counts()

    stub(Fountain.RuntimeDispatch, :for_agent, fn agent ->
      save_ceiling(ctx.user, %{max_model_turns: 2})
      Mimic.call_original(Fountain.RuntimeDispatch, :for_agent, [agent])
    end)

    assert %{"error" => "execution_limits_unsupported"} =
             request(ctx, attrs(ctx, :fresh)) |> json_response(422)

    assert counts() == before_counts
    assert creation_audits(ctx.user.id) == 0
    refute_received :worker_started
  end

  test "worker startup failure retains the admitted allowance with its failed rows", ctx do
    stub_server_start(fn _, _ -> {:error, :fixture_rejection} end)

    assert %{"data" => %{"id" => id, "status" => "failed"}} =
             request(ctx, attrs(ctx, :fresh)) |> json_response(201)

    conv = Repo.get!(Conversation, id)
    assert Repo.get!(Sandbox, conv.sandbox_id).status == "failed"
    assert Repo.get!(ExecutionAllowance, id).limits == %{}
    assert creation_audits(ctx.user.id) == 2
  end

  for path <- [:fresh, :attach], failure <- [:conversation, :allowance, :ceiling] do
    test "#{path} rotation keeps the old binding on #{failure} refusal", ctx do
      before_counts = counts()
      params = rotation_attrs(ctx, unquote(path))

      params =
        case unquote(failure) do
          :conversation ->
            Map.put(params, "title", %{})

          :allowance ->
            stub(ExecutionAllowance, :new_changeset, fn id, limits ->
              Mimic.call_original(ExecutionAllowance, :new_changeset, [id, limits])
              |> Ecto.Changeset.add_error(:limits, "fixture rejection")
            end)

            params

          :ceiling ->
            stub(Fountain.RuntimeDispatch, :for_agent, fn agent ->
              save_ceiling(ctx.user, %{max_model_turns: 2})
              Mimic.call_original(Fountain.RuntimeDispatch, :for_agent, [agent])
            end)

            params
        end

      assert {:error, _} = Launch.start_or_resume_conversation(params)
      assert Repo.reload!(ctx.conv).channel_id == "limits"
      assert counts() == before_counts
      assert creation_audits(ctx.user.id) == 0
      refute_received :worker_started
    end
  end

  test "quota refusal keeps the channel bound", ctx do
    {:ok, _} = Fountain.Accounts.update_sandbox_limit(ctx.user, 1)
    assert {:error, _} = Launch.start_or_resume_conversation(rotation_attrs(ctx, :fresh))
    assert Repo.reload!(ctx.conv).channel_id == "limits"
    refute_received :worker_started
  end

  for path <- [:fresh, :attach] do
    test "#{path} rotation commits the replacement before worker or prompt delivery", ctx do
      owner = self()

      check_binding = fn id ->
        refute Repo.in_transaction?()
        assert Repo.reload!(ctx.conv).channel_id == nil
        assert Launch.channel_conversation(rotation_attrs(ctx, unquote(path))).id == id
        send(owner, :binding_checked)
      end

      stub_server_start(fn _, {_, opts} ->
        check_binding.(Keyword.fetch!(opts, :conversation_id))
        {:ok, owner}
      end)

      stub(Fountain.Conversations.ConversationServer, :send_prompt, fn id, _, _, _ ->
        check_binding.(id)
        :ok
      end)

      params = rotation_attrs(ctx, unquote(path))

      params =
        if unquote(path) == :attach, do: Map.put(params, "prompt", "continue"), else: params

      assert {:ok, _, :created} = Launch.start_or_resume_conversation(params)
      assert_received :binding_checked
    end
  end

  test "worker startup failure restores the old binding", ctx do
    stub_server_start(fn _, _ -> {:error, :fixture_rejection} end)

    assert {:ok, failed, :created} =
             Launch.start_or_resume_conversation(rotation_attrs(ctx, :fresh))

    assert failed.status == "failed"
    assert failed.channel_id == nil
    assert Launch.channel_conversation(rotation_attrs(ctx, :fresh)).id == ctx.conv.id
    assert Repo.get!(ExecutionAllowance, failed.id).limits == %{}
  end

  test "attachment prompt refusal restores the old binding", ctx do
    before_counts = counts()

    stub(Fountain.Conversations.ConversationServer, :send_prompt, fn _, _, _, _ ->
      {:error, :busy}
    end)

    params = Map.put(rotation_attrs(ctx, :attach), "prompt", "continue")
    assert {:error, :busy} = Launch.start_or_resume_conversation(params)
    assert Launch.channel_conversation(params).id == ctx.conv.id
    assert counts() == before_counts
  end

  test "failed startup cannot restore the old binding over a newer rotation", ctx do
    owner = self()

    stub_server_start(fn _, {_, opts} ->
      replacement = Repo.get!(Conversation, Keyword.fetch!(opts, :conversation_id))
      replacement |> Ecto.Changeset.change(channel_id: nil) |> Repo.update!()

      winner =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "idle",
          channel_id: "limits"
        )

      send(owner, {:winner, winner.id})
      {:error, :fixture_rejection}
    end)

    assert {:ok, _, :created} =
             Launch.start_or_resume_conversation(rotation_attrs(ctx, :fresh))

    assert_received {:winner, id}
    assert Launch.channel_conversation(rotation_attrs(ctx, :fresh)).id == id
    assert Repo.reload!(ctx.conv).channel_id == nil
  end

  test "rotation cannot unbind a conversation reassigned after lookup", ctx do
    other = insert_active_user()
    before_counts = counts()

    stub(Fountain.RuntimeDispatch, :for_agent, fn agent ->
      ctx.conv |> Ecto.Changeset.change(user_id: other.id) |> Repo.update!()
      Mimic.call_original(Fountain.RuntimeDispatch, :for_agent, [agent])
    end)

    params = rotation_attrs(ctx, :fresh) |> Map.delete("user_id")

    assert %{"errors" => %{"channel_id" => ["binding changed; retry the rotation"]}} =
             request(ctx, params) |> json_response(422)

    assert Repo.reload!(ctx.conv).user_id == other.id
    assert Repo.reload!(ctx.conv).channel_id == "limits"
    assert counts() == before_counts
    assert creation_audits(ctx.user.id) == 0
    refute_received :worker_started
  end

  defp rotation_attrs(ctx, path),
    do:
      attrs(ctx, path)
      |> Map.merge(%{"user_id" => ctx.user.id, "channel_id" => "limits", "fresh" => true})

  defp creation_audits(user_id) do
    Repo.aggregate(
      from(e in Fountain.Audit.Event,
        where:
          e.user_id == ^user_id and
            e.action in ["conversation.created", "conversation.execution_allowance_created"]
      ),
      :count
    )
  end

  defp save_ceiling(user, limits),
    do: user |> Repo.reload!() |> User.execution_limits_changeset(limits) |> Repo.update!()

  defp counts, do: {Repo.aggregate(Conversation, :count), Repo.aggregate(Sandbox, :count)}
  defp attrs(ctx, :fresh), do: %{"agent_id" => ctx.agent.id, "sandbox_mode" => "ephemeral"}
  defp attrs(ctx, :attach), do: %{"agent_id" => ctx.agent.id, "sandbox_id" => ctx.sandbox.id}
  defp attrs(ctx, :resume), do: %{"agent_id" => ctx.agent.id, "channel_id" => "limits"}
  defp attrs(ctx, :rotate), do: Map.put(attrs(ctx, :resume), "fresh", true)

  defp request(ctx, params) do
    ctx.conn
    |> authed_with_key(ctx.raw_key)
    |> put_req_header("content-type", "application/json")
    |> post("/api/conversations", Jason.encode!(params))
  end
end
