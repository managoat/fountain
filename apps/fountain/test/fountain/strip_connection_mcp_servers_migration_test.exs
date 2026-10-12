defmodule Fountain.StripConnectionMcpServersMigrationTest do
  @moduledoc """
  Connections are removed (simplify 5/5): every `mcp_servers` entry that names
  a connection leaves the agent, and nothing else about the agent changes.
  Rows are seeded with raw SQL, because the agent changeset now refuses the
  shape being cleaned up.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Repo
  alias Fountain.Repo.Migrations.StripConnectionMcpServers, as: Migration

  @version 20_261_012_190_000

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261012190000_strip_connection_mcp_servers.exs",
      __DIR__
    )
  end

  test "removes the entries that name a connection and keeps every other server" do
    user = insert_verified_user()
    id = Ecto.UUID.generate()

    mixed =
      insert_agent(user_id: user.id, mcp_servers: %{"fs" => %{"command" => "npx"}})

    plain =
      insert_agent(user_id: user.id, mcp_servers: %{"remote" => %{"url" => "https://x.example"}})

    only = insert_agent(user_id: user.id)

    set_servers(mixed, %{
      "fs" => %{"command" => "npx"},
      "gmail" => %{"connection" => id},
      "linear" => %{"type" => "http", "url" => "https://mcp.linear.app/mcp", "connection" => id}
    })

    set_servers(only, %{"gmail" => %{"connection" => id}})

    run_migration()

    assert servers(mixed) == %{"fs" => %{"command" => "npx"}}
    assert servers(plain) == %{"remote" => %{"url" => "https://x.example"}}
    assert servers(only) == %{}
  end

  test "the agent changeset refuses a connection entry" do
    changeset =
      Fountain.Agents.Agent.changeset(%Fountain.Agents.Agent{}, %{
        "mcp_servers" => %{"gmail" => %{"connection" => Ecto.UUID.generate()}}
      })

    assert {"gmail: connections were removed; give the server a command or a url", _} =
             changeset.errors[:mcp_servers]
  end

  defp set_servers(agent, servers) do
    Repo.query!("UPDATE agents SET mcp_servers = $1 WHERE id = $2", [
      servers,
      Ecto.UUID.dump!(agent.id)
    ])
  end

  defp servers(agent) do
    %{rows: [[servers]]} =
      Repo.query!("SELECT mcp_servers FROM agents WHERE id = $1", [Ecto.UUID.dump!(agent.id)])

    servers
  end

  defp run_migration do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @version,
      Migration,
      :forward,
      :up,
      :up,
      log: false
    )
  end
end
