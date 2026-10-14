defmodule Fountain.CollapseInferenceCredentialSetsMigrationTest do
  @moduledoc """
  `20261014120000`: every account ends with one credential record, its
  default, and agents that named a deleted set fall back to none.

  Rows are seeded with raw SQL in the set-era shape, because the schema no
  longer maps `name` or `is_default`. The follow-up migration that drops those
  columns removes this file with them.
  """

  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog

  alias Fountain.Repo
  alias Fountain.Repo.Migrations.CollapseInferenceCredentialSets, as: Migration

  @version 20_261_014_120_000

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261014120000_collapse_inference_credential_sets.exs",
      __DIR__
    )
  end

  test "keeps the default, promotes the oldest where there is none, drops the rest" do
    several = insert_verified_user()
    default = row(several, "Default", true, 60)
    extra = row(several, "Second", false, 120)

    no_default = insert_verified_user()
    oldest = row(no_default, "Old", false, 120)
    _newer = row(no_default, "New", false, 60)

    single = insert_verified_user()
    only = row(single, "Default", true, 60)

    agent = insert_agent(user_id: several.id)

    Repo.query!("UPDATE agents SET inference_credential_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(extra),
      Ecto.UUID.dump!(agent.id)
    ])

    capture_log(fn -> run(:up) end)

    assert rows(several) == [{default, true}]
    assert rows(no_default) == [{oldest, true}]
    assert rows(single) == [{only, true}]

    assert %{rows: [[nil]]} =
             Repo.query!("SELECT inference_credential_id FROM agents WHERE id = $1", [
               Ecto.UUID.dump!(agent.id)
             ])
  end

  test "a row inserted without the set columns is a default set named Default" do
    capture_log(fn -> run(:up) end)
    user = insert_verified_user()

    assert %{rows: [["Default", true]]} =
             Repo.query!(
               """
               INSERT INTO inference_credentials (id, user_id, inserted_at, updated_at)
               VALUES (gen_random_uuid(), $1, now(), now())
               RETURNING name, is_default
               """,
               [Ecto.UUID.dump!(user.id)]
             )
  end

  defp row(user, name, default?, seconds_ago) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO inference_credentials (id, user_id, name, is_default, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, $3, now() - make_interval(secs => $4), now())
        RETURNING id
        """,
        [Ecto.UUID.dump!(user.id), name, default?, seconds_ago * 1.0]
      )

    Ecto.UUID.load!(id)
  end

  defp rows(user) do
    Repo.query!(
      "SELECT id, is_default FROM inference_credentials WHERE user_id = $1 ORDER BY inserted_at",
      [Ecto.UUID.dump!(user.id)]
    ).rows
    |> Enum.map(fn [id, flag] -> {Ecto.UUID.load!(id), flag} end)
  end

  defp run(direction) do
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
