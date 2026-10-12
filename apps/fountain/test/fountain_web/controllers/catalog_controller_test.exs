defmodule FountainWeb.CatalogControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    {:ok, raw_key: raw_key}
  end

  test "GET /api/catalog lists the form vocabulary", %{conn: conn, raw_key: key} do
    body = conn |> authed_with_key(key) |> get("/api/catalog") |> json_response(200)
    data = body["data"]

    assert data["sandbox_api_access"] == ["owner", "none"]
    assert data["runtimes"] == Fountain.Agents.Agent.runtimes()
    assert data["models"]["claude"] == Fountain.Agents.ModelCatalog.suggestions("claude")
    refute Map.has_key?(data["models"], "opencode")
    assert data["model_providers"] == Fountain.Agents.ModelCatalog.providers()
    assert is_list(data["sandbox_providers"]["enabled"])
    assert data["sandbox_providers"]["default"] in Fountain.SandboxProviders.known_providers()
    assert data["package_managers"] == ["apt", "npm"]

    assert length(data["mcp_servers"]) ==
             length(Fountain.Connections.McpServerCatalog.entries())

    linear = Enum.find(data["mcp_servers"], &(&1["slug"] == "linear"))
    assert linear["name"] == "Linear"
    assert linear["url"] == "https://mcp.linear.app/mcp"
    assert linear["dcr"] == true
    assert {:ok, _} = Date.from_iso8601(linear["verified_on"])
  end

  # ADR 0038: the landing, the manual and `fountain auth register` print the
  # same request, so it has one source. This is how a client that is not the
  # server reaches it.
  test "GET /api/catalog carries the first request", %{conn: conn, raw_key: key} do
    body = conn |> authed_with_key(key) |> get("/api/catalog") |> json_response(200)
    first = body["data"]["first_request"]

    assert first["curl"] == Fountain.Onboarding.curl(base_url: Fountain.PublicUrl.base())

    # The SDK resolves its own key and base URL, so its snippet keeps the bare
    # constructor the manual prints; a base URL with no key beside it would
    # look finished and would not be.
    assert first["typescript"] == Fountain.Onboarding.typescript()
    assert first["typescript"] =~ "new Fountain()"

    assert first["prompt"] == Fountain.Onboarding.prompt()
    # Only what a client must still substitute: the base URL is already in.
    assert first["placeholders"] ==
             Fountain.Onboarding.remaining_placeholders(first["curl"] <> first["typescript"])

    refute "$FOUNTAIN_BASE_URL" in first["placeholders"]

    # The base URL is filled in, because the server knows it.
    assert first["curl"] =~ Fountain.PublicUrl.base()
    refute first["curl"] =~ "$FOUNTAIN_BASE_URL"

    # The key is not, and cannot be: only a hash of it is stored.
    assert first["curl"] =~ "$FOUNTAIN_API_KEY"
    refute first["curl"] =~ key

    # Every token a client must still substitute is named, so it does not
    # have to scrape them out of the text.
    for token <- first["placeholders"] do
      assert String.contains?(first["curl"] <> first["typescript"], token)
    end
  end

  test "401 without a key", %{conn: conn} do
    assert conn |> get("/api/catalog") |> json_response(401)
  end
end
