defmodule Fountain.EnvironmentLayers.PipelineTest do
  use Fountain.DataCase, async: true
  use Mimic
  alias Fountain.{Crypto, Environments}
  alias Fountain.Broker.Native.{Session, Sessions}
  alias Fountain.EnvironmentLayers.{Builds, Helper, Pipeline, Store}
  alias Managoat.Sandbox
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()

    env =
      insert_env(
        user_id: user.id,
        cache_enabled: true,
        build_script: "build-only",
        setup_script: "never-boot"
      )

    {:ok, key} = Crypto.load_tenant_key(user.id)

    {:ok, _} =
      Environments.upsert_secret(
        env,
        %{"key" => "GITHUB_TOKEN", "value" => "real-build-secret"},
        key
      )

    compatibility = %{
      "provider" => "sprites",
      "architecture" => "amd64",
      "base" => "sha256:" <> String.duplicate("b", 64),
      "revisions" => []
    }

    opts = [
      store: [
        config: %Store.Config{
          endpoint: "https://store.example",
          bucket: "tests",
          access_key_id: "test",
          secret_access_key: "test"
        }
      ]
    ]

    {:ok, build} = Builds.request(user.id, env.id, compatibility, opts)

    stub(Sandbox, :create, fn :sprites, name -> {:ok, %Handle{provider: :sprites, name: name}} end)

    stub(Sandbox, :destroy, fn _ -> :ok end)
    stub(Sandbox, :get, fn _ -> {:error, :not_found} end)
    stub(Helper, :install, fn _, "amd64" -> :ok end)
    stub(Fountain.Conversations.Provisioning, :install_broker_ca, fn _, nil -> :ok end)
    stub(Fountain.Broker.TransportRelay, :ensure, fn _, _ -> :ok end)
    stub(Fountain.Broker.TransportRelay, :stop, fn _ -> :ok end)

    stub(Helper, :keygen, fn ->
      {:ok, %{"identity" => "AGE-SECRET-KEY-1TEST", "recipient" => "public-recipient"}}
    end)

    %{user: user, env: env, build: build, compatibility: compatibility, opts: opts}
  end

  defp protocol(context, failing \\ nil) do
    parent = self()

    stub(Sandbox, :apply_network_policy, fn _, policy ->
      send(parent, {:floor, policy.allow})
      if policy.allow == ["store.example"], do: assert(Repo.aggregate(Session, :count) == 0)
      :ok
    end)

    stub(Sandbox, :exec, fn _, command, args, opts ->
      case command do
        "uname" ->
          {:ok, "x86_64\n", 0}

        "bash" ->
          assert args == ["-c", "build-only"]
          env = Map.new(opts[:env])
          assert env["GITHUB_TOKEN"] == "__github_token__"
          refute inspect(env) =~ "real-build-secret"
          assert Repo.aggregate(Session, :count) == 1
          assert Repo.one!(Session).conversation_id == nil
          send(parent, :setup)
          {:ok, "", 0}
      end
    end)

    stub(Helper, :call, fn _, request ->
      send(parent, {:helper, request.operation})

      if request.operation == failing do
        {:error, :layer_operation_failed}
      else
        case request.operation do
          "snapshot" ->
            {:ok,
             %{"result" => %{"base" => context.compatibility["base"], "sha256" => "baseline"}}}

          "process_snapshot" ->
            {:ok, %{"result" => %{"sha256" => "processes"}}}

          operation when operation in ["quiescent", "export"] ->
            assert Repo.aggregate(Session, :count) == 0
            {:ok, %{"result" => %{}}}

          "seal" ->
            refute Map.has_key?(request, :identity)
            assert request.recipient == "public-recipient"
            {:ok, %{"result" => %{"sha256" => String.duplicate("a", 64), "bytes" => 123}}}

          "upload" ->
            refute Map.has_key?(request, :identity)
            assert String.starts_with?(request.url, "https://store.example/tests/")
            {:ok, %{"result" => %{"sha256" => String.duplicate("a", 64), "bytes" => 123}}}
        end
      end
    end)
  end

  test "environment-only setup revokes brokerage before export and upload", context do
    protocol(context)
    assert {:ok, ready} = Pipeline.run(context.user.id, context.build.id, context.opts)
    assert ready.state == "ready"
    assert Repo.aggregate(Session, :count) == 0
    assert_receive :setup
    assert_receive {:helper, "export"}
    assert_receive {:helper, "upload"}
    assert_receive {:floor, ["store.example"]}
  end

  for failure <- ["snapshot", "quiescent", "export", "seal", "upload"] do
    test "#{failure} failure refuses publication and destroys the builder", context do
      protocol(context, unquote(failure))

      assert {:error, :build_failed} =
               Pipeline.run(context.user.id, context.build.id, context.opts)

      assert Builds.get(context.user.id, context.build.id).state == "failed"
      assert Repo.aggregate(Session, :count) == 0

      assert Repo.get!(Fountain.Conversations.Sandbox, context.build.sandbox_id).status ==
               "terminated"

      if unquote(failure) != "upload", do: refute_received({:helper, "upload"})
    end
  end

  test "build sessions are tenant-scoped and invalidated by input changes", context do
    {:ok, build} = Builds.claim(context.user.id, context.build.id)
    other = insert_verified_user()

    assert {:error, :obsolete_build} =
             Sessions.create_build(other.id, build.id, build.claim, [], :unrestricted)

    assert {:error, :obsolete_build} =
             Sessions.create_build(
               context.user.id,
               build.id,
               Ecto.UUID.generate(),
               [],
               :unrestricted
             )

    assert {:ok, session} =
             Sessions.create_build(context.user.id, build.id, build.claim, [], :unrestricted)

    assert {:ok, resolved} = Sessions.lookup(session.token)
    assert resolved.meta["build_id"] == build.id
    refute Map.has_key?(resolved.meta, "conversation_id")
    assert {:ok, _} = Environments.update_environment(context.env, %{build_script: "changed"})
    assert :error = Sessions.lookup(session.token)
    assert {:error, _} = Sessions.remote_lookup(session.token)
    assert :ok = Sessions.release_build(context.user.id, build.id)
    assert Repo.aggregate(Session, :count) == 0
  end
end
