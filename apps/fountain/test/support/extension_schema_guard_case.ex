defmodule FountainWeb.ExtensionSchemaGuardCase do
  @moduledoc """
  The schema guard's own coverage check, for one extension (ADR 0043, #1536).

  `FountainWeb.SchemaGuard` validates every response the suite renders against
  the schema its operation declares — and for the first two extensions it
  validated none of them, silently, for as long as they existed. The core
  router ends `/api` with `forward "/", ExtensionDispatch`, and a forward is
  opaque to `Phoenix.Router.route_info/4`: it reports the forward's own route,
  `/api`, which matches no documented path, so every extension response was
  skipped as `:undocumented`.

  Nothing failed, because a guard that checks nothing looks exactly like a
  guard that finds nothing. That is the failure this file exists to make
  impossible a second time: it asserts the guard can *resolve* every operation
  the extension documents, which is the step that was missing. It says nothing
  about whether those responses are correct — the guard itself does that, on
  every request the extension's own tests make.

  Use it from the extension's suite, naming the extension module:

      defmodule FountainGoogle.SchemaGuardTest do
        use FountainWeb.ExtensionSchemaGuardCase, extension: FountainGoogle.Extension
      end

  It lives in core's `test/support` rather than in each extension because both
  extensions need the identical checks and neither may depend on the other. It
  names no extension: the module under test arrives as an option, and
  everything else is read from `Fountain.Extensions`, which is the host's own
  registry.
  """

  @doc false
  defmacro __using__(opts) do
    extension = Keyword.fetch!(opts, :extension)

    quote bind_quoted: [extension: extension] do
      use ExUnit.Case, async: true

      alias FountainWeb.{SchemaGuard, SchemaGuardAllowlist}

      @extension extension

      test "the extension is installed in this run" do
        # Everything below is vacuous otherwise, and "vacuously true" is the
        # exact shape of the defect this file is about. An extension's own
        # suite always installs it (config/runtime.exs asks
        # `Code.ensure_loaded?/1`, and here the answer is yes).
        assert @extension in Fountain.Extensions.installed(),
               "#{inspect(@extension)} is not installed, so this file would check nothing."
      end

      test "the schema guard resolves every operation this extension documents" do
        unresolved =
          for {path, item} <- @extension.openapi_paths(),
              {method, operation} <- Map.from_struct(item),
              match?(%OpenApiSpex.Operation{}, operation),
              verb = method |> to_string() |> String.upcase(),
              name = SchemaGuard.name(conn_for(verb, path)),
              name != "#{verb} #{path}",
              do: "#{verb} #{path} resolved to #{inspect(name)}"

        assert unresolved == [], """
        The schema guard could not resolve these operations back to the paths
        the extension publishes:

        #{Enum.map_join(unresolved, "\n", &"  #{&1}")}

        `SchemaGuard.name/1` goes through the core router, which sees only the
        `forward "/", ExtensionDispatch` that mounts this extension. When that
        resolution breaks, nothing fails — every response is skipped as
        `:undocumented` and the guard reports a clean run while checking
        nothing at all (#1536). Fix `template/1` in
        apps/fountain/test/support/schema_guard.ex.
        """
      end

      test "no operation of this extension is on the core allowlist" do
        mine =
          for {path, item} <- @extension.openapi_paths(),
              {method, operation} <- Map.from_struct(item),
              match?(%OpenApiSpex.Operation{}, operation),
              do: "#{method |> to_string() |> String.upcase()} #{path}"

        listed =
          for {{name, status}, _family} <- SchemaGuardAllowlist.entries(),
              name in mine,
              do: "#{name} -> #{status}"

        assert listed == [], """
        These entries on FountainWeb.SchemaGuardAllowlist name operations that
        #{inspect(@extension)} serves:

        #{Enum.map_join(listed, "\n", &"  #{&1}")}

        An extension's operations declare their statuses; they do not go on the
        core allowlist. The core ratchet cannot evaluate them: `apps/fountain`
        runs with no extension installed, so
        `FountainWeb.SchemaGuardrailTest`'s staleness check sees no such
        operation and reports the entry as stale. That is not hypothetical —
        it is how `{"POST /api/support/reports", 401}` was deleted in #1528 as
        a fix nobody made (#1536).

        Declare the status on the operation instead. There are #{length(mine)}
        of them here, against the 66 core operations #1432 still owes.
        """
      end

      # A conn shaped like the one the guard receives: `route_info/4` reads the
      # method, the request path and the host, and nothing else. Path templates
      # are spelled `{id}`, and a real request carries a value there — any
      # value routes the same way, so a literal segment stands in for one.
      defp conn_for(method, path) do
        request_path = Regex.replace(~r/\{[^}]+\}/, path, "x")

        :get
        |> Plug.Test.conn(request_path)
        |> Map.put(:method, method)
        |> Map.put(:host, "www.example.com")
      end
    end
  end
end
