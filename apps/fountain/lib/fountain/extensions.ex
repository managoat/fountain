defmodule Fountain.Extensions do
  @moduledoc """
  The registry of configured `Fountain.Extension`s (ADR 0043, #1505).

  There is no runtime registration. `config :fountain, :extensions, [Mod, ...]`
  is the whole truth: this module reads it, validates it once at boot, and
  answers the two questions the host asks per request.

      configured()  # every module named in config, enabled or not
      installed()   # the configured ones whose `enabled?/0` says yes

  `installed/0` is what every dispatch point uses, so a configured extension
  that cannot run on this deployment is indistinguishable from one that was
  never configured — no routes, no MCP servers, no calls.

  ## Failing closed

  `validate!/0` runs from `Fountain.Application.start/2` and **raises**, so a
  deployment whose extension configuration is wrong refuses to boot rather than
  serving a surface nobody checked. It refuses a module that is not an
  extension, a duplicate id, a duplicate or malformed API prefix, a prefix a
  core route already claims, and a half-declared HTTP surface (a prefix with no
  plug, or a plug with no prefix).

  The core-route check reads `FountainWeb.Router.__routes__/0` rather than a
  hand-kept list, so a route added to the router next month automatically
  reserves its prefix. A core route always wins: dispatch only ever sees a
  request Phoenix matched to no core route at all.
  """

  require Logger

  alias Fountain.Extension

  @type t :: module()

  @doc "Every extension module named in configuration, in configured order."
  @spec configured() :: [t()]
  def configured, do: Application.get_env(:fountain, :extensions, [])

  @doc """
  The configured extensions this deployment can actually run, in configured
  order. Everything that dispatches uses this, never `configured/0`.

  Takes the list for the same reason `validate/2` does: a test can hand it an
  extension whose `enabled?/0` misbehaves without installing that extension in
  the VM for every other test to trip over.
  """
  @spec installed() :: [t()]
  def installed, do: installed(configured())

  @doc "See `installed/0`. Takes the list, so a test can supply one."
  @spec installed([t()]) :: [t()]
  def installed(modules) when is_list(modules), do: Enum.filter(modules, &enabled?/1)

  @doc """
  Whether an extension with this id is installed here.

  What a surface asks when it needs to know whether a capability is present in
  this distribution *without naming a module*: an id is a value in
  configuration, not a code reference, so a core-owned caller can ask and
  `Fountain.ExtensionGuardTest` stays green. That is what `id/0` is for. The
  caller it was added for (#1525) was the marketing copy, which has since
  left the repo for managoat/site; the question is still the one a core-owned
  surface has to ask, so the function stays.

  `false` on a core distribution, and on a bundled one where the extension is
  configured but answers `enabled?/0` with `false`.
  """
  @spec installed?(atom()) :: boolean()
  def installed?(id) when is_atom(id), do: Enum.any?(installed(), &(&1.id() == id))

  @doc """
  The installed extension that serves `path_info`, as `{extension, mount, plug}`.

  `mount` is the matched mount's segments, so the caller can trim exactly what
  matched. The **longest** declared mount wins, which is what lets one extension
  hold both `/api/buzz` and `/api/mcp/buzz` without either swallowing the other.

  `nil` covers all of "no extension declares a mount here", "the one that does
  is disabled here" and "nothing is configured" — the caller answers 404 to
  each, because they are the same answer to a client.
  """
  @spec find_mount([String.t()]) :: {t(), [String.t()], Extension.plug()} | nil
  def find_mount(path_info), do: find_mount(path_info, installed())

  @doc "See `find_mount/1`. Takes the list, so a test can supply one."
  @spec find_mount([String.t()], [t()]) :: {t(), [String.t()], Extension.plug()} | nil
  def find_mount(path_info, modules) when is_list(path_info) and is_list(modules) do
    modules
    |> Enum.flat_map(fn ext ->
      for {path, plug} <- ext.api_mounts(), do: {ext, segments(path), plug}
    end)
    |> Enum.filter(fn {_ext, mount, _plug} -> List.starts_with?(path_info, mount) end)
    |> Enum.max_by(fn {_ext, mount, _plug} -> length(mount) end, fn -> nil end)
  end

  def find_mount(_path_info, _modules), do: nil

  @doc ~S(The segments of a mount path: `"/mcp/buzz"` is `["mcp", "buzz"]`.)
  @spec segments(String.t()) :: [String.t()]
  def segments(path) when is_binary(path), do: String.split(path, "/", trim: true)

  @doc """
  Every mount an installed extension declares, as `{extension, path}`.

  For anything that needs to know the whole surface: the OpenAPI check, and the
  guard tests.
  """
  @spec mounts() :: [{t(), String.t()}]
  def mounts, do: mounts(installed())

  @doc "See `mounts/0`. Takes the list, so a test can supply one."
  @spec mounts([t()]) :: [{t(), String.t()}]
  def mounts(modules) when is_list(modules) do
    for ext <- modules, {path, _plug} <- ext.api_mounts(), do: {ext, path}
  end

  @doc """
  Every installed extension's MCP servers for this conversation, concatenated
  in configured order.

  **A failing extension costs only its own servers.** A raise, throw or exit in
  one `conversation_mcp_servers/2` is caught here, logged, and contributes `[]`;
  the other extensions and the host's own team and caller servers are
  untouched and the turn goes on. The alternative — letting it propagate — kills
  the turn kick, which means a broken optional integration takes the
  conversation with it.
  """
  @spec conversation_mcp_servers(String.t() | nil, String.t() | nil) :: [map()]
  def conversation_mcp_servers(conversation_id, callback_token)
      when is_binary(conversation_id) and is_binary(callback_token) do
    Enum.flat_map(installed(), &safe_mcp_servers(&1, conversation_id, callback_token))
  end

  def conversation_mcp_servers(_conversation_id, _callback_token), do: []

  defp safe_mcp_servers(ext, conversation_id, callback_token) do
    case ext.conversation_mcp_servers(conversation_id, callback_token) do
      servers when is_list(servers) ->
        servers

      other ->
        Logger.error(
          "extension #{inspect(ext)} conversation_mcp_servers/2 returned #{inspect(other)}, " <>
            "expected a list; contributing none"
        )

        []
    end
  rescue
    error ->
      log_contribution_failure(ext, conversation_id, :error, error, __STACKTRACE__)
      []
  catch
    kind, reason ->
      log_contribution_failure(ext, conversation_id, kind, reason, __STACKTRACE__)
      []
  end

  defp log_contribution_failure(ext, conversation_id, kind, reason, stacktrace) do
    Logger.error(
      "extension #{inspect(ext)} conversation_mcp_servers/2 failed for conversation " <>
        "#{conversation_id}; contributing none\n" <>
        Exception.format(kind, reason, stacktrace)
    )
  end

  # `enabled?/0` is asked per dispatch, so a raising one must not take the
  # request with it. A extension that cannot answer is not installed.
  defp enabled?(ext) do
    ext.enabled?() == true
  rescue
    error ->
      Logger.error(
        "extension #{inspect(ext)} enabled?/0 raised; treating as not installed\n" <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      false
  end

  ## ─── Migrations ──────────────────────────────────────────────────────────

  @doc """
  Every installed extension's migration directories, in configured order.

  Callers append these to the core's path — never prepend, never interleave — so
  a database with no extension installed migrates exactly as it did before this
  existed, and core migration ordering never depends on an extension being
  present. With nothing installed this is `[]` and every entrance degrades to
  the single core path it used before (#1506).

  Raises if an installed extension declares a directory that is not there: a
  missing migration path is the difference between "this deployment has no
  extension migrations" and "this deployment silently skipped them", and only
  the first is safe to keep booting through.
  """
  @spec migration_paths() :: [String.t()]
  def migration_paths, do: migration_paths(installed())

  @doc "See `migration_paths/0`. Takes the list, so a test can supply one."
  @spec migration_paths([t()]) :: [String.t()]
  def migration_paths(modules) when is_list(modules) do
    Enum.flat_map(modules, fn ext ->
      Enum.map(ext.migrations(), &resolve_migration_path!(ext, &1))
    end)
  end

  defp resolve_migration_path!(ext, {otp_app, path_under_priv})
       when is_atom(otp_app) and is_binary(path_under_priv) do
    case :code.priv_dir(otp_app) do
      {:error, :bad_name} ->
        raise ArgumentError,
              "extension #{inspect(ext)} declares migrations in #{inspect(otp_app)}, " <>
                "which is not a loaded OTP application"

      priv ->
        path = Path.join(to_string(priv), path_under_priv)

        if File.dir?(path) do
          path
        else
          raise ArgumentError,
                "extension #{inspect(ext)} declares the migration directory " <>
                  "#{inspect(path_under_priv)} in #{inspect(otp_app)}, but #{path} does not exist"
        end
    end
  end

  defp resolve_migration_path!(ext, other) do
    raise ArgumentError,
          "extension #{inspect(ext)} migrations/0 must return {otp_app, path} tuples, " <>
            "got #{inspect(other)}"
  end

  ## ─── OpenAPI ─────────────────────────────────────────────────────────────

  @doc """
  Every installed extension's OpenAPI paths, checked against its mounts.

  An extension returns absolute paths; this refuses any that falls outside the
  mounts it declared, so an extension cannot describe a path it does not serve.
  That check is the reason the callback takes absolute paths at all: prefixing
  mount-relative ones made the property true by construction for a single mount
  and had no answer for an extension holding two.

  Raises if two extensions describe the same path. Mount uniqueness already
  makes that impossible, so it is a second lock on the same door — but the
  failure it prevents (one extension's operation silently replacing another's in
  the published spec) is invisible, and the SDKs are generated from that spec.
  """
  @spec openapi_paths() :: OpenApiSpex.Paths.t()
  def openapi_paths, do: openapi_paths(installed())

  @doc "See `openapi_paths/0`. Takes the list, so a test can supply one."
  @spec openapi_paths([t()]) :: OpenApiSpex.Paths.t()
  def openapi_paths(modules) when is_list(modules) do
    modules
    |> Enum.flat_map(&checked_openapi_paths/1)
    |> Enum.reduce(%{}, fn {path, item, ext}, acc ->
      case acc do
        %{^path => {_item, other}} ->
          raise ArgumentError,
                "extensions #{inspect(other)} and #{inspect(ext)} both describe " <>
                  "the OpenAPI path #{inspect(path)}"

        _ ->
          Map.put(acc, path, {item, ext})
      end
    end)
    |> Map.new(fn {path, {item, _ext}} -> {path, item} end)
  end

  defp checked_openapi_paths(ext) do
    paths = ext.openapi_paths()
    prefixes = Enum.map(ext.api_mounts(), fn {path, _plug} -> "/api" <> path end)

    for {path, item} <- paths do
      unless Enum.any?(prefixes, &under?(path, &1)) do
        raise ArgumentError,
              "extension #{inspect(ext)} describes the OpenAPI path #{inspect(path)}, " <>
                "which is outside every path it mounts (#{Enum.join(prefixes, ", ")})"
      end

      {path, item, ext}
    end
  end

  defp under?(path, prefix), do: path == prefix or String.starts_with?(path, prefix <> "/")

  @doc """
  A router's paths, mounted: `"/agents"` under `"/buzz"` is `"/api/buzz/agents"`.

  What an extension calls from its own `openapi_paths/0`, so it writes its mount
  once rather than repeating it on every path.
  """
  @spec mounted_paths(String.t(), module()) :: OpenApiSpex.Paths.t()
  def mounted_paths(mount, router) when is_binary(mount) and is_atom(router) do
    router
    |> OpenApiSpex.Paths.from_router()
    |> Map.new(fn {path, item} -> {mount_path(mount, path), item} end)
  end

  defp mount_path(mount, path) do
    case String.trim_leading(path, "/") do
      "" -> "/api" <> mount
      rest -> "/api" <> mount <> "/" <> rest
    end
  end

  ## ─── Admin console ───────────────────────────────────────────────────────

  @doc """
  Every installed extension's admin overview figures, in configured order.

  Data, not markup: the host renders each `{label, value}` as one stat tile
  beside its own. An extension that raises here costs its own tiles and nothing
  else — an admin page is a read-only view, and losing one number is better than
  losing the page an operator opened during an incident.
  """
  @spec admin_overview() :: [{String.t(), term()}]
  def admin_overview, do: admin_overview(installed())

  @doc "See `admin_overview/0`. Takes the list, so a test can supply one."
  @spec admin_overview([t()]) :: [{String.t(), term()}]
  def admin_overview(modules) when is_list(modules) do
    Enum.flat_map(modules, fn ext ->
      safe_admin(ext, :admin_overview, fn -> ext.admin_overview() end)
    end)
  end

  @doc """
  Every installed extension's extra admin users-table columns.

  Each is `{header, %{user_id => value}}`, built once for the page rather than
  once per row.
  """
  @spec admin_user_columns() :: [{String.t(), %{String.t() => term()}}]
  def admin_user_columns, do: admin_user_columns(installed())

  @doc "See `admin_user_columns/0`. Takes the list, so a test can supply one."
  @spec admin_user_columns([t()]) :: [{String.t(), %{String.t() => term()}}]
  def admin_user_columns(modules) when is_list(modules) do
    Enum.flat_map(modules, fn ext ->
      safe_admin(ext, :admin_user_columns, fn -> ext.admin_user_columns() end)
    end)
  end

  defp safe_admin(ext, callback, fun) do
    case fun.() do
      list when is_list(list) ->
        list

      other ->
        Logger.error(
          "extension #{inspect(ext)} #{callback}/0 returned #{inspect(other)}, " <>
            "expected a list; contributing none"
        )

        []
    end
  rescue
    error ->
      Logger.error(
        "extension #{inspect(ext)} #{callback}/0 raised; contributing none\n" <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      []
  catch
    kind, reason ->
      Logger.error(
        "extension #{inspect(ext)} #{callback}/0 failed; contributing none\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      []
  end

  ## ─── Oban ────────────────────────────────────────────────────────────────

  @doc """
  The host's Oban options with every installed extension's cron entries merged
  into the `Oban.Plugins.Cron` plugin.

  Core entries first, extensions after, in configured order. With nothing
  installed this returns the options untouched — and a core-only release never
  names a worker module it does not carry, which is the failure this exists to
  prevent (a `config :fountain, Oban` entry for a missing module is a crash on
  start, not a missing feature).
  """
  @spec oban_options(keyword()) :: keyword()
  def oban_options(opts) do
    case Enum.flat_map(installed(), & &1.oban_cron()) do
      [] -> opts
      entries -> Keyword.update!(opts, :plugins, &merge_cron(&1, entries))
    end
  end

  defp merge_cron(plugins, entries) do
    Enum.map(plugins, fn
      {Oban.Plugins.Cron, cron_opts} ->
        {Oban.Plugins.Cron, Keyword.update(cron_opts, :crontab, entries, &(&1 ++ entries))}

      other ->
        other
    end)
  end

  ## ─── Validation ──────────────────────────────────────────────────────────

  @doc """
  Validate the configured extensions, raising on anything wrong.

  Called from `Fountain.Application.start/2`, before any child starts: a
  deployment with a bad extension list fails to boot, loudly, instead of
  serving a surface whose shape nobody checked.
  """
  @spec validate!() :: :ok
  def validate!, do: validate!(configured())

  @doc "See `validate!/0`. Takes the list, for tests and for a dry run."
  @spec validate!([t()]) :: :ok
  def validate!(modules) do
    case validate(modules) do
      :ok ->
        :ok

      {:error, message} ->
        raise ArgumentError,
              "invalid :extensions configuration for :fountain — #{message}\n\n" <>
                "Fix config :fountain, :extensions. See decisions/0043-first-party-extensions.md."
    end
  end

  @doc """
  Validate a list of extension modules against the core routes.

  Returns `:ok` or `{:error, message}` where the message names the offending
  module. Pure: it reads the router's compiled route table and nothing else, so
  a test can call it on any list without touching configuration.
  """
  @spec validate([t()]) :: :ok | {:error, String.t()}
  def validate(modules), do: validate(modules, core_route_prefixes())

  @doc "See `validate/1`. Takes the core prefixes, so a test can supply them."
  @spec validate([t()], [[String.t()]]) :: :ok | {:error, String.t()}
  def validate(modules, core_prefixes) when is_list(core_prefixes) do
    with :ok <- check_all(modules, &check_module/1),
         :ok <- check_unique(modules, & &1.id(), "id"),
         :ok <- check_all(modules, &check_mount_shapes/1),
         :ok <- check_mounts_unique(modules),
         :ok <- check_all(modules, &check_mounts_free(&1, core_prefixes)),
         :ok <- check_resolvable(fn -> openapi_paths(installed(modules)) end),
         # The manual's rules live in Fountain.Manual, beside the merge that
         # depends on them: a slug the core manual already serves, and a mount
         # the host does not route.
         :ok <- check_all(installed(modules), &Fountain.Manual.validate/1) do
      # Only the ones this deployment will actually run: a configured extension
      # that is off here contributes no migrations, so its directory need not be
      # present. Resolution is what checks it, so this is the same code path the
      # migrator takes rather than a second opinion about it.
      check_resolvable(fn -> migration_paths(installed(modules)) end)
    end
  end

  @doc """
  The static path prefixes the core router already claims under `/api`.

  Each is a segment list truncated at the first dynamic segment, so
  `/api/mcp/gmail/:conversation_id/:connection_id` yields `["mcp", "gmail"]`.
  Read from the compiled route table, so it needs no maintenance: a route added
  to `FountainWeb.Router` reserves its path from the same commit.
  """
  @spec core_route_prefixes() :: [[String.t()]]
  def core_route_prefixes do
    FountainWeb.Router.__routes__()
    |> Enum.flat_map(fn route ->
      case String.split(route.path, "/", trim: true) do
        ["api" | rest] -> [Enum.take_while(rest, &static_segment?/1)]
        _other -> []
      end
    end)
    |> Enum.reject(&(&1 == []))
    |> Enum.uniq()
  end

  defp static_segment?(":" <> _rest), do: false
  defp static_segment?("*" <> _rest), do: false
  defp static_segment?(_segment), do: true

  # Turns the raise that `migration_paths/1` and `openapi_paths/1` use at their
  # own call sites into the `{:error, message}` this function returns, so
  # `validate!/0` raises once, with one message shape, from one place.
  defp check_resolvable(fun) do
    fun.()
    :ok
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp check_all(modules, fun) do
    Enum.reduce_while(modules, :ok, fn module, :ok ->
      case fun.(module) do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  @required_callbacks [
    id: 0,
    enabled?: 0,
    api_mounts: 0,
    conversation_mcp_servers: 2,
    migrations: 0,
    openapi_paths: 0,
    admin_overview: 0,
    admin_user_columns: 0,
    oban_cron: 0,
    docs: 0
  ]

  defp check_module(module) when is_atom(module) do
    loaded? = Code.ensure_loaded?(module)

    implements? =
      loaded? and
        Enum.all?(@required_callbacks, fn {fun, arity} ->
          function_exported?(module, fun, arity)
        end)

    cond do
      not loaded? ->
        {:error, "#{inspect(module)} is not a loadable module"}

      implements? ->
        :ok

      true ->
        {:error,
         "#{inspect(module)} does not implement Fountain.Extension " <>
           "(add `use Fountain.Extension, id: :...`)"}
    end
  end

  defp check_module(other) do
    {:error, "#{inspect(other)} is not a module"}
  end

  # One or more lowercase static segments. Deliberately narrow: a mount carrying
  # an uppercase letter, a dot or a dynamic segment is a mount that reads
  # differently in a route, in an OpenAPI path and in a URL a person types.
  @segment_shape ~r/^[a-z][a-z0-9-]*$/
  @max_mount_segments 3

  defp check_mount_shapes(module) do
    Enum.reduce_while(module.api_mounts(), :ok, fn entry, :ok ->
      case check_mount_shape(module, entry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_mount_shape(module, {path, plug}) when is_binary(path) and is_atom(plug) do
    segments = segments(path)

    cond do
      segments == [] ->
        {:error, "#{inspect(module)} declares an empty api_mount path"}

      length(segments) > @max_mount_segments ->
        {:error,
         "#{inspect(module)} api_mount #{inspect(path)} has more than " <>
           "#{@max_mount_segments} segments"}

      not Enum.all?(segments, &Regex.match?(@segment_shape, &1)) ->
        {:error,
         "#{inspect(module)} api_mount #{inspect(path)} is not lowercase static " <>
           "path segments matching #{inspect(Regex.source(@segment_shape))}"}

      not String.starts_with?(path, "/") ->
        {:error, "#{inspect(module)} api_mount #{inspect(path)} must start with /"}

      true ->
        :ok
    end
  end

  defp check_mount_shape(module, {path, plug}) do
    {:error,
     "#{inspect(module)} api_mounts must be {path_string, plug_module} tuples, got " <>
       "#{inspect({path, plug})}"}
  end

  defp check_mount_shape(module, other) do
    {:error,
     "#{inspect(module)} api_mounts must be {path_string, plug_module} tuples, got " <>
       inspect(other)}
  end

  defp check_mounts_unique(modules) do
    modules
    |> Enum.flat_map(fn module ->
      for {path, _plug} <- module.api_mounts(), do: {module, segments(path), path}
    end)
    |> Enum.group_by(fn {_module, segs, _path} -> segs end)
    |> Enum.find(fn {_segs, entries} -> length(entries) > 1 end)
    |> case do
      nil ->
        :ok

      {_segs, entries} ->
        {:error,
         "api_mount #{inspect(elem(hd(entries), 2))} is declared by more than one extension: " <>
           Enum.map_join(entries, ", ", fn {module, _segs, _path} -> inspect(module) end)}
    end
  end

  # Overlap in either direction is refused. The host declares its extension
  # dispatch LAST, so a core route always wins: a mount that a core path
  # prefixes, or that prefixes a core path, would be a route silently serving
  # nothing. `/mcp` overlaps `/api/mcp/team/:id`; `/mcp/buzz` does not.
  defp check_mounts_free(module, core_prefixes) do
    Enum.reduce_while(module.api_mounts(), :ok, fn {path, _plug}, :ok ->
      mount = segments(path)

      case Enum.find(core_prefixes, &overlaps?(mount, &1)) do
        nil ->
          {:cont, :ok}

        core ->
          {:halt,
           {:error,
            "#{inspect(module)} api_mount #{inspect(path)} overlaps the core route " <>
              "/api/#{Enum.join(core, "/")}"}}
      end
    end)
  end

  defp overlaps?(a, b), do: List.starts_with?(a, b) or List.starts_with?(b, a)

  defp check_unique(modules, fun, label) do
    modules
    |> Enum.map(fn module -> {module, fun.(module)} end)
    |> Enum.reject(fn {_module, value} -> is_nil(value) end)
    |> Enum.group_by(fn {_module, value} -> value end, fn {module, _value} -> module end)
    |> Enum.find(fn {_value, mods} -> length(mods) > 1 end)
    |> case do
      nil ->
        :ok

      {value, mods} ->
        {:error,
         "#{label} #{inspect(value)} is declared by more than one extension: " <>
           Enum.map_join(mods, ", ", &inspect/1)}
    end
  end
end
