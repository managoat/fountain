defmodule FountainGoogle.Router do
  @moduledoc """
  The extension's one route, mounted by the host at `/api/mcp/gmail`.

  No pipeline. `FountainWeb.Plugs.ExtensionDispatch` forwards here from inside
  the host's `[:accepts_json, :api]` scope, so content negotiation, the rate
  limit, `TenantAPIAuth` and the request audit have already run and
  `conn.assigns.current_user` is set — the conversation's owner, because the
  sandbox authenticates with its callback token. An extension gets a mount
  point, not a door of its own.

  The path is written relative to the mount, so
  `"/:conversation_id/:connection_id"` is served at
  `/api/mcp/gmail/:conversation_id/:connection_id`: the same path it had as a
  core route, which is the URL `FountainGoogle.conversation_mcp_servers/2`
  hands a sandbox at every turn.

  The host's own `/api/mcp/team/:id`, `/api/mcp/team-comms/:id` and
  `/api/mcp/caller/:id` are core routes declared before the extension
  dispatch, so they win; `Fountain.Extensions.validate!/0` refuses a mount that
  overlaps any of them, and `/mcp/gmail` overlaps none.
  """
  use Phoenix.Router

  scope "/" do
    post "/:conversation_id/:connection_id", FountainGoogle.McpController, :handle
  end
end
