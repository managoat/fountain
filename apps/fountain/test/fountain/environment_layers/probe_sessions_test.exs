defmodule Fountain.EnvironmentLayers.ProbeSessionsTest do
  use Fountain.DataCase, async: true
  alias Fountain.Broker.Native.{Session, Sessions}

  test "probe authorization is short-lived, environment-only and scoped on release" do
    user = insert_verified_user()
    env = insert_env(user_id: user.id, cache_enabled: true)
    assert {:ok, session} = Sessions.create_probe(env, [], :unrestricted)
    assert {:ok, found} = Sessions.lookup(session.token)
    assert found.meta["environment_probe"] == env.id
    refute found.meta["conversation_id"]
    row = Repo.one!(Session)
    assert row.probe_environment_id == env.id
    assert is_nil(row.conversation_id) and is_nil(row.environment_layer_build_id)
    assert DateTime.diff(row.expires_at, DateTime.utc_now()) in 118..120
    assert :ok = Sessions.release_probe(Ecto.UUID.generate(), session.token)
    assert {:ok, _} = Sessions.lookup(session.token)
    assert :ok = Sessions.release_probe(user.id, session.token)
    assert :error = Sessions.lookup(session.token)
  end

  test "editing environment generation revokes an existing probe" do
    env = insert_env(user_id: insert_verified_user().id, cache_enabled: true)
    assert {:ok, session} = Sessions.create_probe(env, [], :unrestricted)
    assert {:ok, _} = Fountain.Environments.update_environment(env, %{build_script: "new build"})
    assert :error = Sessions.lookup(session.token)
    assert {:error, :obsolete_probe} = Sessions.create_probe(env, [], :unrestricted)
  end
end
