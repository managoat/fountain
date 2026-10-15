defmodule FountainWeb.RetiredBrowserRoutesTest do
  # App configuration is global; restore it after each test.
  use FountainWeb.ConnCase, async: false

  @retired_paths [
    "/conversations",
    "/conversations/new",
    "/conversations/abc123",
    "/conversations/abc123/logs",
    "/team",
    "/team/agent-1"
  ]

  setup do
    original = Application.fetch_env(:fountain, :conversations_app_url)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:fountain, :conversations_app_url, value)
        :error -> Application.delete_env(:fountain, :conversations_app_url)
      end
    end)

    Application.put_env(:fountain, :conversations_app_url, "https://apps.test/convs/")
    %{user: insert_verified_user()}
  end

  for apps? <- [true, false] do
    test "retired paths return 404 for every reader with apps configured: #{apps?}", %{user: user} do
      unless unquote(apps?) do
        Application.put_env(:fountain, :conversations_app_url, "")
      end

      for conn <- [build_conn(), login_user(build_conn(), user)], path <- @retired_paths do
        response = get(conn, path)
        assert response(response, 404)
        assert get_resp_header(response, "location") == []
      end
    end
  end

  test "current console and catalog links use the configured apps", %{conn: conn, user: user} do
    conversation = insert_conversation(user_id: user.id)
    html = conn |> login_user(user) |> get("/dashboard") |> html_response(200)

    assert html =~ ~s(href="https://apps.test/convs/")
    assert html =~ ~s(href="https://apps.test/convs/#/new")
    assert html =~ ~s(href="https://apps.test/convs/#/c/#{conversation.id}")
    refute html =~ ~r/href="\/(?:conversations|team)(?:\/|\?|"|#)/

    assert catalog_apps(user) == %{"conversations" => "https://apps.test/convs/"}
  end

  test "a deployment without apps omits their links and still serves the dashboard", %{
    conn: conn,
    user: user
  } do
    Application.put_env(:fountain, :conversations_app_url, "")
    insert_conversation(user_id: user.id)
    html = conn |> login_user(user) |> get("/dashboard") |> html_response(200)

    refute html =~ "apps.test/"
    refute html =~ ~r/href="\/(?:conversations|team)(?:\/|\?|"|#)/
    assert catalog_apps(user) == %{"conversations" => nil}
  end

  defp catalog_apps(user) do
    {_key, raw_key} = insert_api_key(user)

    build_conn()
    |> authed_with_key(raw_key)
    |> get("/api/catalog")
    |> json_response(200)
    |> get_in(["data", "apps"])
  end
end
