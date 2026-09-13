defmodule FountainWeb.AgentsLive.IndexTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Agents.ModelCatalog

  describe "index" do
    test "renders agent list for authenticated user", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ agent.name
      assert html =~ "+ New agent"
      assert html =~ "Edit"
    end

    test "renders empty state when user has no agents", %{conn: conn} do
      # Verification plants the starter agent (ADR 0038), so an account with no
      # agents is now one that deleted it — still a state the page has to draw.
      user = insert_user_without_agents()
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "No agents yet"
    end

    test "new agent button uses plain href (not LiveView navigate)", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents")

      # Must be a plain href so the browser always performs a real navigation.
      # Regression: navigate= was a no-op in some LiveSocket states (e.g. after
      # visiting a conversation page where JS hooks had been mounted).
      assert has_element?(view, ~s(a[href="/agents/new"]))
      refute has_element?(view, ~s(a[data-phx-link][href="/agents/new"]))
    end

    test "edit button uses plain href (not LiveView navigate)", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents")

      assert has_element?(view, ~s(a[href="/agents/#{agent.id}/edit"]))
      refute has_element?(view, ~s(a[data-phx-link][href="/agents/#{agent.id}/edit"]))
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/agents")
      assert path =~ "/auth/login"
    end
  end

  describe "new" do
    test "renders new agent form for authenticated user", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/new")

      assert html =~ "New agent"
      assert html =~ "phx-submit"
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/agents/new")
      assert path =~ "/auth/login"
    end

    # The form's default and placeholder are stronger claims than a catalog
    # suggestion: a suggestion has to be chosen, a default is what you get by
    # doing nothing, and a placeholder is what you get by typing the hint. All
    # three had been outside the refused-id guard, so `claude-sonnet-4-6`
    # stayed the default and `gpt-5.3-codex` the codex placeholder through the
    # clean-up that removed both from the catalog (#1669). Every agent created
    # by accepting the default then failed every turn at `session/set_model`.
    #
    # The assertion is catalog membership, not absence from the refused list,
    # because a default goes stale two ways and the refused list only sees one.
    # `gpt-5-codex` was *retired* on 2026-08-22 while it was both the codex
    # suggestion and the codex placeholder (model_catalog.ex records it as the
    # worse defect of the two). A retired id never becomes an adapter refusal,
    # so it never enters `RefusedModels` — but it does leave the catalog, and
    # so does a refused one. `ModelCatalog.known?/1` catches both paths.
    test "the model default and every placeholder are current catalog entries", %{conn: conn} do
      conn = login_user(conn, insert_verified_user())

      {:ok, view, html} = live(conn, ~p"/agents/new")

      # The prefilled default. `unknown_model?/1` drives the pass-through hint,
      # so the hint firing on a freshly mounted form *is* the bug: the form
      # telling the user its own default is not one Fountain lists.
      refute html =~ "passed to the runtime as-is",
             "the new-agent form's own default is not in the catalog"

      assert ModelCatalog.known?(model_value(html)),
             "the new-agent form defaults to #{model_value(html)}, which is not in the catalog"

      # Each runtime swaps the placeholder, so check them all rather than the
      # one that happens to render first.
      for runtime <- Fountain.Agents.Agent.runtimes() do
        rendered =
          view
          |> element("form[phx-change=validate]")
          |> render_change(%{"agent" => %{"name" => "x", "runtime" => runtime, "model" => ""}})

        placeholder = model_placeholder_value(rendered)

        assert ModelCatalog.known?(placeholder),
               "the #{runtime} placeholder is #{placeholder}, which is not in the catalog"

        refute placeholder in Fountain.RefusedModels.ids(),
               "the #{runtime} placeholder is #{placeholder}, which the pinned adapter refuses"
      end
    end

    # Onboarding asks for Anthropic only; the first model that needs another
    # provider is where its key is collected.
    test "prompts for the provider's key when the chosen model has none on the account", %{
      conn: conn
    } do
      user = insert_verified_user()
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, _} =
        Fountain.InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant")

      conn = login_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/agents/new")
      # default model is Anthropic → nothing to ask
      refute html =~ "No OpenAI API key"
      refute html =~ "credential on this account yet"

      html =
        view
        |> element("form[phx-change=validate]")
        |> render_change(%{
          "agent" => %{"name" => "x", "runtime" => "codex", "model" => "openai/gpt-5"}
        })

      assert html =~ "No OpenAI credential on this account yet"
      assert html =~ ~s(value="openai_api_key")

      # back to an Anthropic model: the card goes away
      html =
        view
        |> element("form[phx-change=validate]")
        |> render_change(%{
          "agent" => %{
            "name" => "x",
            "runtime" => "claude",
            "model" => "anthropic/claude-sonnet-5"
          }
        })

      refute html =~ "credential on this account yet"

      # a model from a provider Fountain doesn't know needs nothing
      html =
        view
        |> element("form[phx-change=validate]")
        |> render_change(%{
          "agent" => %{"name" => "x", "runtime" => "opencode", "model" => "ollama/llama3"}
        })

      refute html =~ "credential on this account yet"
    end

    # #554: the model field was a bare text input, so nothing in the UI said
    # what a valid value looked like until the sprite failed at spawn time.
    test "model field offers the curated models for the selected runtime", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/agents/new")

      assert html =~ ~s(list="model-options")

      for model <- ModelCatalog.suggestions("claude") do
        assert has_element?(view, ~s(datalist#model-options option[value="#{model}"]))
      end

      # Switching runtime re-scopes the list — codex can't reach an
      # anthropic/ model, and the changeset rejects one.
      #
      # Derived from the catalog, not hard-coded: this assertion named
      # `openai/gpt-5.3-codex` until #1669, so it kept passing after that id
      # was removed from the catalog for being refused by the pinned adapter —
      # it was matching the placeholder instead, and thereby pinning the bug.
      html = render_change(view, "validate", %{"agent" => %{"runtime" => "codex"}})

      for model <- ModelCatalog.suggestions("codex") do
        assert has_element?(view, ~s(datalist#model-options option[value="#{model}"]))
      end

      refute html =~ "anthropic/claude-opus-5"
    end

    test "an unlisted model id is flagged as pass-through, not as an error", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents/new")

      listed =
        render_change(view, "validate", %{
          "agent" => %{"runtime" => "claude", "model" => "anthropic/claude-opus-5"}
        })

      refute listed =~ "passed to the runtime as-is"

      unlisted =
        render_change(view, "validate", %{
          "agent" => %{"runtime" => "claude", "model" => "anthropic/claude-opus-99"}
        })

      assert unlisted =~ "passed to the runtime as-is"

      # A bad provider is a real error, not a pass-through — stay quiet and
      # let the changeset speak on submit.
      bad_provider =
        render_change(view, "validate", %{
          "agent" => %{"runtime" => "opencode", "model" => "anthopic/claude-opus-5"}
        })

      refute bad_provider =~ "passed to the runtime as-is"
    end
  end

  describe "the acp runtime in the console (#1634)" do
    test "the command field appears when the runtime is acp, and saves", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/agents/new")
      refute html =~ "agent[runtime_command]"

      html =
        view
        |> element("form[phx-change=validate]")
        |> render_change(%{"agent" => %{"name" => "converger", "runtime" => "acp"}})

      assert html =~ "agent[runtime_command]"
      assert html =~ "It needs no model and no inference key"
      # The model field is inert here, so it is disabled and nobody is asked
      # for a key to run it.
      assert has_element?(view, "input#model[disabled]")
      refute html =~ "credential on this account yet"

      view
      |> form("#agent-form", %{
        "agent" => %{
          "name" => "converger",
          "runtime" => "acp",
          "runtime_command" => "chant acp --env prod"
        }
      })
      |> render_submit()

      agent = Fountain.Agents.get_agent_by_name("converger", user.id)
      assert agent.runtime == "acp"
      assert agent.runtime_command == "chant acp --env prod"
      assert is_nil(agent.model)
    end

    test "switching an acp agent onto a model runtime drops the command", %{conn: conn} do
      user = insert_verified_user()

      agent =
        insert_agent(user_id: user.id, runtime: "acp", runtime_command: "chant acp")

      conn = login_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/agents/#{agent.id}/edit")
      # The model field is inert on this runtime, so the form disables it.
      assert has_element?(view, "input#model[disabled]")

      # And on first paint its owner is not asked for an Anthropic key to run
      # an agent that needs none (#1634).
      refute html =~ "credential on this account yet"

      # Picking a model runtime re-renders the form: the model comes back and
      # the command goes away, which is what the browser does on change.
      html =
        view
        |> element("form[phx-change=validate]")
        |> render_change(%{"agent" => %{"name" => agent.name, "runtime" => "claude"}})

      refute html =~ "agent[runtime_command]"

      # Submitted with the stale command still in the params, which is what a
      # submit that crosses the re-render sends. The changeset refuses a
      # command on this runtime, so the form has to drop it rather than
      # forward it into a 422 the person cannot act on.
      view
      |> element("form[phx-change=validate]")
      |> render_submit(%{
        "agent" => %{
          "name" => agent.name,
          "runtime" => "claude",
          "model" => "anthropic/claude-sonnet-5",
          "runtime_command" => "chant acp"
        }
      })

      reloaded = Fountain.Agents.get_agent(agent.id, user.id)
      assert reloaded.runtime == "claude"
      assert reloaded.model == "anthropic/claude-sonnet-5"
      assert is_nil(reloaded.runtime_command)
    end
  end

  describe "edit" do
    test "renders edit form for existing agent", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      assert html =~ "Edit agent"
      assert html =~ agent.name
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/agents/#{agent.id}/edit")
      assert path =~ "/auth/login"
    end
  end

  describe "permission policy (#939)" do
    test "the form shows what answers before the agent runs a tool", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, permission_policy: %{"default" => "ask"})
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      assert html =~ "Before the agent runs a tool"
      assert html =~ "Ask a human"
      # The stored default is the one selected, rather than the field showing
      # allow while the row says otherwise.
      assert html =~ ~r/<option value="ask" selected/
    end

    test "saving stores the default and the per-kind overrides", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")

      view
      |> form("#agent-form", %{
        "agent" => %{
          "name" => agent.name,
          "model" => agent.model,
          "runtime" => agent.runtime,
          "permission_default" => "ask",
          "permission_kinds" => %{"execute" => "auto_deny", "read" => ""}
        }
      })
      |> render_submit()

      assert %{"default" => "ask", "execute" => "auto_deny"} =
               Fountain.Agents.get_agent(agent.id, user.id).permission_policy
    end

    test "an untouched form leaves the policy empty rather than writing a default", %{conn: conn} do
      # Every agent predates this field. Saving an unrelated edit must not
      # start writing `%{"default" => "auto_allow"}` into rows that had `%{}`,
      # which would read as a policy someone chose.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")

      view
      |> form("#agent-form", %{
        "agent" => %{
          "name" => "renamed",
          "model" => agent.model,
          "runtime" => agent.runtime
        }
      })
      |> render_submit()

      assert Fountain.Agents.get_agent(agent.id, user.id).permission_policy == %{}
    end

    test "a runtime that never asks says so instead of offering the choice", %{conn: conn} do
      # opencode decides permission in its own server and sends no request
      # (#959), so a policy here would display a restriction nothing enforces.
      user = insert_verified_user()

      agent =
        insert_agent(user_id: user.id, runtime: "opencode", model: "anthropic/claude-sonnet-5")

      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      assert html =~ "decides this inside its own server"
      assert html =~ "disabled"
    end
  end

  # The model input renders `value=` before `placeholder=` (form.ex), and both
  # sit on the one element with id="model".
  defp model_value(html) do
    [_, value] = Regex.run(~r/<input[^>]*id="model"[^>]*value="([^"]*)"/, html)
    value
  end

  defp model_placeholder_value(html) do
    [_, value] = Regex.run(~r/<input[^>]*id="model"[^>]*placeholder="([^"]*)"/, html)
    value
  end
end

defmodule FountainWeb.AgentsLive.NetworkPolicyNoteTest do
  # async: false because it flips `:runners_enabled`, which is application-wide
  # config the rest of the suite reads to decide which providers are enabled.
  # `:runner` is the only adapter in tree without `:network_policy`, so it is
  # the only pairing that can express this.
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous = Application.get_env(:fountain, :runners_enabled)
    Application.put_env(:fountain, :runners_enabled, true)
    on_exit(fn -> Application.put_env(:fountain, :runners_enabled, previous) end)
    :ok
  end

  describe "network policy the backend cannot enforce (#935)" do
    # The provider is per agent (ADR 0018) and the egress policy is per
    # environment, so the agent form is the only console page where both are
    # known. Without this the pairing is discovered by a conversation dying
    # mid-provision.
    test "warns when a limited environment is paired with a backend that has no policy", %{
      conn: conn
    } do
      user = insert_verified_user()
      env = insert_env(user_id: user.id, networking_type: "limited", networking_config: %{})

      agent =
        insert_agent(user_id: user.id, environment_id: env.id, sandbox_provider: "runner")

      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      assert html =~ "cannot hold a limited environment"
      assert html =~ "runner"
    end

    test "no warning when the backend advertises a network policy", %{conn: conn} do
      user = insert_verified_user()
      env = insert_env(user_id: user.id, networking_type: "limited", networking_config: %{})

      # No pin, so the agent runs on the instance default. That is sprites,
      # which advertises `:network_policy`, as do e2b and daytona.
      agent = insert_agent(user_id: user.id, environment_id: env.id)

      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      refute html =~ "cannot hold a limited environment"
    end

    test "no warning when the environment is unrestricted", %{conn: conn} do
      user = insert_verified_user()
      env = insert_env(user_id: user.id, networking_type: "unrestricted")

      agent =
        insert_agent(user_id: user.id, environment_id: env.id, sandbox_provider: "runner")

      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      refute html =~ "cannot hold a limited environment"
    end
  end
end

defmodule FountainWeb.AgentsLive.ConnectionsFormTest do
  # async: false because it turns the broker on (application-wide config).
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Fountain.BrokerTestHelpers

  defp with_credential(user) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

    {:ok, _} =
      Fountain.InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant-x")

    user
  end

  describe "MCP servers that are not a command (#1178)" do
    test "a connection can be attached as an MCP server and survives a later save", %{conn: conn} do
      user = with_credential(insert_verified_user())
      enable_connections()
      connection = insert_connection(user, account_email: "me@example.com")
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      html = view |> element("button", "+ Add server") |> render_click()
      assert html =~ "Connected account"

      # Switching the type reveals the connection select.
      html =
        view
        |> element("form[phx-change=validate]")
        |> render_change(%{
          "agent" => %{"mcp_servers" => %{"0" => %{"name" => "gmail", "kind" => "connection"}}}
        })

      assert html =~ "me@example.com (google)"

      view
      |> form("#agent-form", %{
        "agent" => %{
          "name" => agent.name,
          "model" => agent.model,
          "runtime" => agent.runtime,
          "mcp_servers" => %{
            "0" => %{"name" => "gmail", "kind" => "connection", "connection" => connection.id}
          }
        }
      })
      |> render_submit()

      assert %{"gmail" => %{"connection" => id}} =
               Fountain.Agents.get_agent(agent.id, user.id).mcp_servers

      assert id == connection.id

      # Reopen and save with no change to the row: the entry is kept.
      {:ok, view, html} = live(conn, ~p"/agents/#{agent.id}/edit")
      assert html =~ "me@example.com (google)"

      view
      |> form("#agent-form", %{
        "agent" => %{"name" => agent.name, "model" => agent.model, "runtime" => agent.runtime}
      })
      |> render_submit()

      assert %{"gmail" => %{"connection" => ^id}} =
               Fountain.Agents.get_agent(agent.id, user.id).mcp_servers
    end

    test "a remote server written through the API survives a save from the form", %{conn: conn} do
      user = with_credential(insert_verified_user())
      remote = %{"type" => "http", "url" => "https://mcp.example.com/sse"}
      agent = insert_agent(user_id: user.id, mcp_servers: %{"remote" => remote})
      conn = login_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/agents/#{agent.id}/edit")
      assert html =~ "kept as is"

      view
      |> form("#agent-form", %{
        "agent" => %{"name" => "renamed", "model" => agent.model, "runtime" => agent.runtime}
      })
      |> render_submit()

      assert Fountain.Agents.get_agent(agent.id, user.id).mcp_servers == %{"remote" => remote}
    end
  end
end

defmodule FountainWeb.AgentsLive.FreshAccountTest do
  # This test enables two instance-level sandbox providers so the selector
  # participates in the browser form; other suites read the same config.
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "credential validation preserves a fresh account's complete agent form", %{conn: conn} do
    adapter = Managoat.Sandbox.Sprites
    previous = Application.get_env(:managoat_sandbox, adapter, [])
    runners = Application.get_env(:fountain, :runners_enabled)
    Application.put_env(:fountain, :runners_enabled, true)
    on_exit(fn -> Application.put_env(:fountain, :runners_enabled, runners) end)

    Application.put_env(
      :managoat_sandbox,
      adapter,
      Keyword.put(previous, :token, "test-provider")
    )

    on_exit(fn -> Application.put_env(:managoat_sandbox, adapter, previous) end)

    user = insert_verified_user()
    conn = login_user(conn, user)
    {:ok, view, html} = live(conn, ~p"/agents/new")
    assert html =~ "credential on this account yet"

    assert has_element?(
             view,
             ~s(form[phx-submit=submit] select[name="agent[sandbox_provider]"])
           )

    refute has_element?(view, "form form")
    model = hd(Fountain.Agents.ModelCatalog.suggestions("codex"))

    params = %{
      "name" => "fresh-form-regression",
      "description" => "Keep this description",
      "system" => "Keep this prompt",
      "runtime" => "codex",
      "model" => model,
      "sandbox_provider" => "runner"
    }

    view |> form("form[phx-submit=submit]", %{"agent" => params}) |> render_change()

    assert view
           |> form("form[phx-submit=save_credential]", %{"value" => ""})
           |> render_submit() =~ "Paste a value before saving."

    assert has_element?(view, ~s(input[name="agent[name]"][value="fresh-form-regression"]))
    assert has_element?(view, ~s(input[name="agent[model]"][value="#{model}"]))
    assert Fountain.Agents.get_agent_by_name(params["name"], user.id) == nil

    view |> form("form[phx-submit=submit]", %{"agent" => params}) |> render_submit()
    agent = Fountain.Agents.get_agent_by_name(params["name"], user.id)
    assert agent.runtime == "codex"
    assert agent.model == model
    assert agent.sandbox_provider == "runner"
    assert agent.description == params["description"]
    assert agent.system == params["system"]
    assert Fountain.InferenceCredentials.missing_for_model(user.id, model) != nil
  end
end
