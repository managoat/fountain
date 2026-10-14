defmodule Fountain.DropHomeColumnsMigrationTest do
  @moduledoc """
  The contract step after persistent homes and mixed-runtime guests went
  (ADR 0073): the columns, the home index and the departed-conversation
  trigger are gone, and `down/0` puts the shape back.

  `async: false`: the migration's DDL locks `sandboxes` and `agents` until
  the test's transaction rolls back.
  """

  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog

  alias Fountain.Repo
  alias Fountain.Repo.Migrations.DropHomeColumns, as: Migration

  @version 20_261_014_191_000

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261014191000_drop_home_columns.exs",
      __DIR__
    )
  end

  @sandbox_columns ~w(mode runtime codex_inference_source codex_peer_homes departed_conversations)

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
        [table]
      )

    List.flatten(rows)
  end

  defp exists?(sql) do
    %{rows: [[n]]} = Repo.query!(sql)
    n > 0
  end

  defp run(direction) do
    capture_log(fn ->
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
    end)
  end

  test "down puts the shape back, and up takes it away again" do
    # The suite's database is migrated, so the columns are already gone.
    refute Enum.any?(@sandbox_columns, &(&1 in columns("sandboxes")))
    refute "sandbox_mode" in columns("agents")

    run(:down)
    assert Enum.all?(@sandbox_columns, &(&1 in columns("sandboxes")))
    assert "sandbox_mode" in columns("agents")

    assert exists?(
             "SELECT count(*) FROM pg_indexes WHERE indexname = 'sandboxes_home_identity_index'"
           )

    run(:up)
    refute Enum.any?(@sandbox_columns, &(&1 in columns("sandboxes")))
    refute "sandbox_mode" in columns("agents")

    refute exists?(
             "SELECT count(*) FROM pg_indexes WHERE indexname = 'sandboxes_home_identity_index'"
           )

    refute exists?(
             "SELECT count(*) FROM pg_trigger WHERE tgname = 'record_departed_conversation'"
           )

    # A sandbox and an agent still insert without the columns.
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    assert insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
  end
end
