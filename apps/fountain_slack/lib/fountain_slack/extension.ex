defmodule FountainSlack.Extension do
  @moduledoc """
  The one module the host knows about (ADR 0043, ADR 0054, #2152).

  `config :fountain, :extensions, [..., FountainSlack.Extension]` is the whole
  of Fountain's knowledge of the Slack connection. Nothing under
  `apps/fountain/lib` names this module or any other `FountainSlack.*` one —
  `Fountain.ExtensionGuardTest` fails the build if that stops being true.

  ## Two callbacks

  A connection provider is data the host reads, so this extension needs no
  router, no migration, no process and no cron. It implements
  `connection_providers/0`, the callback ADR 0054 added for exactly this, and
  `docs/0` for the page that describes the provider; everything else is the
  contribute-nothing default from `use Fountain.Extension`.

  The extension contributes the provider, never the flow (ADR 0054 decision 2).
  Slack's two quirks — the request goes in `user_scope`, and the token comes
  back under `authed_user` — are fields on the struct (`authorize_params`,
  `token_body_nest`, #2152 step 1), so `Fountain.Connections.OAuth` drives
  this provider exactly as it drives a tenant's own, the token is stored,
  encrypted and brokered by core, and no token ever passes through this
  application.
  """

  use Fountain.Extension, id: :slack

  @doc """
  The Slack provider, `FountainSlack.Provider.provider/0`, built from
  `config :fountain_slack` on every call so an operator's client and scope
  settings are read as they stand.
  """
  @impl true
  def connection_providers, do: [FountainSlack.Provider.provider()]

  @doc "This extension's slice of the manual: the `slack (connection)` page."
  @impl true
  def docs, do: FountainSlack.Docs
end
