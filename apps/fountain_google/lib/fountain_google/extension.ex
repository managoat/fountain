defmodule FountainGoogle.Extension do
  @moduledoc """
  The one module the host knows about (ADR 0043, #2152).

  `config :fountain, :extensions, [..., FountainGoogle.Extension]` is the whole
  of Fountain's knowledge of the Gmail tools. Nothing under `apps/fountain/lib`
  names this module or any other `FountainGoogle.*` one —
  `Fountain.ExtensionGuardTest` fails the build if that stops being true.

  ## Three callbacks, and no tenth

  ADR 0043 decision 3 specified this extension against `api_mounts/0` and
  `conversation_mcp_servers/2` before it was built, as the design that showed
  the seam needed no tenth entry. Built, it uses those two and `docs/0`, and
  inherits the contribute-nothing default for the other seven:

    * `api_mounts/0` — one mount, `/mcp/gmail`, so the endpoint keeps the path
      it had as a core route.
    * `conversation_mcp_servers/2` — the Gmail server, for a conversation whose
      agent names an active Google connection and no URL beside it.
    * `docs/0` — the `fountain-gmail` manual page.

  No migration: the connection rows are the host's (`Fountain.Connections`),
  and this extension holds no state of its own. No OpenAPI operation either —
  the one route is a JSON-RPC transport a sandbox posts to, which was never in
  the spec as a core route and is not now.
  """

  use Fountain.Extension, id: :google

  @doc """
  The one path this extension serves: `/api/mcp/gmail`.

  `/api/mcp/gmail/:conversation_id/:connection_id` is written relative to it
  in `FountainGoogle.Router`, so the endpoint is served exactly where it was as
  a core route. Not under a `/google` prefix, because the host's own MCP
  transports live under `/api/mcp/` and a sandbox that was told this URL at
  one turn must find it at the next.
  """
  @impl true
  def api_mounts, do: [{"/mcp/gmail", FountainGoogle.Router}]

  @doc """
  Nothing. The router's one route has no `open_api_operation/1`, so
  `Fountain.Extensions.mounted_paths/2` yields an empty map — asserted in
  `FountainGoogle.BoundaryTest` so that a documented operation added here
  shows up as a change to the published contract rather than slipping in.
  """
  @impl true
  def openapi_paths, do: Fountain.Extensions.mounted_paths("/mcp/gmail", FountainGoogle.Router)

  @doc """
  The Gmail server, for a conversation whose agent names a Google connection.

  `FountainGoogle.conversation_mcp_servers/2` decides which entries qualify and
  what the sandbox is told; the callback token is the host's
  conversation-scoped credential, unchanged.
  """
  @impl true
  defdelegate conversation_mcp_servers(conversation_id, callback_token), to: FountainGoogle

  @doc """
  The one manual page this extension owns.

  It kept its slug across the move, so `/docs/catalog/mcp-servers/fountain-gmail`
  is the URL it always was — on a bundled distribution. A core one serves no
  such page, and its sidebar never names it.
  """
  @impl true
  def docs, do: FountainGoogle.Docs
end
