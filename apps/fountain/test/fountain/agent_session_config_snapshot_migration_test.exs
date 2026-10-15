defmodule Fountain.AgentSessionConfigSnapshotMigrationTest do
  @moduledoc """
  #2664's backfill: every conversation keeps its agent's current
  session_config, so its next turn asks for what the previous release would
  have asked for. Run against tables of its own in a private schema.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Repo.Migrations.SnapshotAgentSessionConfig, as: Migration

  @version 20_261_015_130_000

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261015130000_snapshot_agent_session_config.exs",
      __DIR__
    )
  end

  setup do
    schema = "agent_session_config_#{System.unique_integer([:positive])}"
    Repo.query!(~s(CREATE SCHEMA "#{schema}"))
    Repo.query!(~s(SET LOCAL search_path TO "#{schema}", public))

    Repo.query!(
      "CREATE TABLE agents (id uuid PRIMARY KEY, session_config jsonb NOT NULL DEFAULT '{}')"
    )

    Repo.query!("CREATE TABLE conversations (id uuid PRIMARY KEY, agent_id uuid)")
    :ok
  end

  test "copies each agent's config onto its conversations, without a harness mode" do
    tuned = agent(%{"effort" => "high", "fast" => true})
    legacy = agent(%{"mode" => "bypassPermissions", "collaboration_mode" => "plan", "x" => "y"})
    plain = agent(%{})

    a = conversation(tuned)
    b = conversation(tuned)
    c = conversation(legacy)
    d = conversation(plain)
    orphan = conversation(nil)

    run_migration(:up)

    assert snapshot(a) == %{"effort" => "high", "fast" => true}
    assert snapshot(b) == %{"effort" => "high", "fast" => true}
    assert snapshot(c) == %{"x" => "y"}
    assert snapshot(d) == %{}
    assert snapshot(orphan) == %{}

    run_migration(:down)

    refute "agent_session_config" in columns()
  end

  defp agent(config) do
    id = Ecto.UUID.generate()
    Repo.query!("INSERT INTO agents VALUES ($1::uuid, $2)", [dump(id), config])
    id
  end

  defp conversation(agent_id) do
    id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO conversations VALUES ($1, $2)", [
      dump(id),
      agent_id && dump(agent_id)
    ])

    id
  end

  defp snapshot(id) do
    %{rows: [[config]]} =
      Repo.query!("SELECT agent_session_config FROM conversations WHERE id = $1", [dump(id)])

    config
  end

  defp columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
       WHERE table_schema = current_schema() AND table_name = 'conversations'
      """)

    List.flatten(rows)
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

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
