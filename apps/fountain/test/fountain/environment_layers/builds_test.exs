defmodule Fountain.EnvironmentLayers.BuildsTest do
  use Fountain.DataCase, async: true
  use Mimic
  alias Fountain.{Audit, Crypto, Environments, Quotas}
  alias Fountain.Conversations.Sandbox
  alias Fountain.EnvironmentLayers.{Build, Builds, Manifest, Store}
  alias Managoat.Sandbox.Handle

  defp compatibility,
    do: %{
      "provider" => "sprites",
      "architecture" => "amd64",
      "base" => "immutable-image-1",
      "revisions" => []
    }

  defp opts,
    do: [
      actor: "api",
      store: [
        config: %Store.Config{
          endpoint: "https://store.example",
          bucket: "build-tests",
          access_key_id: "test",
          secret_access_key: "test"
        }
      ]
    ]

  defp artifact,
    do: %{sha256: String.duplicate("a", 64), bytes: 500, identity: "AGE-SECRET-KEY-1TEST"}

  setup do
    user = insert_verified_user()

    env =
      insert_env(
        user_id: user.id,
        cache_enabled: true,
        build_script: "compile",
        setup_script: "boot"
      )

    stub(Managoat.Sandbox, :create, fn :sprites, name ->
      {:ok, %Handle{provider: :sprites, name: name}}
    end)

    stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)
    stub(Managoat.Sandbox, :get, fn _ -> {:error, :not_found} end)
    %{user: user, env: env}
  end

  test "disabled storage and foreign owners reserve nothing", %{user: user, env: env} do
    other = insert_verified_user()

    assert {:error, :disabled} =
             Builds.request(user.id, env.id, compatibility(), store: [config: nil])

    assert {:error, :not_found} = Builds.request(other.id, env.id, compatibility(), opts())
    assert Repo.aggregate(Build, :count) == 0
    assert Quotas.fleet_count(provider: "sprites") == 0
    assert {:ok, env} = Environments.update_environment(env, %{cache_enabled: false})

    assert {:error, :cache_not_buildable} =
             Builds.request(user.id, env.id, compatibility(), opts())
  end

  test "deduplicates admission and consumes the same fleet budget as conversations", %{
    user: user,
    env: env
  } do
    assert {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())
    assert {:ok, same} = Builds.request(user.id, env.id, compatibility(), opts())
    assert same.id == build.id
    assert Quotas.fleet_count(provider: "sprites") == 1
    sandbox = Repo.get!(Sandbox, build.sandbox_id)
    assert sandbox.environment_id == env.id
    assert is_nil(sandbox.agent_id) and is_nil(sandbox.vault_id)
    assert length(Audit.list_for_user(user.id, action_prefix: "environment_layer.requested")) == 1

    for _ <- 1..(Quotas.fleet_ceiling("sprites") - 1),
        do: insert_sandbox(user_id: user.id, status: "ready")

    assert {:ok, ^same} = Builds.request(user.id, env.id, compatibility(), opts())
    different = Map.put(compatibility(), "base", "image-2")
    assert {:error, :fleet_full} = Builds.request(user.id, env.id, different, opts())
  end

  test "claim is single use and publication requires matching claim plus confirmed teardown", %{
    user: user,
    env: env
  } do
    {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())
    {:ok, claimed} = Builds.claim(user.id, build.id, actor: "api")
    assert {:error, :obsolete_or_claimed} = Builds.claim(user.id, build.id)

    assert {:error, :publication_refused} =
             Builds.publish(user.id, build.id, claimed.claim, artifact())

    assert {:error, :publication_refused} =
             Builds.publish(user.id, build.id, Ecto.UUID.generate(), artifact())

    assert is_nil(Builds.ready(user.id, env.id, compatibility(), opts()))
  end

  test "run only exposes environment build inputs, destroys the builder, then publishes", %{
    user: user,
    env: env
  } do
    {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())
    test = self()

    assert {:ok, ready} =
             Builds.run(user.id, build.id, fn _handle, input ->
               send(test, {:input, input})
               assert Repo.get!(Sandbox, build.sandbox_id).status == "starting"
               {:ok, artifact()}
             end)

    assert_receive {:input, input}
    assert input.build_script == "compile"
    refute Map.has_key?(input, :setup_script)
    refute Map.has_key?(input, :vault)
    refute Map.has_key?(input, :conversation_id)
    assert ready.state == "ready"
    assert ready.wrapped_identity != artifact().identity
    refute inspect(ready) =~ artifact().identity
    assert Repo.get!(Sandbox, build.sandbox_id).status == "terminated"
    assert Quotas.fleet_count(provider: "sprites") == 0
    assert Builds.ready(user.id, env.id, compatibility(), opts()).id == ready.id
    assert {:ok, reused} = Builds.request(user.id, env.id, compatibility(), opts())
    assert reused.id == ready.id
  end

  test "a retired row cannot publish while provider deletion is unconfirmed", %{
    user: user,
    env: env
  } do
    for response <- [{:ok, %{status: :running}}, {:error, :timeout}] do
      stub(Managoat.Sandbox, :destroy, fn _ -> {:error, :timeout} end)
      stub(Managoat.Sandbox, :get, fn _ -> response end)
      {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())

      assert {:error, :build_failed} =
               Builds.run(user.id, build.id, fn _, _ -> {:ok, artifact()} end)

      assert Repo.get!(Sandbox, build.sandbox_id).status == "terminated"
      assert Builds.get(user.id, build.id).state == "failed"
      assert is_nil(Builds.ready(user.id, env.id, compatibility(), opts()))
    end
  end

  test "a failed callback cannot publish and its machine is destroyed", %{user: user, env: env} do
    {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())
    assert {:error, :build_failed} = Builds.run(user.id, build.id, fn _, _ -> raise "SECRET" end)
    assert Builds.get(user.id, build.id).state == "failed"
    assert Repo.get!(Sandbox, build.sandbox_id).status == "terminated"
    assert is_nil(Builds.ready(user.id, env.id, compatibility(), opts()))
  end

  test "generation changes reject an old worker, including change then revert", %{
    user: user,
    env: env
  } do
    {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())
    {:ok, claimed} = Builds.claim(user.id, build.id)
    {:ok, changed} = Environments.update_environment(env, %{build_script: "different"})
    {:ok, reverted} = Environments.update_environment(changed, %{build_script: "compile"})
    assert reverted.build_generation != build.generation

    assert {:error, :publication_refused} =
             Builds.publish(user.id, build.id, claimed.claim, artifact())

    assert {:ok, replacement} = Builds.request(user.id, env.id, compatibility(), opts())
    assert replacement.id != build.id
    assert replacement.fingerprint == build.fingerprint
    Builds.reap()
    assert Builds.get(user.id, build.id).state == "canceled"
    assert Repo.get!(Sandbox, build.sandbox_id).status == "terminated"
  end

  test "boot edits keep reusable identity; policy changes invalidate running work but not artifact identity",
       %{env: env} do
    {:ok, original} = Manifest.binding(env, compatibility())
    {:ok, boot} = Environments.update_environment(env, %{setup_script: "new boot"})
    assert boot.build_generation == env.build_generation
    assert {:ok, ^original} = Manifest.binding(boot, compatibility())
    {:ok, policy} = Environments.update_environment(boot, %{networking_type: "limited"})
    assert policy.build_generation == boot.build_generation
    refute policy.build_policy_revision == boot.build_policy_revision
    assert {:ok, ^original} = Manifest.binding(policy, compatibility())
  end

  test "secret mutations invalidate generation and tenant-keyed fingerprint", %{
    user: user,
    env: env
  } do
    {:ok, original} = Manifest.binding(env, compatibility())
    {:ok, key} = Crypto.load_tenant_key(user.id)

    {:ok, secret} =
      Environments.upsert_secret(env, %{"key" => "BUILD_TOKEN", "value" => "secret"}, key)

    changed = Repo.reload!(env)
    refute changed.build_generation == env.build_generation
    {:ok, binding} = Manifest.binding(changed, compatibility())
    refute binding == original
    {:ok, _} = Environments.delete_secret(changed, secret)
    deleted = Repo.reload!(env)
    refute deleted.build_generation == changed.build_generation
    assert {:ok, ^original} = Manifest.binding(deleted, compatibility())
  end

  test "timeout and deletion revoke selection and retain cleanup intent", %{user: user, env: env} do
    {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())

    Repo.update_all(from(b in Build, where: b.id == ^build.id),
      set: [deadline_at: ~U[2020-01-01 00:00:00Z]]
    )

    Builds.reap()
    assert Builds.get(user.id, build.id).state == "canceled"
    assert Builds.get(user.id, build.id).cleanup_pending
    {:ok, another} = Builds.request(user.id, env.id, compatibility(), opts())
    assert {:ok, _} = Environments.delete_environment(env)
    Builds.reap()
    row = Repo.get!(Build, another.id)
    assert is_nil(row.environment_id)
    assert row.environment_ref == env.id
    assert row.state == "canceled"
    assert Repo.get!(Sandbox, row.sandbox_id).status == "terminated"
  end

  test "unknown base and unresolved repository refs are not buildable", %{user: user, env: env} do
    for input <- [
          Map.delete(compatibility(), "base"),
          Map.put(compatibility(), "provider", "e2b"),
          Map.put(compatibility(), "revisions", ["main"])
        ] do
      assert {:error, :cache_not_buildable} = Builds.request(user.id, env.id, input, opts())
    end
  end

  test "cancel stops a running pipeline and cleanup waits out upload capabilities", %{
    user: user,
    env: env
  } do
    {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())
    parent = self()

    task =
      Task.async(fn ->
        Builds.run(user.id, build.id, fn _, _ ->
          send(parent, {:running, self()})

          receive do
            :never -> {:ok, artifact()}
          end
        end)
      end)

    assert_receive {:running, pid}, 5_000
    monitor = Process.monitor(pid)
    current = Builds.get(user.id, build.id)
    assert {:ok, grant} = Builds.upload_grant(user.id, build.id, current.claim, opts())
    assert DateTime.compare(grant.expires_at, build.deadline_at) != :gt
    assert {:ok, canceled} = Builds.cancel(user.id, build.id, actor: "api")
    assert canceled.state == "canceled"
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    assert {:error, :obsolete_or_claimed} = Task.await(task, 5_000)

    assert {:error, :obsolete_or_claimed} =
             Builds.upload_grant(user.id, build.id, current.claim, opts())

    assert Repo.get!(Sandbox, build.sandbox_id).status == "terminated"
    assert Builds.get(user.id, build.id).cleanup_pending
  end

  test "cleanup survives environment deletion, retries errors and never deletes from a changed store",
       %{user: user, env: env} do
    {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())
    assert {:ok, _} = Builds.cancel(user.id, build.id)
    assert {:ok, _} = Environments.delete_environment(env)
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:deleted, conn.request_path})
      Plug.Conn.send_resp(conn, 204, "")
    end)

    cleanup_opts = [
      store: Keyword.put(opts()[:store], :request_options, plug: {Req.Test, __MODULE__})
    ]

    Builds.reap(cleanup_opts)
    refute_received {:deleted, _}

    Repo.update_all(from(b in Build, where: b.id == ^build.id),
      set: [cleanup_after: ~U[2020-01-01 00:00:00Z]]
    )

    cfg = %{opts()[:store][:config] | bucket: "different-store"}
    Builds.reap(store: Keyword.put(cleanup_opts[:store], :config, cfg))
    refute_received {:deleted, _}
    assert Builds.get(user.id, build.id).cleanup_pending
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    Builds.reap(cleanup_opts)
    assert Builds.get(user.id, build.id).cleanup_pending

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE"
      send(parent, {:deleted, conn.request_path})
      Plug.Conn.send_resp(conn, 204, "")
    end)

    Builds.reap(cleanup_opts)
    assert_receive {:deleted, path}
    assert path == "/build-tests/environment-layers/v1/#{user.id}/#{env.id}/#{build.id}.age"
    refute Builds.get(user.id, build.id).cleanup_pending
    Builds.reap(cleanup_opts)
    refute_received {:deleted, _}
  end

  test "policy changes stop an in-flight claim but preserve a completed artifact", %{
    user: user,
    env: env
  } do
    {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())
    {:ok, ready} = Builds.run(user.id, build.id, fn _, _ -> {:ok, artifact()} end)
    {:ok, _} = Environments.update_environment(env, %{networking_type: "limited"})
    Builds.reap()
    assert Builds.ready(user.id, env.id, compatibility(), opts()).id == ready.id
    assert is_nil(Builds.ready(user.id, env.id, compatibility(), store: [config: nil]))

    {:ok, other} =
      Builds.request(user.id, env.id, Map.put(compatibility(), "base", "another-image"), opts())

    {:ok, _} = Builds.claim(user.id, other.id)
    current = Repo.reload!(env)
    {:ok, _} = Environments.update_environment(current, %{networking_type: "unrestricted"})
    Builds.reap()
    assert Builds.get(user.id, other.id).state == "canceled"
  end

  test "a caller crash kills its pipeline and the deadline reaper collects the machine", %{
    user: user,
    env: env
  } do
    {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())
    parent = self()

    {:ok, caller} =
      Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
        Builds.run(user.id, build.id, fn _, _ ->
          send(parent, {:pipeline_worker, self()})

          receive do
            :never -> {:ok, artifact()}
          end
        end)
      end)

    assert_receive {:pipeline_worker, worker}, 5_000
    monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000

    Repo.update_all(from(b in Build, where: b.id == ^build.id),
      set: [deadline_at: ~U[2020-01-01 00:00:00Z]]
    )

    Builds.reap()
    assert Builds.get(user.id, build.id).state == "canceled"
    assert Repo.get!(Sandbox, build.sandbox_id).status == "terminated"
  end

  test "expired artifacts lose access and their wrapped key before a replacement build", %{
    user: user,
    env: env
  } do
    {:ok, build} = Builds.request(user.id, env.id, compatibility(), opts())
    {:ok, _} = Builds.run(user.id, build.id, fn _, _ -> {:ok, artifact()} end)

    Repo.update_all(from(b in Build, where: b.id == ^build.id),
      set: [expires_at: ~U[2020-01-01 00:00:00Z]]
    )

    assert is_nil(Builds.ready(user.id, env.id, compatibility(), opts()))
    assert {:error, :build_obsolete} = Builds.request(user.id, env.id, compatibility(), opts())
    Builds.reap()
    expired = Builds.get(user.id, build.id)
    assert expired.state == "expired"
    assert is_nil(expired.wrapped_identity)
    {:ok, replacement} = Builds.request(user.id, env.id, compatibility(), opts())
    refute replacement.id == build.id
  end
end
