defmodule Fountain.SandboxRuntimeMigrationTest do
  use Fountain.DataCase, async: true

  alias Fountain.Repo.Migrations.AddSandboxRuntimeIdentity, as: Migration

  @version 20_260_918_050_000

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20260918050000_add_sandbox_runtime_identity.exs",
      __DIR__
    )
  end

  setup do
    schema = "sandbox_runtime_#{System.unique_integer([:positive])}"
    Repo.query!(~s(CREATE SCHEMA "#{schema}"))
    Repo.query!(~s(SET LOCAL search_path TO "#{schema}", public))

    Repo.query!("""
    CREATE TABLE sandboxes (
      id uuid PRIMARY KEY, user_id uuid, agent_id uuid, environment_id uuid,
      vault_id uuid, mode varchar NOT NULL, status varchar NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE conversations (
      id uuid PRIMARY KEY, sandbox_id uuid, user_id uuid,
      runtime varchar, inserted_at timestamp NOT NULL
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX sandboxes_home_identity_index
    ON sandboxes (user_id, agent_id, environment_id, vault_id) NULLS NOT DISTINCT
    WHERE mode = 'persistent' AND status NOT IN ('terminated', 'failed')
    """)

    %{user: uuid(), agent: uuid(), home: uuid()}
  end

  test "backfill retains newest disk evidence and rollback preserves homes", ctx do
    insert_home(ctx.home, ctx)
    unknown = uuid()
    insert_home(unknown, %{ctx | agent: uuid()})

    for {runtime, at} <- [{"claude", "2026-09-17"}, {"opencode", "2026-09-18"}] do
      Repo.query!(
        "INSERT INTO conversations VALUES ($1, $2, $3, $4, $5::text::timestamp)",
        [uuid(), ctx.home, ctx.user, runtime, at]
      )
    end

    run_migration(:up)
    assert runtime(ctx.home) == "opencode"
    assert runtime(unknown) == nil
    run_migration(:down)
    assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM sandboxes")
    run_migration(:up)

    other = uuid()

    Repo.query!(
      "INSERT INTO sandboxes VALUES ($1, $2, $3, NULL, NULL, 'persistent', 'ready', 'claude')",
      [other, ctx.user, ctx.agent]
    )

    # A second home with the same full identity is refused, even with nil env/vault.
    assert_raise Postgrex.Error, ~r/sandboxes_home_identity_index/, fn ->
      Repo.query!(
        "INSERT INTO sandboxes VALUES ($1, $2, $3, NULL, NULL, 'persistent', 'ready', 'claude')",
        [uuid(), ctx.user, ctx.agent],
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, ~r/sandboxes_home_identity_legacy_index/, fn ->
      run_migration(:down)
    end

    assert runtime(ctx.home) == "opencode"
    assert runtime(other) == "claude"
    assert %{rows: [[3]]} = Repo.query!("SELECT count(*) FROM sandboxes")
  end

  defp insert_home(id, ctx) do
    Repo.query!(
      "INSERT INTO sandboxes VALUES ($1, $2, $3, NULL, NULL, 'persistent', 'ready')",
      [id, ctx.user, ctx.agent]
    )
  end

  defp runtime(id) do
    %{rows: [[runtime]]} = Repo.query!("SELECT runtime FROM sandboxes WHERE id = $1", [id])
    runtime
  end

  defp uuid, do: Ecto.UUID.dump!(Ecto.UUID.generate())

  defp run_migration(direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @version,
      Migration,
      :forward,
      direction,
      direction,
      log: false
    )
  end
end
