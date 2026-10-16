defmodule Fountain.EnvironmentLayers.RestoreTest do
  use Fountain.DataCase, async: true
  use Mimic
  alias Fountain.EnvironmentLayers.{Builds, Envelope, Helper, Pipeline, Probe, Restore, Store}
  alias Managoat.Sandbox
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id, cache_enabled: true)
    handle = %Handle{provider: :sprites, name: "restore-test"}

    compatibility = %{
      "provider" => "sprites",
      "architecture" => "amd64",
      "base" => "sha256:" <> String.duplicate("b", 64),
      "revisions" => []
    }

    build = %{
      id: Ecto.UUID.generate(),
      binding: %{},
      wrapped_identity: "wrapped",
      ciphertext_sha256: String.duplicate("a", 64),
      ciphertext_bytes: 123
    }

    stub(Store, :identity, fn -> {:ok, "store"} end)

    stub(Probe, :run, fn ^handle, current ->
      assert current.id == env.id
      {:ok, compatibility}
    end)

    stub(Builds, :ready, fn uid, eid, ^compatibility ->
      assert uid == user.id and eid == env.id
      build
    end)

    stub(Store, :grant, fn uid, eid, id, :get ->
      assert uid == user.id and eid == env.id and id == build.id
      {:ok, %{url: "https://store.example/object?capability", origin: "https://store.example"}}
    end)

    %{user: user, env: env, handle: handle, compatibility: compatibility, build: build}
  end

  test "identity is unwrapped only after ciphertext fetch and confirmed narrow floor", c do
    parent = self()

    stub(Sandbox, :apply_network_policy, fn _, policy ->
      send(parent, {:floor, policy.allow})
      :ok
    end)

    expect(Helper, :call, fn _, %{operation: "fetch"} = request ->
      refute Map.has_key?(request, :identity)
      assert_receive {:floor, [_, "store.example"]}
      send(parent, :fetched)
      {:ok, %{}}
    end)

    expect(Envelope, :unwrap, fn _, _, _, _, _ ->
      assert_receive :fetched
      assert_receive {:floor, [_broker]}
      {:ok, "private-artifact-key"}
    end)

    expect(Helper, :call, fn _, %{operation: "restore", identity: "private-artifact-key"} ->
      {:ok, %{}}
    end)

    assert {:warm, [], %{bytes: 123, fetch_ms: _, probe_ms: _, authenticate_extract_ms: _}} =
             Restore.attempt(c.handle, c.user.id, c.env, nil)
  end

  test "failed floor never releases a key and requests a fresh cold machine", c do
    stub(Sandbox, :apply_network_policy, fn _, policy ->
      if length(policy.allow) == 1, do: {:error, :unavailable}, else: :ok
    end)

    stub(Helper, :call, fn _, %{operation: "fetch"} -> {:ok, %{}} end)
    reject(&Envelope.unwrap/5)
    assert :retry_fresh = Restore.attempt(c.handle, c.user.id, c.env, nil)
  end

  test "cache miss enqueues the exact compatibility and continues cold", c do
    stub(Builds, :ready, fn _, _, _ -> nil end)

    expect(Pipeline, :enqueue, fn uid, eid, compatibility ->
      assert uid == c.user.id and eid == c.env.id and compatibility == c.compatibility
      {:ok, :queued}
    end)

    reject(&Helper.call/2)
    assert :cold = Restore.attempt(c.handle, c.user.id, c.env, nil)
  end

  test "disabled and non-Sprites environments do no probing", c do
    reject(&Probe.run/2)
    assert :cold = Restore.attempt(c.handle, c.user.id, %{c.env | cache_enabled: false}, nil)
    assert :cold = Restore.attempt(%{c.handle | provider: :e2b}, c.user.id, c.env, nil)
    assert :cold = Restore.attempt(c.handle, c.user.id, nil, nil)
  end

  test "wrong tenant refuses before probing", c do
    reject(&Probe.run/2)
    assert :retry_fresh = Restore.attempt(c.handle, Ecto.UUID.generate(), c.env, nil)
  end

  test "obsolete artifact after download never receives a key", c do
    expect(Builds, :ready, fn _, _, _ -> c.build end)
    expect(Builds, :ready, fn _, _, _ -> nil end)
    stub(Sandbox, :apply_network_policy, fn _, _ -> :ok end)
    stub(Helper, :call, fn _, %{operation: "fetch"} -> {:ok, %{}} end)
    reject(&Envelope.unwrap/5)
    assert :retry_fresh = Restore.attempt(c.handle, c.user.id, c.env, nil)
  end
end
