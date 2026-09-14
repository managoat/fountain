defmodule Fountain.Extension do
  @moduledoc """
  The behaviour a first-party Fountain extension implements (ADR 0043, #1505).

  An extension is an OTP application that depends on `:fountain`, is compiled
  into the release, and is switched on by naming its extension module in
  configuration:

      config :fountain, :extensions, [MyExt.Extension]

  The host reaches an extension **only** through the callbacks below. Nothing
  in `apps/fountain` names an extension module, and an extension never
  registers itself with the host at runtime: the configured list is the whole
  truth, read at boot by `Fountain.Extensions.validate!/0` and per call
  everywhere else.

  ## The callbacks

    * `c:id/0` — a stable atom. Namespaces logs and error payloads, and is what
      an operator sees when configuration is wrong.
    * `c:enabled?/0` — whether this deployment has what the extension needs
      (a binary on disk, a credential, a flag). An installed extension that
      answers `false` contributes nothing and is never called again; that is a
      supported state, not an error.
    * `c:api_mounts/0` — the paths under `/api` this extension serves and the
      Plug behind each. Mounted **inside** the host's `:api` pipeline by
      `FountainWeb.Plugs.ExtensionDispatch`, so authentication, the rate limit,
      `conn.assigns.current_user` and the request audit are host-owned and an
      extension cannot opt out of them by choosing a path.
    * `c:conversation_mcp_servers/2` — the MCP servers this extension serves
      back to a conversation's sandbox. The one callback on the turn's hot
      path. Return `[]` for a conversation the extension does not claim.
    * `c:migrations/0` — migration directories in the extension's own `priv`,
      appended after the core's at every migration entrance.
    * `c:openapi_paths/0` — the extension's OpenAPI paths, absolute. The host
      refuses any that falls outside `c:api_mounts/0`, so an extension cannot
      describe a path it does not serve.
    * `c:admin_overview/0` and `c:admin_user_columns/0` — read-only numbers for
      the operator console. Data, never markup, and never a way to reach into a
      core page.
    * `c:oban_cron/0` — periodic jobs, merged into the host's Oban cron so a
      core-only release never names a worker it does not carry.
    * `c:docs/0` — a `Managoat.Docs` instance whose pages and nav join the
      manual at `/docs`. Its pages are embedded in the extension's own module,
      so a core distribution serves a manual that never mentions them.
    * `c:connection_providers/0` — the connection providers this extension
      owns, as config-backed `Fountain.Connections.Provider` structs. The host
      lists them beside its own platform providers, reserves their slugs and
      drives them with the one OAuth client (ADR 0054).

  ## Supervision is not a callback

  An extension starts its own processes from its own `Application.start/2`.
  Because it depends on `:fountain`, OTP starts the host first and stops it
  last, so the Repo is up before the extension's tree and the extension's tree
  is down before the Repo goes away. The host aggregates no extension children
  and a crash in an extension's supervisor cannot reach the host's. ADR 0043
  originally gave this a `children/1` callback; #1505 replaced it with the
  application dependency, which buys the same ordering for free and one
  strictly better thing: an extension's tree starts *after* the Endpoint, which
  is what a harness talking HTTP back to this server actually needs.

  ## Defaults

  `use Fountain.Extension, id: :thing` implements every callback with a
  contribute-nothing default, so an extension writes only the ones it uses:

      defmodule MyExt.Extension do
        use Fountain.Extension, id: :my_ext

        @impl true
        def api_mounts, do: [{"/my-ext", MyExt.Router}]
      end

  The behaviour stays total on purpose — there are no optional callbacks to
  check for at a call site.
  """

  @typedoc "A Plug module, or a Plug module with its options."
  @type plug :: module() | {module(), term()}

  @doc "A stable identifier for this extension. Never changes once shipped."
  @callback id() :: atom()

  @doc """
  Whether this deployment can run the extension. Asked before every dispatch,
  so keep it cheap; anything that touches the filesystem or the network belongs
  behind a value read once at the extension's own boot.
  """
  @callback enabled?() :: boolean()

  @doc """
  The paths under `/api` this extension serves, and the Plug behind each.

  Each entry is `{"/segment[/segment...]", plug}` — an absolute path relative to
  `/api`, lowercase, and static. More than one is allowed, and the Buzz
  extension needs it: ADR 0043's compatibility promise keeps both of its
  existing paths and they are not nested under one another.

      def api_mounts do
        [{"/my-ext", MyExt.Router}, {"/mcp/my-ext", MyExt.McpRouter}]
      end

  Dispatch takes the **longest** declared mount that prefixes the request, trims
  it from `path_info` onto `script_name`, and calls that mount's plug — so an
  extension's routes are written relative to their own mount and its path
  helpers still generate correct URLs.

  `Fountain.Extensions.validate!/0` refuses, at boot: a malformed segment, a
  mount two extensions both declare, and a mount that overlaps a core route in
  either direction (a mount that is a prefix of a core path, or a core path
  whose static part is a prefix of the mount). Overlap is refused rather than
  resolved because the host declares its dispatch last, so a core route always
  wins and an overlapping mount would be a route that silently serves nothing.

  Returns `[]` for an extension with no HTTP surface.
  """
  @callback api_mounts() :: [{path :: String.t(), plug()}]

  @doc """
  Migration directories this extension owns, as `{otp_app, path_under_priv}`.

  Resolved through `:code.priv_dir/1`, so the same declaration works in the
  umbrella, in a hex dependency and in a release. Appended to the core's path at
  every migration entrance — the boot migrator, `Fountain.Release.migrate/0` and
  `mix ecto.migrate` — always after it, so core ordering never depends on an
  extension being present.

  **Version numbers are global.** Every extension's migrations are recorded in
  Fountain's one `schema_migrations` table, so a version number an extension
  picks must not collide with the core's or another extension's. Ecto raises on
  a duplicate version across the path set, which turns a collision into a failed
  migrate rather than a skipped migration. Keep using timestamps.

  A declared directory that does not exist is a boot failure
  (`Fountain.Extensions.validate!/0`), not a silently empty path set.
  """
  @callback migrations() :: [{otp_app :: atom(), path_under_priv :: String.t()}]

  @doc """
  This extension's OpenAPI paths, absolute.

  `Fountain.Extensions.mounted_paths/2` turns a router's paths into these,
  which is the whole implementation for an extension with a Phoenix router:

      def openapi_paths do
        Fountain.Extensions.mounted_paths("/my-ext", MyExt.Router)
      end

  The host refuses a path that falls outside `c:api_mounts/0`, so an extension
  cannot describe a path it does not serve, however it built the map.

  This callback exists because a forward is opaque to the spec:
  `OpenApiSpex.Paths.from_router/1` reads `router.__routes__()`, where the
  host's `forward` to `FountainWeb.Plugs.ExtensionDispatch` is one route whose
  plug exports no `open_api_operation/1` — so it is filtered out entirely and
  the mounted routes are invisible. Verified in
  `deps/open_api_spex/lib/open_api_spex/path_item.ex`.

  Schema components are resolved from the returned operations. A component title
  that collides with a core one, or with another extension's, raises when the
  spec is built rather than letting the last writer win.
  """
  @callback openapi_paths() :: OpenApiSpex.Paths.t()

  @doc """
  The MCP servers to serve back to this conversation's sandbox, in the shape
  `Managoat.Runtimes` puts on `session/new`.

  `callback_token` is the conversation-scoped credential
  (`Fountain.Conversations.CallbackKey`) the sandbox will authenticate the tool
  calls with. It is not a standing user key, and an extension must not mint or
  substitute one.

  Called on every turn kick, for every conversation, once per installed
  extension. Return `[]` — cheaply — for a conversation this extension has
  nothing to do with. A raise here is contained by
  `Fountain.Extensions.conversation_mcp_servers/2` and costs this extension's
  servers only, never the host's.
  """
  @callback conversation_mcp_servers(conversation_id :: String.t(), callback_token :: String.t()) ::
              [map()]

  @doc """
  Read-only figures for the admin overview, as `{label, value}` pairs.

  The operator console is a core surface and stays one: an extension hands the
  host **data**, never markup, and has no way to reach into a page. The host
  renders each pair as one stat tile beside its own, or renders none if the
  extension returns `[]`.

  `opts` may carry `:navigate` (a path the tile links to) and `:note` (a line
  under the number). Still data: the host owns every element of the markup.

  This callback exists because #1017 and #1519 put two Buzz figures on the admin
  pages — the running-harness count and the per-account identity count — and a
  hosted agent is a standing OS process no sandbox meter reports. Deleting them
  to move Buzz would have removed the only view an operator has of what they are
  paying for. Called on a page render, so it must be one query or none.
  """
  @callback admin_overview() :: [
              {label :: String.t(), value :: term()}
              | {label :: String.t(), value :: term(), opts :: keyword()}
            ]

  @doc """
  Extra columns for the admin users table, as `{header, %{user_id => cell}}`.

  A `cell` is a bare value, or `%{value: term(), alert?: boolean()}` when the
  extension wants the number highlighted — a hosted-agent count at its ceiling,
  say. The extension owns that policy because the host does not know what a
  ceiling means for it; the host owns the colour.

  One grouped query per column, not one per row: the map is built once for the
  page. A user with no entry renders as `0`. Return `[]` to add no columns.
  """
  @callback admin_user_columns() :: [{header :: String.t(), %{String.t() => term()}}]

  @doc """
  Oban cron entries this extension wants scheduled, as `{crontab, worker}`.

  Merged into the host's `Oban.Plugins.Cron` at boot by
  `Fountain.Application`, because the alternative is a core-only release whose
  `config :fountain, Oban` names a worker module it does not carry — which is a
  crash on start, not a missing feature.

  Oban-shaped on purpose. An extension shares the host's Repo, its `oban_jobs`
  table and its queues; a second Oban instance to avoid naming the first would
  be pretending a coupling away rather than removing it.
  """
  @callback oban_cron() :: [{crontab :: String.t(), worker :: module()}]

  @doc """
  This extension's manual: a module that `use Managoat.Docs`, or `nil`.

  The pages are embedded in the extension's own module at ITS compile time, so
  a core distribution has neither the pages nor a nav entry naming them — the
  manual a core image serves is complete rather than pruned, which is the
  property that made this a callback instead of a build-time copy step.

      defmodule MyExt.Docs do
        use Managoat.Docs,
          root: Path.expand("../..", __DIR__),
          docs_dir: "docs",
          nav: "docs/nav.yml",
          mount: "/docs"
      end

  The mount must be the host's `/docs`, so a page keeps the URL it had as a
  core page. `Fountain.Extensions.validate!/0` refuses a different mount, and
  refuses a slug the core manual already serves — two pages at one URL is a
  page nobody can reach.

  A nav section whose title matches one of the host's appends its pages to
  that section rather than starting a second one with the same name, so a
  moved page stays where a reader last saw it.
  """
  @callback docs() :: module() | nil

  @doc """
  The connection providers this extension owns (ADR 0054, #2152).

  Each is a `%Fountain.Connections.Provider{}` built from configuration, the
  shape a platform provider has always had: `user_id: nil`, its slug as its
  `id`, a `kind` of `oauth2` or `mcp`, and everything the OAuth client needs
  on the struct — `authorize_params` and `token_body_nest` included. The host
  lists them after its own platform providers, in configured order; refuses a
  tenant provider that takes one of their slugs; and drives them with
  `Fountain.Connections.OAuth`. An extension contributes the *provider*, never
  the flow, so the token never passes through extension code.

  A provider whose deployment has no client is still listed, with
  `Fountain.Connections.OAuth.configured?/1` false, so a console can say "not
  available here" rather than not knowing the provider could exist. By
  convention the extension reads `<SLUG>_OAUTH_CLIENT_ID` / `_SECRET` /
  `_SCOPES` into its own config namespace and builds the struct from there;
  that is the env var the console names beside an unconfigured row.

  Called on a page render and at every connect and refresh, so it must be
  cheap: build from config, no IO. `Fountain.Extensions.validate!/0` refuses,
  at boot, an entry that is not a provider struct, one carrying a `user_id`,
  one whose `id` is not its slug, a slug of the wrong shape or kind, and a slug
  the host or another extension already owns. A raise here is contained by
  `Fountain.Extensions.connection_providers/0` and costs this extension's
  providers only, never the host's.
  """
  @callback connection_providers() :: [Fountain.Connections.Provider.t()]

  @doc false
  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)

    quote do
      @behaviour Fountain.Extension

      @impl Fountain.Extension
      def id, do: unquote(id)

      @impl Fountain.Extension
      def enabled?, do: true

      @impl Fountain.Extension
      def api_mounts, do: []

      @impl Fountain.Extension
      def conversation_mcp_servers(_conversation_id, _callback_token), do: []

      @impl Fountain.Extension
      def migrations, do: []

      @impl Fountain.Extension
      def openapi_paths, do: %{}

      @impl Fountain.Extension
      def admin_overview, do: []

      @impl Fountain.Extension
      def admin_user_columns, do: []

      @impl Fountain.Extension
      def oban_cron, do: []

      @impl Fountain.Extension
      def docs, do: nil

      @impl Fountain.Extension
      def connection_providers, do: []

      defoverridable enabled?: 0,
                     api_mounts: 0,
                     conversation_mcp_servers: 2,
                     migrations: 0,
                     openapi_paths: 0,
                     admin_overview: 0,
                     admin_user_columns: 0,
                     oban_cron: 0,
                     docs: 0,
                     connection_providers: 0
    end
  end
end
