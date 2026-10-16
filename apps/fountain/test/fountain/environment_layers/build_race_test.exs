defmodule Fountain.EnvironmentLayers.BuildRaceTest do
  # Real committed connections are necessary to exercise PostgreSQL row/quota locks.
  use Fountain.DataCase, async: false
  alias Fountain.EnvironmentLayers.{Build, Builds, Store}

  test "simultaneous requests reserve one machine and simultaneous claims have one winner" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      user = insert_verified_user()
      env = insert_env(user_id: user.id, cache_enabled: true)

      compatibility = %{
        "provider" => "sprites",
        "architecture" => "amd64",
        "base" => "image-1",
        "revisions" => []
      }

      options = [
        store: [
          config: %Store.Config{
            endpoint: "https://store.example",
            bucket: "race-tests",
            access_key_id: "test",
            secret_access_key: "test"
          }
        ]
      ]

      try do
        requests = contend(fn -> Builds.request(user.id, env.id, compatibility, options) end)
        ids = Enum.map(requests, fn {:ok, build} -> build.id end)
        assert [id] = Enum.uniq(ids)
        assert Repo.aggregate(from(b in Build, where: b.environment_id == ^env.id), :count) == 1
        claims = contend(fn -> Builds.claim(user.id, id) end)
        assert Enum.count(claims, &match?({:ok, _}, &1)) == 1
        assert Enum.count(claims, &match?({:error, :obsolete_or_claimed}, &1)) == 5

        assert length(
                 Fountain.Audit.list_for_user(user.id,
                   action_prefix: "environment_layer.requested"
                 )
               ) == 1
      after
        Repo.delete_all(from b in Build, where: b.owner_ref == ^user.id)
        Repo.delete_all(from s in Fountain.Conversations.Sandbox, where: s.user_id == ^user.id)
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
        Repo.delete!(env)
        Repo.delete!(user)
      end
    end)
  end

  defp contend(fun) do
    parent = self()

    tasks =
      for _ <- 1..6 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> fun.()
            end
          end)
        end)
      end

    try do
      for _ <- tasks do
        assert_receive {:ready, _}, 5_000
      end

      Enum.each(tasks, &send(&1.pid, :go))
      Enum.map(tasks, &Task.await(&1, 10_000))
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    end
  end
end
