defmodule FountainWeb.ChromeTest do
  use FountainWeb.ConnCase, async: true

  # The console's name and icons are Managoat's, built in (ADR 0082). There is
  # no PRODUCT_NAME or BRAND_ASSETS_URL to change them.

  test "the sign-in page and its title say Managoat", %{conn: conn} do
    html = conn |> get(~p"/auth/login") |> html_response(200)
    assert html =~ "Sign in to Managoat"
    assert html =~ "<title>Managoat</title>"
  end

  test "the console header shows the built-in icon and name", %{conn: conn} do
    user = Fountain.Factory.insert_verified_user()
    html = conn |> login_user(user) |> get(~p"/dashboard") |> html_response(200)
    assert html =~ ~s(src="/images/app-icon.png")
    assert html =~ "Managoat"
  end

  test "every icon the root layout links ships in the release", %{conn: conn} do
    # A link to a file the image does not carry is a 404 that nothing else
    # catches: the page around it renders perfectly.
    html = conn |> get(~p"/auth/login") |> html_response(200)
    static = Path.expand("../../priv/static", __DIR__)

    links =
      ~r{(?:href|src|content)="(?:https?://[^/"]+)?(/(?:images/[\w.-]+|favicon\.ico))"}
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    for path <- ~w(/favicon.ico /images/favicon-32x32.png /images/favicon-16x16.png
                   /images/apple-touch-icon.png) do
      assert path in links, "the root layout no longer links #{path}"
    end

    for path <- links do
      assert File.exists?(Path.join(static, path)),
             "#{path} is linked and the release has no such file"
    end
  end

  test "the CSP admits images from this origin and data: only", %{conn: conn} do
    [csp] = conn |> get(~p"/auth/login") |> get_resp_header("content-security-policy")
    assert csp =~ "img-src 'self' data:;"
  end
end
