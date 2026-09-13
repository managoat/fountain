defmodule Fountain.Conversations.ConversationServerPlatformInferenceTest do
  # The platform key through a real ConversationServer (#1388): that it is
  # selected only when the tenant has none, that it takes the *same* two
  # routes a tenant's own key takes (ADR 0019 gate 3 when brokered, the
  # sandbox env when not), and that the turn it ran is marked so the pricer
  # can find it.
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.TurnMachine
  alias Fountain.InferenceCredentials.Source

  @session %{vault: "c-test", token: "av_sess_conv", expires_at: nil}
  @platform_key "sk-ant-platform-key"

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude", model: "anthropic/claude-opus-5")

    previous =
      for key <- [
            :broker_listen_port,
            :broker_proxy_url,
            :platform_anthropic_api_key,
            :platform_openai_api_key,
            :platform_gemini_api_key
          ],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    # The deployment holds a key. The tenant holds nothing — that is
    # `ConversationServerCase`'s own default stub of `decrypted_for_user/2`,
    # which the two tests about a tenant's own key override.
    Application.put_env(:fountain, :platform_anthropic_api_key, @platform_key)

    {:ok, user: user, agent: agent}
  end

  describe "the non-brokered path" do
    test "the platform key is what the runtime is handed, exactly as a tenant's own is", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)

      stub_happy_sprite()
      _ref = stub_turn_boundary()
      reject(Fountain.Broker, :prepare, 4)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # The harness runtime ignores credentials, so the assertion is on what
      # the server hands `default_env/2` plus what the real runtime makes of
      # it — the same two halves the broker test checks.
      state = :sys.get_state(pid)
      assert state.env_credentials == %{anthropic_api_key: @platform_key}
      assert state.brokered == %{}

      assert Managoat.Runtimes.Claude.default_env(nil, state.env_credentials) ==
               [{"ANTHROPIC_API_KEY", @platform_key}]
    end

    test "a tenant with their own key never sees the platform one", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)

      stub_happy_sprite()
      _ref = stub_turn_boundary()

      # After `stub_happy_sprite/0`, which sets the case's own default of "no
      # credentials at all" — a stub set before it is overwritten by it.
      Mimic.stub(Fountain.InferenceCredentials, :decrypted_for_user, fn _u, _k ->
        {:ok, %{anthropic_api_key: "sk-ant-tenant-key"}}
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = :sys.get_state(pid)
      assert state.inference_source == Source.credential()
      assert state.env_credentials == %{anthropic_api_key: "sk-ant-tenant-key"}
    end

    # ADR 0053 decision 5. The vault value wins in the sandbox environment
    # (`Egress`'s gate-3 split; `docs/concepts/secrets.md` publishes it) but
    # selection could not see it, so this conversation took the platform key,
    # was stamped `"platform"`, priced against the tenant's credits and
    # counted against the deployment's daily ceiling -- on a turn the
    # tenant's own key served. Live on the hosted deployment, which has held
    # platform keys since 2026-09-03.
    test "a vault secret naming the credential is the tenant's own key, not the platform's", %{
      user: user,
      agent: agent
    } do
      vault = insert_vault(user_id: user.id)

      # The case stubs `load_tenant_key/1` to an all-zero DEK, so the row has
      # to be written under the same one or the server cannot decrypt it and
      # the secret never reaches the merge.
      {:ok, _} =
        Fountain.Vaults.upsert_secret(
          vault,
          %{"key" => "ANTHROPIC_API_KEY", "value" => "sk-ant-from-the-vault"},
          <<0::256>>
        )

      conv = insert_conversation(user_id: user.id, agent: agent, vault_id: vault.id)

      stub_happy_sprite()
      _ref = stub_turn_boundary()

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = :sys.get_state(pid)
      assert state.inference_source == Source.tenant_secret()

      # And so the turn is not billed as platform inference.
      assert TurnMachine.with_inference(%{"input" => 5}, TurnMachine.ctx(state)) ==
               %{"input" => 5, "inference" => "own"}
    end
  end

  describe "the brokered path (ADR 0019 gate 3)" do
    setup %{user: user} do
      Application.put_env(:fountain, :broker_listen_port, 14_322)
      Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
      :ok
    end

    test "the platform key goes to the broker and never into the sandbox", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()

      stub_happy_sprite()
      _ref = stub_turn_boundary()
      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

      stub(Fountain.Broker, :prepare, fn _c, brokered, bindings, _opts ->
        send(test, {:prepared, brokered, bindings})
        {:ok, @session}
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # Same route as a tenant's own key: the value reaches the broker with
      # an implicit substitute binding to the provider's host.
      assert_receive {:prepared, brokered, bindings}, 2_000
      assert brokered["ANTHROPIC_API_KEY"] == @platform_key

      assert [%{host: "api.anthropic.com", auth_type: "substitute"}] =
               bindings["ANTHROPIC_API_KEY"]

      assert_receive {:spawned, _cmd, _args, opts}, 2_000
      spawn_env = Keyword.fetch!(opts, :env)
      refute Enum.any?(spawn_env, fn {_, v} -> v == @platform_key end)
    end
  end

  describe "the mark on the turn" do
    test "the server records which key it selected", %{user: user, agent: agent} do
      conv = insert_conversation(user_id: user.id, agent: agent)

      stub_happy_sprite()
      _ref = stub_turn_boundary()

      {pid, _mon, :alive} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = :sys.get_state(pid)
      assert state.inference_source == Source.platform()
      assert state.inference_model == "anthropic/claude-opus-5"
      assert state.env_credentials.anthropic_api_key == @platform_key
    end

    test "usage says which key ran the turn, and names the model on a platform turn" do
      ctx = %{inference: Source.platform(), model: "anthropic/claude-opus-5"}

      assert TurnMachine.with_inference(%{"input" => 5, "output" => 3}, ctx) ==
               %{
                 "input" => 5,
                 "output" => 3,
                 "inference" => "platform",
                 "model" => "anthropic/claude-opus-5"
               }

      assert TurnMachine.with_inference(%{"input" => 5}, %{ctx | inference: Source.credential()}) ==
               %{"input" => 5, "inference" => "own"}

      assert TurnMachine.with_inference(nil, ctx) == nil
    end

    test "with no platform key configured the usage map is untouched" do
      Application.delete_env(:fountain, :platform_anthropic_api_key)

      ctx = %{inference: Source.credential(), model: "anthropic/claude-opus-5"}
      assert TurnMachine.with_inference(%{"input" => 5}, ctx) == %{"input" => 5}
    end
  end

  # #1685. The mark above is applied in the `{:done, ...}` clause, which a
  # turn reaches only when its prompt is *answered*. Production over seven
  # days: 26 turns carried the mark and 319 ended with no usage map at all —
  # whichever of those ran on the platform key spent it invisibly. The stamp
  # is therefore written at turn start, where `Managoat.ACP.Peer` reports
  # `:model_selected` immediately before it writes `session/prompt`.
  describe "the mark at turn start (#1685)" do
    setup %{user: user, agent: agent} do
      conv = insert_conversation(user_id: user.id, agent: agent)
      row = insert_turn(conv, status: "running", started_at: DateTime.utc_now())

      machine = %TurnMachine{
        conversation_id: conv.id,
        row: row,
        metrics:
          TurnMachine.start_metrics("claude", :sprites, System.monotonic_time(:millisecond))
      }

      {:ok, conv: conv, row: row, machine: machine}
    end

    test "a turn whose adapter dies before the response still says whose key ran it", %{
      machine: m,
      row: row
    } do
      {_m, []} = select_model(m, platform_ctx())

      # No `{:done, ...}` ever arrives: the adapter exits, the sandbox hits
      # its deadline, or the server restarts.
      assert stored(row).usage == %{
               "inference" => "platform",
               "model" => "anthropic/claude-opus-5"
             }
    end

    test "so does one that is interrupted", %{machine: m, row: row} do
      {m, []} = select_model(m, platform_ctx())

      TurnMachine.mark_interrupted(m)

      assert stored(row).status == "interrupted"
      assert stored(row).usage["inference"] == "platform"
    end

    test "so does one that fails before it can report anything", %{machine: m, conv: conv} do
      other = insert_turn(conv, status: "running")
      {_m, []} = select_model(%{m | row: other}, platform_ctx())

      TurnMachine.fail_before_start(other, conv.id, "spawn", "boom", 1)

      assert stored(other).status == "failed"
      assert stored(other).usage["inference"] == "platform"
    end

    test "a failed model selection stamps nothing: no prompt went out", %{
      machine: m,
      row: row
    } do
      ctx = platform_ctx()

      # Every peer source of this report is in `phase: :setting_model`,
      # strictly before `send_prompt/1`. The turn spent no tokens, and a
      # stamp here would be indistinguishable afterwards from a turn that
      # died mid-inference.
      assert {_m, [{:finish, "failed", _, _}, {:drop_connection, "failed"}]} =
               TurnMachine.handle(
                 m,
                 {:failed, {:model_selection_failed, ctx.model, "no such model"}},
                 ctx
               )

      assert is_nil(stored(row).usage)
      assert stored(row).model_selection["status"] == "failed"
    end

    test "a turn on the tenant's own key is not stamped as a platform one", %{
      machine: m,
      row: row
    } do
      ctx = %{platform_ctx() | inference: Source.credential()}
      {_m, []} = select_model(m, ctx)

      assert stored(row).usage == %{"inference" => "own"}
      refute stored(row).usage["inference"] == "platform"
    end

    test "an own-credential turn without platform keys stamps nothing", %{machine: m, row: row} do
      Application.delete_env(:fountain, :platform_anthropic_api_key)

      {_m, []} = select_model(m, %{platform_ctx() | inference: Source.credential()})
      assert is_nil(stored(row).usage)
    end

    test "a turn that does answer its prompt ends with the map it had before the stamp", %{
      machine: m,
      conv: conv,
      row: row
    } do
      ctx = platform_ctx()
      {m, []} = select_model(m, ctx)

      assert {_m, [{:finish, "completed", _, _}]} =
               TurnMachine.handle(m, {:done, "end_turn", %{"input" => 5, "output" => 3}}, ctx)

      assert stored(row).usage == TurnMachine.with_inference(%{"input" => 5, "output" => 3}, ctx)

      # And the conversation's running sums moved once, not twice.
      assert %{usage_input_tokens: 5, usage_output_tokens: 3} =
               Conversations._unsafe_get_conversation!(conv.id)
    end

    test "the API reports no token figure for a turn carrying only the stamp" do
      assert FountainWeb.ConversationJSON.turn_usage(%{
               "inference" => "platform",
               "model" => "anthropic/claude-opus-5"
             }) == nil

      assert FountainWeb.ConversationJSON.turn_usage(%{
               "inference" => "platform",
               "model" => "anthropic/claude-opus-5",
               "input" => 5,
               "output" => 3
             }) == %{input: 5, output: 3}
    end
  end

  test "a grant-only deployment stamps the completed codex turn", %{user: user} do
    for key <- [:platform_anthropic_api_key, :platform_openai_api_key, :platform_gemini_api_key],
        do: Application.delete_env(:fountain, key)

    Fountain.ChatGPTFixtures.connect!()
    assert Fountain.PlatformChatGPT.active?()
    refute Fountain.PlatformInference.enabled?()
    model = "openai/gpt-6-astra"

    assert {:ok, %Fountain.InferenceCredentials.Source{origin: :platform} = source, credentials} =
             Fountain.InferenceCredentials.select(model, %{}, "codex", refresh: false)

    assert Map.has_key?(credentials, :codex_chatgpt_access_token)
    agent = insert_agent(user_id: user.id, runtime: "codex", model: model)
    conv = insert_conversation(user_id: user.id, agent: agent)
    row = insert_turn(conv, status: "running", started_at: DateTime.utc_now())

    machine = %TurnMachine{
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      row: row,
      metrics: TurnMachine.start_metrics("codex", :runner, System.monotonic_time(:millisecond))
    }

    ctx = %{inference: source, model: model}
    {machine, []} = select_model(machine, ctx)
    assert stored(row).usage == %{"inference" => "platform", "model" => model}

    {machine, [{:finish, status, attrs, metadata}]} =
      TurnMachine.handle(machine, {:done, "end_turn", %{"input" => 5, "output" => 3}}, ctx)

    TurnMachine.finish(machine, status, attrs, metadata)

    assert stored(row).status == "completed"

    assert stored(row).usage == %{
             "inference" => "platform",
             "model" => model,
             "input" => 5,
             "output" => 3
           }
  end

  defp platform_ctx, do: %{inference: Source.platform(), model: "anthropic/claude-opus-5"}

  # What `Managoat.ACP.Peer` reports from `send_prompt/1`, just before it
  # writes `session/prompt`.
  defp select_model(machine, ctx),
    do: TurnMachine.handle(machine, {:model_selected, ctx.model, ctx.model, "runtime"}, ctx)

  defp stored(row), do: Fountain.Repo.get!(Conversations.Turn, row.id)

  defp stub_turn_boundary do
    test = self()
    ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, _data -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _c -> :ok end)
    ref
  end
end
