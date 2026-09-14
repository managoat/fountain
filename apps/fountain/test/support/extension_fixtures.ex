defmodule Fountain.ExtensionFixtures do
  @moduledoc """
  Fixture extensions that prove the `Fountain.Extension` contract without Buzz
  (ADR 0043, #1505).

  The gate on #1505 is that the seam works before anything moves through it, so
  these are the only extensions the suite installs. They are named in
  `config/test.exs` rather than set per test on purpose: `:extensions` is
  global application state, and a test that wrote it would collide with every
  other async test in the VM the way the fleet-ceiling seed flake did (#1214).
  Everything a test needs to vary is therefore a *different fixture*, not a
  different configuration.

    * `Enabled` — the full contract: a prefix, a Phoenix router behind it, an
      MCP contribution keyed on the conversation id, and one connection
      provider (ADR 0054) that the registry lists after the host's own.
    * `Disabled` — configured, `enabled?/0` false. Proves an installed-but-off
      extension is indistinguishable from an absent one.
    * `Silent` — enabled, no HTTP surface at all. Proves `nil`/`nil` is a
      supported shape and not a validation failure.
    * `Exploding` and `WrongShape` — misbehave from
      `conversation_mcp_servers/2`, but only for one conversation id each, so
      they are safe to install alongside the others. That is what makes the
      isolation tests exercise `Fountain.Extensions.conversation_mcp_servers/2`
      itself rather than a copy of its logic.
  """

  defmodule Router do
    @moduledoc """
    The fixture extension's own Phoenix router, mounted at `/api/fixture`.

    Its routes are written relative to that mount, which is the property
    `ExtensionDispatch` has to provide: the extension does not know or repeat
    its own prefix.
    """
    use Phoenix.Router

    pipeline :fixture do
      plug :accepts, ["json"]
    end

    scope "/", Fountain.ExtensionFixtures do
      pipe_through :fixture

      get "/whoami", Controller, :whoami
      get "/nested/deep", Controller, :deep
    end
  end

  defmodule Schemas do
    @moduledoc "The fixture extension's own OpenAPI components."

    require OpenApiSpex

    defmodule Whoami do
      @moduledoc false
      require OpenApiSpex

      # A title no core schema uses. `FixtureWhoami`, not `Whoami`, because a
      # collision here would be a real one and the collision tests build their
      # own colliding schema on purpose.
      OpenApiSpex.schema(%{
        title: "FixtureWhoami",
        type: :object,
        properties: %{
          user_id: %OpenApiSpex.Schema{type: :string},
          email: %OpenApiSpex.Schema{type: :string}
        }
      })
    end

    defmodule Deep do
      @moduledoc false
      require OpenApiSpex

      OpenApiSpex.schema(%{
        title: "FixtureDeep",
        type: :object,
        properties: %{
          path_info: %OpenApiSpex.Schema{
            type: :array,
            items: %OpenApiSpex.Schema{type: :string}
          }
        }
      })
    end
  end

  defmodule Controller do
    @moduledoc """
    Answers with what the host handed the extension, so a test can assert on
    the seam itself rather than on the fixture's own behaviour.
    """
    use Phoenix.Controller, formats: [:json]
    use OpenApiSpex.ControllerSpecs

    # Both operations declare every status they can render, because the schema
    # guard resolves through `ExtensionDispatch` since #1536 and this fixture is
    # an installed extension in the test VM like any other. Before that it was
    # the only kind of extension there was, and none of its responses were ever
    # checked — `:whoami` declared no 401 and `:deep` declared nothing at all.
    # A fixture that models the seam should model a well-formed extension too.
    operation(:whoami,
      summary: "Who the host authenticated",
      operation_id: "fixtureWhoami",
      responses: [
        ok: {"Whoami", "application/json", Fountain.ExtensionFixtures.Schemas.Whoami},
        unauthorized:
          {"Missing or invalid API key", "application/json", FountainWeb.Schemas.Error}
      ]
    )

    def whoami(conn, _params) do
      json(conn, %{
        user_id: conn.assigns.current_user.id,
        email: conn.assigns.current_user.email,
        # The prefix moved out of path_info and into script_name, so the
        # extension sees its own mount and can still build correct URLs.
        path_info: conn.path_info,
        script_name: conn.script_name
      })
    end

    operation(:deep,
      summary: "A nested path",
      operation_id: "fixtureDeep",
      responses: [
        ok: {"The trimmed path", "application/json", Fountain.ExtensionFixtures.Schemas.Deep},
        unauthorized:
          {"Missing or invalid API key", "application/json", FountainWeb.Schemas.Error}
      ]
    )

    def deep(conn, _params), do: json(conn, %{path_info: conn.path_info})
  end

  defmodule Enabled do
    @moduledoc "A fully-featured fixture extension. Installed in the test VM."
    use Fountain.Extension, id: :fixture

    @doc "The conversation id this fixture claims. Any other gets `[]`."
    def claimed_conversation_id, do: "11111111-1111-1111-1111-111111111111"

    @doc "The mount this fixture's router sits at."
    def mount, do: "/fixture"

    @impl true
    def api_mounts, do: [{mount(), Fountain.ExtensionFixtures.Router}]

    @impl true
    def migrations, do: [{:fountain, "test_extension_migrations"}]

    @doc """
    Describes paths only while the suite is running.

    `apps/fountain/test/test_helper.exs` sets the flag; nothing else does. That
    is not fussiness — **the published OpenAPI artifact is generated in
    `MIX_ENV=test`.** `scripts/sdk-contract/build.sh` runs `mix openapi.export`,
    ci.yml and release.yml both set `MIX_ENV: test` for it, and the
    `dist/openapi.json` that comes out is attached to every tag and is what
    `sdk/contract/contract.json` is projected from. A fixture that described
    paths from `config/test.exs` would put `/api/fixture/whoami` in the spec
    every Fountain release ships. The SDK contract gate catches it, which is how
    this was found.

    A real extension has the opposite requirement and needs no flag: the bundled
    distribution serves its operations, so they belong in the artifact (ADR 0043
    decision 6). #1507 must add Buzz's operations to an SDK manifest or to
    `sdk/contract/omissions.json` deliberately, rather than discovering them.
    """
    def describes_openapi_paths? do
      Application.get_env(:fountain, :extension_fixture_openapi, false)
    end

    @impl true
    def openapi_paths do
      if describes_openapi_paths?() do
        Fountain.Extensions.mounted_paths(mount(), Fountain.ExtensionFixtures.Router)
      else
        %{}
      end
    end

    @doc "What this fixture puts on the admin overview."
    def overview_label, do: "Fixture widgets"

    @impl true
    def admin_overview do
      [{overview_label(), 7, navigate: "/admin/users", note: "contributed by an extension"}]
    end

    @doc "The header of the column this fixture adds to the admin users table."
    def column_header, do: "Fixture units"

    @impl true
    def admin_user_columns do
      # A grouped query in a real extension; a constant here, because what is
      # under test is the seam and not the fixture's arithmetic. The alert form
      # is exercised so the host's highlight is covered.
      [{column_header(), %{"nobody" => %{value: 3, alert?: true}}}]
    end

    @doc "The slug of the connection provider this fixture contributes."
    def provider_slug, do: "fixture-svc"

    @doc """
    One config-backed provider, the shape a platform provider has: no
    `user_id`, the slug as its id, a plaintext client on the struct, and the
    two quirk fields the OAuth client reads (#2152). Installed in the test VM,
    so it is a row on every account's connections page and a reserved slug.
    """
    @impl true
    def connection_providers do
      [
        %Fountain.Connections.Provider{
          id: provider_slug(),
          user_id: nil,
          slug: provider_slug(),
          name: "Fixture service",
          kind: "oauth2",
          authorize_url: "https://svc.fixture.example/oauth/authorize",
          token_url: "https://svc.fixture.example/oauth/token",
          revoke_url: nil,
          userinfo_url: "https://svc.fixture.example/me",
          account_label_path: "login",
          scopes: ["read"],
          client_id: "fixture-client",
          client_secret: "fixture-secret",
          token_endpoint_auth: "client_secret_post",
          pkce: true,
          env_key: "FIXTURE_SVC_ACCESS_TOKEN",
          token_hosts: ["svc.fixture.example"],
          client_source: "manual",
          authorize_params: %{"prompt" => "fixture"}
        }
      ]
    end

    @impl true
    def conversation_mcp_servers(conversation_id, callback_token) do
      # Also serves the conversation `Exploding` blows up on, so the isolation
      # test can assert that a failing extension costs its own servers and
      # nobody else's.
      if conversation_id in [
           claimed_conversation_id(),
           Fountain.ExtensionFixtures.Exploding.trigger_conversation_id()
         ] do
        [
          %{
            "name" => "fixture",
            "type" => "http",
            "url" => "http://localhost/api/fixture/mcp/#{conversation_id}",
            "headers" => %{"authorization" => "Bearer #{callback_token}"}
          }
        ]
      else
        []
      end
    end
  end

  defmodule Disabled do
    @moduledoc "Configured but off here. Installed in the test VM."
    use Fountain.Extension, id: :fixture_disabled

    @impl true
    def enabled?, do: false

    @impl true
    def api_mounts, do: [{"/fixture-disabled", Fountain.ExtensionFixtures.Router}]

    @impl true
    def conversation_mcp_servers(_conversation_id, _callback_token) do
      [%{"name" => "disabled-should-never-appear"}]
    end

    @impl true
    def connection_providers do
      [%Fountain.Connections.Provider{id: "disabled-svc", slug: "disabled-svc", kind: "oauth2"}]
    end
  end

  defmodule Silent do
    @moduledoc "Enabled, contributes nothing. Installed in the test VM."
    use Fountain.Extension, id: :fixture_silent
  end

  defmodule Exploding do
    @moduledoc """
    Raises from `conversation_mcp_servers/2`, but only for one conversation.
    Installed in the test VM: a fixture that raised on every turn kick would be
    a landmine in every unrelated test, and one that was never installed could
    only be tested against a copy of the host's isolation logic.
    """
    use Fountain.Extension, id: :fixture_exploding

    @doc "The one conversation this fixture explodes on."
    def trigger_conversation_id, do: "22222222-2222-2222-2222-222222222222"

    @impl true
    def conversation_mcp_servers(conversation_id, _callback_token) do
      if conversation_id == trigger_conversation_id() do
        raise "fixture extension exploded"
      else
        []
      end
    end
  end

  defmodule WrongShape do
    @moduledoc "Returns a non-list, for one conversation. Installed."
    use Fountain.Extension, id: :fixture_wrong_shape

    @doc "The one conversation this fixture answers wrongly for."
    def trigger_conversation_id, do: "33333333-3333-3333-3333-333333333333"

    @impl true
    def conversation_mcp_servers(conversation_id, _callback_token) do
      if conversation_id == trigger_conversation_id(), do: :not_a_list, else: []
    end
  end

  defmodule CollidingSchemas do
    @moduledoc false

    defmodule Agent do
      @moduledoc false
      require OpenApiSpex

      # Deliberately titled "Agent", which the core already defines, and
      # deliberately a different shape. This is the collision the published spec
      # must never resolve silently: every $ref to Agent would land on whichever
      # of the two merged last, and the SDKs are generated from that spec.
      OpenApiSpex.schema(%{
        title: "Agent",
        type: :object,
        properties: %{not_the_core_agent: %OpenApiSpex.Schema{type: :boolean}}
      })
    end
  end

  defmodule CollidingController do
    @moduledoc false
    use Phoenix.Controller, formats: [:json]
    use OpenApiSpex.ControllerSpecs

    operation(:show,
      summary: "Collides on a component title",
      operation_id: "fixtureColliding",
      responses: [
        ok: {"Agent", "application/json", Fountain.ExtensionFixtures.CollidingSchemas.Agent}
      ]
    )

    def show(conn, _params), do: json(conn, %{})
  end

  defmodule CollidingRouter do
    @moduledoc false
    use Phoenix.Router

    # No scope alias: CollidingController is defined above in this file, so
    # Elixir has already auto-aliased it and Phoenix would concatenate the
    # namespace a second time.
    scope "/" do
      get "/thing", Fountain.ExtensionFixtures.CollidingController, :show
    end
  end

  defmodule Colliding do
    @moduledoc """
    Describes a component titled `Agent`, which the core also defines. NOT
    configured: composing it into the spec is supposed to raise, and it does so
    only when asked for by a test.
    """
    use Fountain.Extension, id: :fixture_colliding

    @impl true
    def api_mounts, do: [{"/colliding", Fountain.ExtensionFixtures.CollidingRouter}]

    @impl true
    def openapi_paths do
      Fountain.Extensions.mounted_paths("/colliding", Fountain.ExtensionFixtures.CollidingRouter)
    end
  end

  defmodule MissingMigrations do
    @moduledoc "Declares a migration directory that is not there. NOT configured."
    use Fountain.Extension, id: :fixture_missing_migrations

    @impl true
    def migrations, do: [{:fountain, "no_such_directory"}]
  end

  defmodule DescribesWithoutMount do
    @moduledoc "Describes an OpenAPI path it does not mount. NOT configured."
    use Fountain.Extension, id: :fixture_describes_without_mount

    @impl true
    def api_mounts, do: [{"/describes", Fountain.ExtensionFixtures.Router}]

    # Outside its own mount: it serves /api/describes/* and nothing else.
    @impl true
    def openapi_paths do
      Fountain.Extensions.mounted_paths("/somewhere-else", Fountain.ExtensionFixtures.Router)
    end
  end

  defmodule AdminRaises do
    @moduledoc """
    Raises from both admin callbacks. Deliberately NOT configured — every admin
    page render would log. `Extensions.admin_overview/1` takes a list so it can
    still be tested against the real function.
    """
    use Fountain.Extension, id: :fixture_admin_raises

    @impl true
    def admin_overview, do: raise("fixture cannot count")

    @impl true
    def admin_user_columns, do: raise("fixture cannot count either")
  end

  defmodule ProvidersRaise do
    @moduledoc """
    Raises from `connection_providers/0`. Deliberately NOT configured — it
    would fail boot validation, which is the point of one of its tests, and
    empty its own rows on every page render, which is the point of the other.
    """
    use Fountain.Extension, id: :fixture_providers_raise

    @impl true
    def connection_providers, do: raise("fixture cannot list its providers")
  end

  defmodule ProvidersTakeGoogle do
    @moduledoc "Contributes a provider on the host's own `google` slug. NOT configured."
    use Fountain.Extension, id: :fixture_providers_take_google

    @impl true
    def connection_providers do
      [%Fountain.Connections.Provider{id: "google", slug: "google", kind: "oauth2"}]
    end
  end

  defmodule ProvidersDuplicateFixture do
    @moduledoc "Contributes the slug `Enabled` already contributes. NOT configured."
    use Fountain.Extension, id: :fixture_providers_duplicate

    @impl true
    def connection_providers do
      [
        %Fountain.Connections.Provider{
          id: Fountain.ExtensionFixtures.Enabled.provider_slug(),
          slug: Fountain.ExtensionFixtures.Enabled.provider_slug(),
          kind: "oauth2"
        }
      ]
    end
  end

  defmodule ProvidersWithUser do
    @moduledoc "Contributes a provider that carries a user_id. NOT configured."
    use Fountain.Extension, id: :fixture_providers_with_user

    @impl true
    def connection_providers do
      [
        %Fountain.Connections.Provider{
          id: "tenant-svc",
          slug: "tenant-svc",
          kind: "oauth2",
          user_id: "00000000-0000-0000-0000-000000000000"
        }
      ]
    end
  end

  defmodule ProvidersMalformed do
    @moduledoc "Contributes things that are not provider structs. NOT configured."
    use Fountain.Extension, id: :fixture_providers_malformed

    @impl true
    def connection_providers, do: [%{slug: "not-a-struct"}]
  end

  defmodule ProvidersBadSlug do
    @moduledoc "Contributes a provider whose slug is not a slug. NOT configured."
    use Fountain.Extension, id: :fixture_providers_bad_slug

    @impl true
    def connection_providers do
      [%Fountain.Connections.Provider{id: "Bad Slug", slug: "Bad Slug", kind: "oauth2"}]
    end
  end

  defmodule EnabledRaises do
    @moduledoc """
    Raises from `enabled?/0`. Deliberately NOT configured — it would take every
    call to `installed/0` with it. `Extensions.installed/1` takes a list so this
    can still be tested against the real function.
    """
    use Fountain.Extension, id: :fixture_enabled_raises

    @impl true
    def enabled?, do: raise("fixture cannot decide whether it is enabled")
  end
end
