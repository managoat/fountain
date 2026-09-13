defmodule Fountain.Conversations.EgressTest do
  @moduledoc """
  The egress family that left `ConversationServer` in #1373, driven without
  a server: the split rules on real rows, the session's life against a
  stubbed `Fountain.Broker`, and the floor against a stubbed `Provisioning`.

  Brokering is switched on per tenant through application env, so this
  module is `async: false` like the other broker tests.
  """
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Broker
  alias Fountain.Conversations
  alias Fountain.Conversations.Egress
  alias Fountain.SecretBindings.Binding
  alias Managoat.Sandbox.Handle

  @session %{vault: "c-test", token: "av_sess_conv", expires_at: nil}

  setup do
    previous =
      for key <- [:broker_listen_port, :broker_proxy_url],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    user = insert_verified_user()
    {:ok, user: user}
  end

  defp broker_on do
    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
  end

  defp broker_off do
    Application.delete_env(:fountain, :broker_listen_port)
  end

  defp host_triples(bindings), do: Enum.map(bindings, &{&1.key, &1.host, &1.auth_type})

  describe "the split rules where no broker is configured" do
    test "are all no-ops, and read no bindings", %{user: user} do
      broker_off()
      {:ok, _} = Fountain.SecretBindings.create_binding(user.id, binding_attrs("DATABASE_URL"))
      _conn = insert_connection(user)

      refute Egress.brokered?()
      assert Egress.bindings(user.id) == %{}

      secrets = %{"GITHUB_TOKEN" => "ghp_real", "DATABASE_URL" => "postgres://x"}
      assert Egress.split_brokered(secrets, %{}) == {secrets, %{}}
      assert Egress.add_connection_secrets(user.id, secrets, %{}, nil) == {secrets, %{}, []}

      creds = %{anthropic_api_key: "sk-ant-api03-x"}
      assert Egress.split_inference(creds, %{}, %{}) == {creds, %{}, %{}}
    end
  end

  describe "split_brokered/2" do
    test "catalog keys and bound keys become placeholders; the rest stay", %{user: user} do
      broker_on()
      {:ok, _} = Fountain.SecretBindings.create_binding(user.id, binding_attrs("DATABASE_URL"))
      bindings = Egress.bindings(user.id)

      assert [%Binding{key: "DATABASE_URL", host: "api.example.com"}] = bindings["DATABASE_URL"]

      secrets = %{"GITHUB_TOKEN" => "ghp_real", "DATABASE_URL" => "postgres://x", "PLAIN" => "p"}

      assert {sandbox, brokered} = Egress.split_brokered(secrets, bindings)

      assert sandbox == %{
               "GITHUB_TOKEN" => "__github_token__",
               "DATABASE_URL" => "__database_url__",
               "PLAIN" => "p"
             }

      assert brokered == %{"GITHUB_TOKEN" => "ghp_real", "DATABASE_URL" => "postgres://x"}
    end
  end

  describe "split_inference/3" do
    test "placeholders for the runtime, values for the broker, the tenant's own wins",
         %{user: user} do
      broker_on()
      creds = %{anthropic_api_key: "sk-ant-api03-real", openai_api_key: "sk-real"}
      own = %{"ANTHROPIC_API_KEY" => "tenant-secret"}
      own_bindings = %{"OPENAI_API_KEY" => [:tenant_binding]}

      {env_creds, brokered, bindings} = Egress.split_inference(creds, own, own_bindings)

      assert env_creds == %{
               anthropic_api_key: "sk-ant-api03-__anthropic_api_key__",
               openai_api_key: "sk-__openai_api_key__"
             }

      # The secret split before this wins over the credential of the same name.
      assert brokered == %{"ANTHROPIC_API_KEY" => "tenant-secret", "OPENAI_API_KEY" => "sk-real"}

      # An implicit binding only where the tenant has none of their own.
      assert bindings["OPENAI_API_KEY"] == [:tenant_binding]

      assert host_triples(bindings["ANTHROPIC_API_KEY"]) == [
               {"ANTHROPIC_API_KEY", "api.anthropic.com", "substitute"}
             ]
    end
  end

  describe "connections" do
    test "add_connection_secrets/4 brokers a connection's token with bearer bindings to its hosts",
         %{user: user} do
      broker_on()
      conn = insert_connection(user)

      {merged, bindings, keys} =
        Egress.add_connection_secrets(user.id, %{"OWN" => "o"}, %{}, nil)

      assert keys == [conn.env_key]
      assert merged["OWN"] == "o"
      assert merged[conn.env_key] == conn.access_token

      assert host_triples(bindings[conn.env_key]) ==
               Enum.map(Fountain.Connections.Google.token_hosts(), &{conn.env_key, &1, "bearer"})
    end

    test "a tenant's own secret and own binding of the same name win", %{user: user} do
      broker_on()
      conn = insert_connection(user)
      own = %{conn.env_key => "mine"}
      own_bindings = %{conn.env_key => [:mine]}

      assert Egress.add_connection_secrets(user.id, own, own_bindings, nil) ==
               {own, own_bindings, []}
    end

    test "connection_bindings/3 adds the agent's remote MCP hosts to the provider's",
         %{user: user} do
      broker_on()
      conn = insert_connection(user)
      remote = %{conn.env_key => ["mcp.example", hd(Fountain.Connections.Google.token_hosts())]}

      hosts =
        Egress.connection_bindings(user.id, conn.env_key, remote) |> Enum.map(& &1.host)

      assert hosts == Enum.uniq(Fountain.Connections.Google.token_hosts() ++ ["mcp.example"])
    end

    test "refresh_connection_secrets/3 swaps in a rotated token and says so", %{user: user} do
      broker_on()
      conn = insert_connection(user)
      current = %{conn.env_key => conn.access_token, "OTHER" => "x"}

      assert Egress.refresh_connection_secrets([], user.id, current) == {current, false}

      assert Egress.refresh_connection_secrets([conn.env_key], user.id, current) ==
               {current, false}

      stale = %{conn.env_key => "old", "OTHER" => "x"}

      assert Egress.refresh_connection_secrets([conn.env_key], user.id, stale) ==
               {current, true}
    end

    # #1736: the tenant's own secrets, read again before a turn. Pure over
    # the merged map, so no rows are needed.
    test "refresh_tenant_secrets/5 swaps in an edited value and says so" do
      brokered = %{"GITHUB_TOKEN" => "ghp_old", "ANTHROPIC_API_KEY" => "sk-ant-api03-inference"}
      keys = ["GITHUB_TOKEN"]

      # Unchanged: the same map, and nothing moved.
      assert Egress.refresh_tenant_secrets(
               keys,
               %{"GITHUB_TOKEN" => "ghp_old", "DATABASE_URL" => "postgres://x"},
               brokered,
               %{},
               %{}
             ) == {brokered, keys, false}

      # Edited: the new value, and the unbrokered key stays out.
      assert Egress.refresh_tenant_secrets(
               keys,
               %{"GITHUB_TOKEN" => "ghp_new", "DATABASE_URL" => "postgres://y"},
               brokered,
               %{},
               %{}
             ) == {%{brokered | "GITHUB_TOKEN" => "ghp_new"}, keys, true}

      # Added: a bound key that was not there before joins the broker.
      bindings = %{"STRIPE_KEY" => [%Binding{key: "STRIPE_KEY", host: "api.stripe.com"}]}

      assert {%{"STRIPE_KEY" => "sk_live"} = next, ["GITHUB_TOKEN", "STRIPE_KEY"], true} =
               Egress.refresh_tenant_secrets(
                 keys,
                 %{"GITHUB_TOKEN" => "ghp_old", "STRIPE_KEY" => "sk_live"},
                 brokered,
                 bindings,
                 %{}
               )

      assert next["GITHUB_TOKEN"] == "ghp_old"
    end

    test "refresh_tenant_secrets/5 drops a deleted key, and what it masked takes the name back" do
      # The tenant's own ANTHROPIC_API_KEY won at init; deleting it hands the
      # name back to the runtime's credential, as init would. Same for a
      # vault override of a connection's key (the review's row 1): the
      # connection token is in the underlay, and comes back.
      underlay = %{"ANTHROPIC_API_KEY" => "sk-ant-api03-inference", "GOOGLE_TOKEN" => "ya29.live"}

      brokered = %{
        "GITHUB_TOKEN" => "ghp",
        "ANTHROPIC_API_KEY" => "sk-ant-api03-own",
        "GOOGLE_TOKEN" => "ya29.override"
      }

      assert Egress.refresh_tenant_secrets(
               ["ANTHROPIC_API_KEY", "GITHUB_TOKEN", "GOOGLE_TOKEN"],
               %{"GITHUB_TOKEN" => "ghp"},
               brokered,
               %{},
               underlay
             ) ==
               {%{
                  "GITHUB_TOKEN" => "ghp",
                  "ANTHROPIC_API_KEY" => "sk-ant-api03-inference",
                  "GOOGLE_TOKEN" => "ya29.live"
                }, ["GITHUB_TOKEN"], true}

      # A deleted key nothing else supplies leaves the broker.
      assert Egress.refresh_tenant_secrets(
               ["GITHUB_TOKEN"],
               %{},
               %{"GITHUB_TOKEN" => "ghp"},
               %{},
               %{}
             ) ==
               {%{}, [], true}
    end

    test "refresh_rules/4 is :ok only when a live session was rewritten" do
      stub(Broker, :refresh, fn "conv-1", %{"K" => "v"}, %{}, [user_id: "u"] -> {:ok, 2} end)
      assert Egress.refresh_rules("conv-1", %{"K" => "v"}, %{}, user_id: "u") == :ok

      stub(Broker, :refresh, fn _, _, _, _ -> {:ok, 0} end)
      assert Egress.refresh_rules("conv-1", %{}, %{}, []) == {:error, :no_live_session}

      stub(Broker, :refresh, fn _, _, _, _ -> {:error, :down} end)
      assert Egress.refresh_rules("conv-1", %{}, %{}, []) == {:error, :down}
    end

    test "with_connection_servers/4 resolves a remote entry only for a brokered tenant",
         %{user: user} do
      conn = insert_connection(user)

      # Three kinds of entry: one served by Fountain for the connection, one
      # remote server the connection's token is attached to, and a plain one.
      agent = %{
        mcp_servers: %{
          "served" => %{"connection" => conn.id},
          "remote" => %{"connection" => conn.id, "url" => "https://mcp.example/sse"},
          "plain" => %{"url" => "https://plain.example"}
        }
      }

      # Unbrokered: no token and no connections, so both connection entries
      # are dropped and the agent runs on the plain one.
      broker_off()

      assert %{mcp_servers: %{"plain" => _} = off} =
               Egress.with_connection_servers(agent, user.id, "conv-1", "tok")

      assert Map.keys(off) == ["plain"]

      broker_on()

      assert %{mcp_servers: %{"served" => %{"url" => url}, "remote" => remote, "plain" => _}} =
               Egress.with_connection_servers(agent, user.id, "conv-1", "tok")

      assert url =~ "conv-1"
      assert remote["url"] == "https://mcp.example/sse"

      assert Egress.with_connection_servers(nil, user.id, "conv-1", "tok") == nil

      assert Egress.with_connection_servers(%{mcp_servers: nil}, user.id, "conv-1", "tok") == %{
               mcp_servers: nil
             }
    end
  end

  describe "the session" do
    test "the broker stage completes only after CA installation", %{user: user} do
      broker_on()
      conv = insert_conversation(user_id: user.id)

      stub(Broker, :prepare, fn id, brokered, bindings, opts ->
        assert id == conv.id
        assert brokered == %{"GITHUB_TOKEN" => "ghp"}
        assert bindings == %{}
        assert opts == [network: :unrestricted, user_id: user.id]
        {:ok, @session}
      end)

      assert {:ok, @session} =
               Egress.prepare(conv.id, %{"GITHUB_TOKEN" => "ghp"}, %{},
                 network: :unrestricted,
                 user_id: user.id
               )

      assert [{"started", %{"keys" => ["GITHUB_TOKEN"]}}] = stages(conv.id, "broker")
      handle = %Handle{provider: :sprites, name: "s"}

      stub(Fountain.Conversations.Provisioning, :install_broker_ca, fn ^handle, id ->
        assert id == conv.id
        assert [{"started", _}] = stages(conv.id, "broker")
        :ok
      end)

      assert :ok = Egress.install_ca(@session, handle, conv.id)
      assert [{"started", _}, {"done", %{"vault" => "c-test"}}] = stages(conv.id, "broker")
    end

    test "a failed CA command never leaves a completed broker stage", %{user: user} do
      conv = insert_conversation(user_id: user.id)
      handle = %Handle{provider: :sprites, name: "s"}
      stub(Broker, :prepare, fn _id, _b, _bi, _o -> {:ok, @session} end)
      stub(Broker, :ca_pem, fn -> {:ok, "PEM"} end)
      stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _data, _opts -> :ok end)

      stub(Managoat.Sandbox.Sprites, :exec, fn _h, "bash", _args, _opts ->
        {:ok, "trust installation failed", 1}
      end)

      assert {:ok, session} = Egress.prepare(conv.id, %{}, %{}, user_id: user.id)

      assert {:error, {:broker, :ca_install_exit, 1, _}} =
               Egress.install_ca(session, handle, conv.id)

      assert [{"started", _}, {"failed", %{"reason" => "ca_install_exit", "exit_code" => 1}}] =
               stages(conv.id, "broker")
    end

    test "prepare/4 reports the failure as the stage's", %{user: user} do
      conv = insert_conversation(user_id: user.id)
      stub(Broker, :prepare, fn _id, _b, _bi, _o -> {:error, :down} end)

      assert {:error, :down} =
               Egress.prepare(conv.id, %{}, %{}, network: :unrestricted, user_id: user.id)

      assert [{"started", _}, {"failed", %{"reason" => ":down"}}] = stages(conv.id, "broker")
    end

    test "reprepare/5 replaces the proxy variables and nothing else", %{user: user} do
      broker_on()
      stub(Broker, :prepare, fn _id, _b, _bi, _o -> {:ok, @session} end)

      old = %{@session | token: "av_sess_old"}
      env = [{"KEEP", "1"}] ++ Broker.sandbox_env(old) ++ [{"ALSO", "2"}]

      assert {:ok, @session, rebuilt} =
               Egress.reprepare("c", %{}, %{}, env, network: :unrestricted, user_id: user.id)

      # The CA half of `old` is already in the list and stays where it is.
      assert rebuilt ==
               [{"KEEP", "1"}] ++
                 Broker.ca_env() ++ [{"ALSO", "2"}] ++ Broker.proxy_env(@session)

      stub(Broker, :prepare, fn _id, _b, _bi, _o -> {:error, :down} end)

      assert {:error, :down} =
               Egress.reprepare("c", %{}, %{}, env, network: :unrestricted, user_id: user.id)
    end

    # #1674: stripping the CA keys by name takes the tenant's own
    # SSL_CERT_FILE with them, and re-adding the broker's value on top is the
    # bug the issue reported — an hour into the conversation rather than at
    # provisioning, where it would have been noticed.
    test "reprepare/5 leaves an env_vars override of the CA defaults alone",
         %{user: user} do
      broker_on()
      stub(Broker, :prepare, fn _id, _b, _bi, _o -> {:ok, @session} end)

      env =
        Broker.ca_env() ++
          [{"SSL_CERT_FILE", "/home/sprite/mine.crt"}] ++ Broker.proxy_env(@session)

      assert {:ok, @session, rebuilt} =
               Egress.reprepare("c", %{}, %{}, env, network: :unrestricted, user_id: user.id)

      assert List.last(Enum.filter(rebuilt, &(elem(&1, 0) == "SSL_CERT_FILE"))) ==
               {"SSL_CERT_FILE", "/home/sprite/mine.crt"}
    end

    test "drop_oauth_token/3 forgets the token on both sides and re-splits the API key" do
      creds = %{claude_code_oauth_token: "sk-ant-oat01-x", anthropic_api_key: "sk-ant-api03-k"}
      brokered = %{"CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat01-x", "GITHUB_TOKEN" => "ghp"}
      bindings = %{"CLAUDE_CODE_OAUTH_TOKEN" => [:implicit], "GITHUB_TOKEN" => [:own]}

      {env_creds, brokered, bindings} = Egress.drop_oauth_token(creds, brokered, bindings)

      assert env_creds == %{anthropic_api_key: "sk-ant-api03-__anthropic_api_key__"}
      assert brokered == %{"ANTHROPIC_API_KEY" => "sk-ant-api03-k", "GITHUB_TOKEN" => "ghp"}
      assert Map.keys(bindings) |> Enum.sort() == ["ANTHROPIC_API_KEY", "GITHUB_TOKEN"]
      assert bindings["GITHUB_TOKEN"] == [:own]
    end

    test "sandbox_env/1 is the session's proxy variables, or nothing", %{user: user} do
      broker_on()
      assert Egress.sandbox_env(nil) == []
      assert Egress.sandbox_env(@session) == Broker.sandbox_env(@session)
    end

    test "the exported CA counter records one bounded outcome per conversation setup", %{
      user: user
    } do
      metric =
        Enum.find(FountainWeb.Telemetry.prometheus_metrics(), fn metric ->
          metric.name == [:fountain, :broker, :ca_install, :count]
        end)

      assert metric.tags == [:provider, :outcome]
      broker_on()
      handler = {__MODULE__, make_ref()}
      :ok = :telemetry.attach(handler, metric.event_name, &__MODULE__.forward_ca_metric/4, self())
      on_exit(fn -> :telemetry.detach(handler) end)
      conv = insert_conversation(user_id: user.id)
      handle = %Handle{provider: :sprites, name: "s"}

      assert :ok = Egress.install_ca(nil, handle, conv.id)
      stub(Broker, :prepare, fn _id, _b, _bi, _o -> {:ok, @session} end)
      assert {:ok, @session} = Egress.prepare(conv.id, %{}, %{}, user_id: user.id)
      assert {:ok, @session, _} = Egress.reprepare(conv.id, %{}, %{}, [], user_id: user.id)
      refute_received {:ca_metric, _, _}

      for {result, outcome} <- [
            {:ok, "ok"},
            {{:error, {:broker, :ca_install_exit, 1, "sensitive output"}}, "exit"},
            {{:error, {:broker, :ca_install, :timeout}}, "unreachable"},
            {{:error, :ca_unavailable}, "unavailable"}
          ] do
        stub(Fountain.Conversations.Provisioning, :install_broker_ca, fn ^handle, _id ->
          result
        end)

        assert Egress.install_ca(@session, handle, conv.id) == result
        assert_received {:ca_metric, %{count: 1}, %{provider: :sprites, outcome: ^outcome}}
        refute_received {:ca_metric, _, _}
      end
    end

    test "install_ca/3 emits no broker stage without a session", %{user: user} do
      conv = insert_conversation(user_id: user.id)
      handle = %Handle{provider: :sprites, name: "s"}
      assert :ok = Egress.install_ca(nil, handle, conv.id)
      assert stages(conv.id, "broker") == []
    end
  end

  def forward_ca_metric(_event, measurements, metadata, pid) do
    send(pid, {:ca_metric, measurements, metadata})
  end

  describe "release/2" do
    setup :set_mimic_global

    test "releases the vault off the caller's path, for a brokered tenant only", %{user: user} do
      test_pid = self()
      stub(Broker, :release, fn conv_id -> send(test_pid, {:released, conv_id}) && :ok end)

      broker_off()
      assert :ok = Egress.release("c-off")
      refute_receive {:released, "c-off"}, 100

      broker_on()
      assert :ok = Egress.release("c-on")
      assert_receive {:released, "c-on"}, 1_000
    end
  end

  describe "apply_policy/4" do
    test "is the environment's network policy, or the broker floor when brokered" do
      handle = %Handle{provider: :sprites, name: "s"}
      env = %{networking_type: "limited"}

      stub(Fountain.Conversations.Provisioning, :apply_network_policy, fn ^handle, ^env, "c" ->
        :policy
      end)

      stub(Fountain.Conversations.Provisioning, :apply_broker_floor, fn ^handle, "c" -> :floor end)

      assert :policy = Egress.apply_policy(handle, env, "c", false)
      assert :floor = Egress.apply_policy(handle, env, "c", true)
    end
  end

  defp binding_attrs(key),
    do: %{"key" => key, "host" => "api.example.com", "auth_type" => "bearer"}

  defp stages(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end
end
