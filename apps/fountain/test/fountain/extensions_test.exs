defmodule Fountain.ExtensionsTest do
  @moduledoc """
  The extension registry and its validation (ADR 0043, #1505).

  Everything here is `async: true` because nothing writes `:extensions`. The
  installed list comes from `config/test.exs` and the validation tests pass
  their list in as an argument, which is the whole reason `validate/2` takes
  one.
  """
  use ExUnit.Case, async: true

  alias Fountain.Extensions

  alias Fountain.ExtensionFixtures.{
    AdminRaises,
    Disabled,
    Enabled,
    EnabledRaises,
    Exploding,
    ProvidersBadSlug,
    ProvidersDuplicateFixture,
    ProvidersMalformed,
    ProvidersRaise,
    ProvidersWithUser,
    Silent,
    WrongShape
  }

  import ExUnit.CaptureLog

  describe "configured/0 and installed/0" do
    # These assert about the FIXTURES, not about the whole list. Which real
    # extensions a run installs depends on the working directory — the Buzz
    # extension is on the code path at the umbrella root and not inside
    # apps/fountain (ADR 0043) — so a test that pinned the exact list would
    # pass in one and fail in the other while testing nothing about the seam.
    test "configured/0 lists every extension named in config, enabled or not" do
      configured = Extensions.configured()

      for fixture <- [Enabled, Disabled, Silent, Exploding, WrongShape] do
        assert fixture in configured
      end
    end

    test "installed/0 drops the ones this deployment cannot run" do
      installed = Extensions.installed()

      refute Disabled in installed
      for fixture <- [Enabled, Silent, Exploding, WrongShape], do: assert(fixture in installed)
    end

    test "installed/0 preserves configured order" do
      # Ordering is a host decision and the MCP fan-out depends on it, so it is
      # asserted rather than left to Enum's incidental behaviour.
      assert Extensions.installed() == Enum.filter(Extensions.configured(), & &1.enabled?())
    end
  end

  describe "find_mount/1" do
    test "finds an installed extension by its mount" do
      assert {Enabled, ["fixture"], Fountain.ExtensionFixtures.Router} =
               Extensions.find_mount(["fixture", "whoami"])
    end

    test "matches the mount itself, with nothing after it" do
      assert {Enabled, ["fixture"], _plug} = Extensions.find_mount(["fixture"])
    end

    test "does not find a configured-but-disabled extension" do
      # Disabled declares /fixture-disabled and is still in configured/0. If
      # this ever returns the module, a deployment that turned an extension off
      # would still be serving its routes.
      assert Disabled.api_mounts() == [
               {"/fixture-disabled", Fountain.ExtensionFixtures.Router}
             ]

      assert Extensions.find_mount(["fixture-disabled", "whoami"]) == nil
    end

    test "does not find an extension that mounts nothing" do
      assert Silent.api_mounts() == []
    end

    test "returns nil for an unknown path, an empty one, and a non-list" do
      assert Extensions.find_mount(["nothing-serves-this"]) == nil
      assert Extensions.find_mount([]) == nil
      assert Extensions.find_mount(nil) == nil
    end

    test "the LONGEST mount wins, so a nested mount is not swallowed" do
      # The property Buzz needs: one extension holding both /api/buzz and
      # /api/mcp/buzz, with a different plug behind each.
      defmodule TwoMounts do
        use Fountain.Extension, id: :two_mounts
        @impl true
        def api_mounts do
          [
            {"/thing", Fountain.ExtensionFixtures.Router},
            {"/thing/deeper", Fountain.ExtensionFixtures.CollidingRouter}
          ]
        end
      end

      assert {TwoMounts, ["thing"], Fountain.ExtensionFixtures.Router} =
               Extensions.find_mount(["thing", "x"], [TwoMounts])

      assert {TwoMounts, ["thing", "deeper"], Fountain.ExtensionFixtures.CollidingRouter} =
               Extensions.find_mount(["thing", "deeper", "x"], [TwoMounts])
    end
  end

  describe "conversation_mcp_servers/2" do
    test "collects the claimed conversation's servers" do
      token = "cbk_test_token"

      assert [server] =
               Extensions.conversation_mcp_servers(Enabled.claimed_conversation_id(), token)

      assert server["name"] == "fixture"
      assert server["headers"]["authorization"] == "Bearer #{token}"
    end

    test "contributes nothing for a conversation no extension claims" do
      assert Extensions.conversation_mcp_servers(Ecto.UUID.generate(), "cbk_test_token") == []
    end

    test "never calls a disabled extension" do
      # Disabled returns a server unconditionally; if it were called, it would
      # show up here for every conversation in the system.
      servers = Extensions.conversation_mcp_servers(Ecto.UUID.generate(), "cbk_test_token")
      refute Enum.any?(servers, &(&1["name"] == "disabled-should-never-appear"))
    end

    test "contributes nothing without a conversation id or a callback token" do
      # The token gates the whole list: an extension's servers are authenticated
      # with the conversation-scoped credential or they are not served at all.
      assert Extensions.conversation_mcp_servers(nil, "cbk_test_token") == []
      assert Extensions.conversation_mcp_servers(Enabled.claimed_conversation_id(), nil) == []
    end
  end

  describe "conversation_mcp_servers/2 isolation" do
    # These go through the real function over the real installed list. The
    # misbehaving fixtures each fail for one conversation id only, which is
    # what makes that possible: installing them costs nothing anywhere else,
    # and the alternative — a hand-rolled `Enum.flat_map` with its own
    # try/rescue — would test a copy of the logic rather than the logic.

    test "a raising extension costs only its own servers" do
      # Enabled serves this conversation too, so the assertion is not merely
      # "no crash": it is that everyone else's contribution survived intact.
      log =
        capture_log(fn ->
          servers =
            Extensions.conversation_mcp_servers(Exploding.trigger_conversation_id(), "cbk_t")

          assert Enum.map(servers, & &1["name"]) == ["fixture"]
        end)

      assert log =~ "Exploding"
      assert log =~ "fixture extension exploded"
    end

    test "an extension returning a non-list contributes none and does not corrupt the list" do
      log =
        capture_log(fn ->
          assert Extensions.conversation_mcp_servers(WrongShape.trigger_conversation_id(), "t") ==
                   []
        end)

      assert log =~ "WrongShape"
      assert log =~ "expected a list"
    end

    test "an extension that cannot say whether it is enabled is not installed" do
      log =
        capture_log(fn ->
          assert Extensions.installed([EnabledRaises, Enabled]) == [Enabled]
        end)

      assert log =~ "EnabledRaises"
      assert log =~ "treating as not installed"
    end
  end

  describe "admin_overview/1 and admin_user_columns/1" do
    test "collect what installed extensions report" do
      assert {_label, 7, opts} =
               Enum.find(Extensions.admin_overview(), &(elem(&1, 0) == Enabled.overview_label()))

      assert opts[:navigate] == "/admin/users"

      assert {_header, cells} =
               Enum.find(
                 Extensions.admin_user_columns(),
                 &(elem(&1, 0) == Enabled.column_header())
               )

      assert cells["nobody"] == %{value: 3, alert?: true}
    end

    test "are empty with nothing installed" do
      assert Extensions.admin_overview([]) == []
      assert Extensions.admin_user_columns([]) == []
    end

    test "a raising extension costs its own figures and not the page" do
      # An admin page is a read-only view. Losing one number beats losing the
      # page an operator opened during an incident, so this is contained the
      # way the MCP fan-out is.
      log =
        capture_log(fn ->
          assert Extensions.admin_overview([AdminRaises, Enabled]) == Enabled.admin_overview()

          assert Extensions.admin_user_columns([AdminRaises, Enabled]) ==
                   Enabled.admin_user_columns()
        end)

      assert log =~ "AdminRaises"
      assert log =~ "fixture cannot count"
    end
  end

  describe "connection_providers/1 (ADR 0054)" do
    alias Fountain.Connections.Provider

    test "collects what installed extensions contribute, in configured order" do
      assert [%Provider{slug: "fixture-svc", user_id: nil, id: "fixture-svc"}] =
               Enum.filter(Extensions.connection_providers(), &(&1.slug == "fixture-svc"))

      assert Extensions.connection_providers([Enabled, Silent]) == Enabled.connection_providers()
    end

    test "is empty with nothing installed, and never reads a disabled extension" do
      assert Extensions.connection_providers([]) == []
      refute Enum.any?(Extensions.connection_providers(), &(&1.slug == "disabled-svc"))
    end

    test "a raising extension costs its own providers and not the page" do
      log =
        capture_log(fn ->
          assert Extensions.connection_providers([ProvidersRaise, Enabled]) ==
                   Enabled.connection_providers()
        end)

      assert log =~ "ProvidersRaise"
      assert log =~ "fixture cannot list its providers"
    end

    test "an extension returning a non-list contributes none" do
      defmodule ProvidersNotAList do
        use Fountain.Extension, id: :fixture_providers_not_a_list
        @impl true
        def connection_providers, do: :nope
      end

      log =
        capture_log(fn ->
          assert Extensions.connection_providers([ProvidersNotAList, Enabled]) ==
                   Enabled.connection_providers()
        end)

      assert log =~ "expected a list"
    end
  end

  describe "validate/2 accepts" do
    test "the list this suite actually runs" do
      assert Extensions.validate(Extensions.configured()) == :ok
    end

    test "an empty list" do
      assert Extensions.validate([]) == :ok
    end

    test "an extension with no HTTP surface at all" do
      assert Extensions.validate([Silent]) == :ok
    end
  end

  describe "validate/2 fails closed on a connection provider (ADR 0054)" do
    test "that takes a slug another extension already contributes" do
      assert {:error, message} = Extensions.validate([Enabled, ProvidersDuplicateFixture])
      assert message =~ "ProvidersDuplicateFixture"
      assert message =~ "fixture-svc"
    end

    test "that carries a user_id" do
      assert {:error, message} = Extensions.validate([ProvidersWithUser])
      assert message =~ "with a user_id"
    end

    test "that is not a provider struct" do
      assert {:error, message} = Extensions.validate([ProvidersMalformed])
      assert message =~ "expected a %Fountain.Connections.Provider{}"
    end

    test "whose slug is not a slug" do
      assert {:error, message} = Extensions.validate([ProvidersBadSlug])
      assert message =~ ~s(slug "Bad Slug" is not lowercase)
    end

    test "when listing them raises" do
      assert {:error, message} = Extensions.validate([ProvidersRaise])
      assert message =~ "connection_providers/0 raised: fixture cannot list its providers"
    end

    test "but not on a DISABLED extension's bad provider" do
      # `Disabled` contributes a bare struct that would fail every check; it is
      # never asked, the way its migrations are never resolved.
      assert Extensions.validate([Disabled]) == :ok
    end
  end

  describe "validate/2 fails closed" do
    test "on a duplicate id" do
      defmodule DupeIdA do
        use Fountain.Extension, id: :same
      end

      defmodule DupeIdB do
        use Fountain.Extension, id: :same
      end

      assert {:error, message} = Extensions.validate([DupeIdA, DupeIdB])
      assert message =~ "id :same is declared by more than one extension"
    end

    test "on a duplicate mount" do
      defmodule DupeMountA do
        use Fountain.Extension, id: :dupe_mount_a
        @impl true
        def api_mounts, do: [{"/shared", Fountain.ExtensionFixtures.Router}]
      end

      defmodule DupeMountB do
        use Fountain.Extension, id: :dupe_mount_b
        @impl true
        def api_mounts, do: [{"/shared", Fountain.ExtensionFixtures.Router}]
      end

      assert {:error, message} = Extensions.validate([DupeMountA, DupeMountB])
      assert message =~ ~s(api_mount "/shared" is declared by more than one extension)
    end

    test "on a mount a core route already claims" do
      defmodule Shadower do
        use Fountain.Extension, id: :shadower
        @impl true
        def api_mounts, do: [{"/agents", Fountain.ExtensionFixtures.Router}]
      end

      assert {:error, message} = Extensions.validate([Shadower])
      assert message =~ "overlaps the core route /api/agents"
    end

    test "on a mount the browser scope claims (/api/settings/theme)" do
      # The one /api path that lives in the browser scope, declared after every
      # /api scope in the router. A hand-kept reserved list would have missed
      # it; reading __routes__/0 does not.
      defmodule SettingsShadower do
        use Fountain.Extension, id: :settings_shadower
        @impl true
        def api_mounts, do: [{"/settings", Fountain.ExtensionFixtures.Router}]
      end

      assert {:error, message} = Extensions.validate([SettingsShadower])
      assert message =~ "overlaps the core route /api/settings"
    end

    test "on a mount that a core route PREFIXES, not just one that prefixes a core route" do
      # /api/mcp/team/:id exists, so mounting /mcp would be a route the host's
      # own declaration order guarantees never serves anything. Overlap is
      # refused in both directions for that reason.
      defmodule McpShadower do
        use Fountain.Extension, id: :mcp_shadower
        @impl true
        def api_mounts, do: [{"/mcp", Fountain.ExtensionFixtures.Router}]
      end

      assert {:error, message} = Extensions.validate([McpShadower])
      assert message =~ "overlaps the core route /api/mcp"
    end

    test "but NOT on a deeper mount beside a core one (/mcp/buzz beside /api/mcp/team)" do
      # The case the Buzz move needs: /api/mcp/team/:id and /api/mcp/caller/:id
      # are core routes, and /api/mcp/buzz overlaps neither.
      defmodule McpSibling do
        use Fountain.Extension, id: :mcp_sibling
        @impl true
        def api_mounts, do: [{"/mcp/sibling", Fountain.ExtensionFixtures.Router}]
      end

      assert Extensions.validate([McpSibling]) == :ok
    end

    test "on a mount segment that is not lowercase and static" do
      for bad <- ["/Buzz", "/buzz.thing", "/9lives", "/buzz/:id", "/"] do
        module =
          :"Elixir.BadMount#{System.unique_integer([:positive])}"
          |> Module.create(
            quote do
              use Fountain.Extension, id: :bad_mount
              @impl true
              def api_mounts, do: [{unquote(bad), Fountain.ExtensionFixtures.Router}]
            end,
            Macro.Env.location(__ENV__)
          )
          |> elem(1)

        assert {:error, message} = Extensions.validate([module])
        assert message =~ "api_mount", "accepted #{inspect(bad)}"
      end
    end

    test "on a mount deeper than three segments" do
      defmodule TooDeep do
        use Fountain.Extension, id: :too_deep
        @impl true
        def api_mounts, do: [{"/a/b/c/d", Fountain.ExtensionFixtures.Router}]
      end

      assert {:error, message} = Extensions.validate([TooDeep])
      assert message =~ "more than 3 segments"
    end

    test "on an api_mounts entry that is not {path, plug}" do
      defmodule BadMountShape do
        use Fountain.Extension, id: :bad_mount_shape
        @impl true
        def api_mounts, do: ["/just-a-string"]
      end

      assert {:error, message} = Extensions.validate([BadMountShape])
      assert message =~ "must be {path_string, plug_module} tuples"
    end

    test "on an OpenAPI path outside every mount the extension declares" do
      assert {:error, message} =
               Extensions.validate([Fountain.ExtensionFixtures.DescribesWithoutMount])

      assert message =~ "which is outside every path it mounts"
    end

    test "on a module that is not an extension" do
      assert {:error, message} = Extensions.validate([Enum])
      assert message =~ "does not implement Fountain.Extension"
    end

    test "on a module that does not exist" do
      assert {:error, message} = Extensions.validate([NoSuchModuleAnywhere])
      assert message =~ "is not a loadable module"
    end

    test "on an installed extension whose migration directory is missing (#1506)" do
      # A missing directory is the difference between "no extension migrations
      # here" and "silently skipped them", and only the first is safe to boot
      # through — so it is a boot failure, not a warning.
      assert {:error, message} =
               Extensions.validate([Fountain.ExtensionFixtures.MissingMigrations])

      assert message =~ "no_such_directory"
      assert message =~ "does not exist"
    end

    test "not on a DISABLED extension whose migration directory is missing" do
      # It contributes no migrations here, so its directory need not exist.
      defmodule DisabledMissingMigrations do
        use Fountain.Extension, id: :disabled_missing_migrations
        @impl true
        def enabled?, do: false
        @impl true
        def migrations, do: [{:fountain, "no_such_directory"}]
      end

      assert Extensions.validate([DisabledMissingMigrations]) == :ok
    end
  end

  describe "validate!/1" do
    test "raises with the offending module named and the ADR pointed at" do
      assert_raise ArgumentError, ~r/does not implement Fountain.Extension/, fn ->
        Extensions.validate!([Enum])
      end

      assert_raise ArgumentError, ~r/0043-first-party-extensions/, fn ->
        Extensions.validate!([Enum])
      end
    end

    test "passes the configuration this VM booted with" do
      # If this fails, Fountain.Application.start/2 would have refused to boot.
      assert Extensions.validate!() == :ok
    end
  end

  describe "core_route_prefixes/0" do
    test "is read from the router rather than hand-kept" do
      prefixes = Extensions.core_route_prefixes()

      # Some are whole routes (`/api/agents`); `/api/admin` has no bare route,
      # only `/api/admin/users` and friends. Both reserve the name, because the
      # overlap check refuses a mount in either direction — which is the
      # property that matters, so it is what is asserted.
      for segment <- ~w(agents vaults environments conversations audit search catalog admin) do
        assert Enum.any?(prefixes, &List.starts_with?(&1, [segment])),
               "/api/#{segment} should reserve #{segment}"
      end
    end

    test "truncates at the first dynamic segment" do
      prefixes = Extensions.core_route_prefixes()

      # /api/mcp/team/:conversation_id stops at the static half, so a mount at
      # /mcp/team is refused and one at /mcp/other is not. (/mcp/gmail used to
      # be the example here; it is the Google extension's mount now, #2152.)
      assert ["mcp", "team"] in prefixes
      refute ["mcp", "gmail"] in prefixes
      refute Enum.any?(prefixes, fn segs -> Enum.any?(segs, &String.starts_with?(&1, ":")) end)
    end

    test "does not reserve a path nothing serves" do
      refute ["fixture"] in Extensions.core_route_prefixes()
    end
  end
end
