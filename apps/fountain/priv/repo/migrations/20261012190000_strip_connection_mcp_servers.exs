defmodule Fountain.Repo.Migrations.StripConnectionMcpServers do
  use Ecto.Migration

  @moduledoc """
  Connections are removed (simplify 5/5). An agent's `mcp_servers` could name
  one instead of a server, either alone (`%{"gmail" => %{"connection" => id}}`,
  which the Google extension served) or beside a URL (a remote server the
  broker attached the connection's token to). Nothing resolves either shape
  now, and passed through as written each would reach the runtime as a server
  with nothing to start. So every entry that names a connection is removed
  from the agents that hold one, which is what the previous release already
  did at spawn for a connection that was gone. The agent's other servers stay.

  The `connections` and `connection_providers` tables are NOT dropped here.
  The previous release, serving during a rolling deploy, reads `connections`
  on every brokered provision and turn kick (`Fountain.Connections` through
  `Fountain.Conversations.Egress`), so dropping it under that release would
  fail those conversations. The drop is a follow-up migration, a release
  later; until then the rows are unread.

  `agent_versions` snapshots are history and keep what they recorded; the
  agent changeset refuses a connection entry, so restoring one says why.
  """

  def up do
    execute """
    UPDATE agents
       SET mcp_servers = (
             SELECT COALESCE(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
               FROM jsonb_each(agents.mcp_servers) AS e(key, value)
              WHERE NOT (jsonb_typeof(e.value) = 'object' AND e.value ? 'connection')
           ),
           updated_at = now()
     WHERE jsonb_typeof(mcp_servers) = 'object'
       AND EXISTS (
             SELECT 1
               FROM jsonb_each(agents.mcp_servers) AS e(key, value)
              WHERE jsonb_typeof(e.value) = 'object' AND e.value ? 'connection'
           )
    """
  end

  # Data, not shape: which entries named which connection is not recorded, and
  # nothing could serve them again.
  def down, do: :ok
end
