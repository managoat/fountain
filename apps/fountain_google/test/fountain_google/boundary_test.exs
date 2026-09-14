defmodule FountainGoogle.BoundaryTest do
  @moduledoc """
  What the extension owes the host, asserted from the extension's side
  (ADR 0043, #2152).

  `Fountain.ExtensionGuardTest` checks that core names nothing here. This checks
  the other things the move promised: the contract is implemented and no wider
  than three callbacks, the mount is the path the endpoint always had and the
  host's dispatch guard accepts it, the one route is deliberately outside the
  published contract, and the audit event a send records survived.
  """
  use Fountain.DataCase, async: true

  alias FountainGoogle.Extension

  describe "the extension contract" do
    test "implements every Fountain.Extension callback" do
      assert Extension.id() == :google

      for {fun, arity} <- Fountain.Extension.behaviour_info(:callbacks) do
        assert function_exported?(Extension, fun, arity),
               "FountainGoogle.Extension is missing #{fun}/#{arity}"
      end
    end

    test "uses three callbacks and widens the seam with none" do
      # ADR 0043 decision 3 specified this extension against `api_mounts/0` and
      # `conversation_mcp_servers/2` as the design that needed no tenth
      # callback. Everything else must still be the `use Fountain.Extension`
      # default, so a review notices the day one of them stops being one.
      assert Extension.enabled?() == true
      assert Extension.migrations() == []
      assert Extension.admin_overview() == []
      assert Extension.admin_user_columns() == []
      assert Extension.oban_cron() == []
      assert Extension.docs() == FountainGoogle.Docs
    end

    test "mounts exactly the path the API has always served" do
      assert Extension.api_mounts() == [{"/mcp/gmail", FountainGoogle.Router}]
    end

    test "the host's dispatch guard accepts the mount" do
      # `/api/mcp/gmail/...` used to be a core route, and a core route reserves
      # its static prefix against every extension mount. The route is gone, so
      # the prefix is free — this is the check that fails if it ever comes back.
      refute ["mcp", "gmail"] in Fountain.Extensions.core_route_prefixes()
      assert Fountain.Extensions.validate([Extension]) == :ok
    end

    test "is installed in this VM, so the suite exercises it through the seam" do
      assert Extension in Fountain.Extensions.installed()
    end

    test "declares no migration, because it holds no state of its own" do
      assert Fountain.Extensions.migration_paths([Extension]) == []
    end

    test "describes no path: the transport is not an operation" do
      # Would raise on a path outside the mount; asserting the value keeps the
      # check honest, and pins that the published spec is unchanged by the move.
      assert Fountain.Extensions.openapi_paths([Extension]) == %{}
    end
  end

  describe "every route this extension serves is described, or excepted" do
    # `FountainWeb.ApiSpecTest`'s "every /api/ route is in the spec" walks
    # `FountainWeb.Router.__routes__/0`, which stopped including this route when
    # it moved. Without this the extension's routes would have escaped that
    # guard entirely — the API would be free to grow an undocumented operation
    # and no check anywhere would notice.

    # `/api/mcp/gmail/:conversation_id/:connection_id` is not in the spec and
    # was not before the move either (it was an `@exceptions` entry in core's
    # test): it is a JSON-RPC transport the sandbox posts to with a
    # conversation-scoped token, not an operation a client codes against.
    @excepted_routes [{"/mcp/gmail/{conversation_id}/{connection_id}", :post}]

    test "every mounted route has an OpenAPI operation" do
      described = Fountain.Extensions.openapi_paths([Extension]) |> Map.keys() |> MapSet.new()

      undocumented =
        for {mount, router} <- Extension.api_mounts(),
            route <- router.__routes__(),
            path = open_api_path(mount <> route.path),
            not MapSet.member?(described, "/api" <> path),
            {path, route.verb} not in @excepted_routes,
            do: {path, route.verb}

      assert undocumented == [],
             "these extension routes have no OpenAPI operation: #{inspect(undocumented)}"
    end

    test "every exception is still a live route" do
      live =
        for {mount, router} <- Extension.api_mounts(),
            route <- router.__routes__(),
            do: {open_api_path(mount <> route.path), route.verb}

      assert Enum.reject(@excepted_routes, &(&1 in live)) == [],
             "an exception names a route this extension no longer serves"
    end

    defp open_api_path(path) do
      path
      |> String.split("/")
      |> Enum.map_join("/", fn
        ":" <> segment -> "{#{segment}}"
        segment -> segment
      end)
    end
  end

  # The audit event survived the move too: a send records the host's
  # `connection.used` with the `sprite` actor and never the content (ADR 0013).
  # It is an effect rather than a tenant-state mutation, so the controller
  # records it, and `FountainGoogle.McpControllerTest` is where that is proved
  # through the endpoint.
end
