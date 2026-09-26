defmodule Fountain.AppliedSkillsPerRuntimeMigrationTest do
  use Fountain.DataCase, async: true

  alias Fountain.Repo.Migrations.RecordAppliedSkillsPerRuntime, as: Migration

  @version 20_260_926_150_000

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20260926150000_record_applied_skills_per_runtime.exs",
      __DIR__
    )
  end

  setup do
    schema = "applied_skills_#{System.unique_integer([:positive])}"
    Repo.query!(~s(CREATE SCHEMA "#{schema}"))
    Repo.query!(~s(SET LOCAL search_path TO "#{schema}", public))

    Repo.query!("""
    CREATE TABLE sandboxes (
      id uuid PRIMARY KEY, user_id uuid, runtime varchar, applied_skills jsonb[]
    )
    """)

    Repo.query!("""
    CREATE TABLE conversations (
      id uuid PRIMARY KEY, sandbox_id uuid, user_id uuid,
      runtime varchar, inserted_at timestamp NOT NULL
    )
    """)

    %{user: uuid()}
  end

  test "a single-runtime row round-trips through up and down", ctx do
    claude = insert(ctx, "claude", ~s(ARRAY['{"name":"a","content":"# a"}'::jsonb]))
    empty = insert(ctx, "codex", "ARRAY[]::jsonb[]")
    unrecorded = insert(ctx, "claude", "NULL")

    run_migration(:up)

    assert by_runtime(claude) == %{"claude" => [%{"name" => "a", "content" => "# a"}]}
    # An empty selection is a record ("none of ours"), not an absence.
    assert by_runtime(empty) == %{"codex" => []}
    assert by_runtime(unrecorded) == nil

    run_migration(:down)

    assert list(claude) == [%{"name" => "a", "content" => "# a"}]
    assert list(empty) == []
    assert list(unrecorded) == nil
  end

  test "a legacy row without a runtime is keyed by its newest conversation's", ctx do
    legacy = insert(ctx, nil, ~s(ARRAY['{"name":"a"}'::jsonb]))
    orphan = insert(ctx, nil, ~s(ARRAY['{"name":"b"}'::jsonb]))

    for {runtime, at} <- [{"claude", "2026-09-17"}, {"codex", "2026-09-18"}] do
      Repo.query!(
        "INSERT INTO conversations VALUES ($1, $2, $3, $4, $5::text::timestamp)",
        [uuid(), legacy, ctx.user, runtime, at]
      )
    end

    run_migration(:up)

    assert by_runtime(legacy) == %{"codex" => [%{"name" => "a"}]}
    # No evidence of the runtime: no record, rather than one under a guess.
    assert by_runtime(orphan) == nil

    run_migration(:down)

    assert list(legacy) == [%{"name" => "a"}]
    assert list(orphan) == [%{"name" => "b"}]
  end

  test "a rollback keeps what was recorded since, for the machine's own runtime", ctx do
    home = insert(ctx, "claude", ~s(ARRAY['{"name":"old"}'::jsonb]))
    run_migration(:up)

    Repo.query!(
      """
      UPDATE sandboxes
      SET applied_skills_by_runtime = '{"claude": [{"name": "new"}], "codex": [{"name": "c"}]}'
      WHERE id = $1
      """,
      [home]
    )

    run_migration(:down)
    assert list(home) == [%{"name" => "new"}]
  end

  defp insert(ctx, runtime, skills_sql) do
    id = uuid()

    Repo.query!(
      "INSERT INTO sandboxes VALUES ($1, $2, $3, #{skills_sql})",
      [id, ctx.user, runtime]
    )

    id
  end

  defp by_runtime(id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT applied_skills_by_runtime FROM sandboxes WHERE id = $1", [id])

    value
  end

  defp list(id) do
    %{rows: [[value]]} = Repo.query!("SELECT applied_skills FROM sandboxes WHERE id = $1", [id])
    value
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
