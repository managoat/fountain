# async: false — these set the global :registration_access_code.
defmodule FountainWeb.RegistrationAccessCodeTest do
  @moduledoc """
  `REGISTRATION_ACCESS_CODE` on the three signup doors: the form, the JSON
  endpoint, and GitHub, whose code has to survive the OAuth round trip in the
  session.
  """

  use FountainWeb.ConnCase, async: false
  use Oban.Testing, repo: Fountain.Repo

  alias Fountain.Accounts

  setup do
    previous = Application.get_env(:fountain, :registration_access_code)
    Application.put_env(:fountain, :registration_access_code, "trythegoat")
    on_exit(fn -> Application.put_env(:fountain, :registration_access_code, previous) end)
  end

  defp github_auth(email) do
    %Ueberauth.Auth{
      provider: :github,
      uid: "gh_#{System.unique_integer([:positive])}",
      info: %Ueberauth.Auth.Info{email: email},
      credentials: %Ueberauth.Auth.Credentials{},
      extra: %Ueberauth.Auth.Extra{
        raw_info: %{
          user: %{"emails" => [%{"email" => email, "primary" => true, "verified" => true}]}
        }
      }
    }
  end

  describe "request logging" do
    test "redacts the code on the form and the JSON shapes, and still redacts the rest" do
      filtered =
        Phoenix.Logger.filter_values(%{
          "access_code" => "trythegoat",
          "password" => "hunter22",
          "token" => "t0k3n",
          "user" => %{"access_code" => "trythegoat", "password" => "hunter22"}
        })

      assert filtered == %{
               "access_code" => "[FILTERED]",
               "password" => "[FILTERED]",
               "token" => "[FILTERED]",
               "user" => %{"access_code" => "[FILTERED]", "password" => "[FILTERED]"}
             }
    end
  end

  describe "the form" do
    test "asks for the code, and GitHub signup submits it", %{conn: conn} do
      body = conn |> get(~p"/auth/register") |> html_response(200)
      assert body =~ ~s(name="user[access_code]")
      assert body =~ ~s(formaction="/auth/register/github")
      refute body =~ ~s(href="/auth/oauth/github")
    end

    test "without the code: 403, the error on the code field, no account", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/register", %{
          "user" => %{"email" => "form-nocode@example.com", "password" => "password123"}
        })

      assert html_response(conn, 403) =~ "needs a valid access code"
      refute Accounts.get_user_by_email("form-nocode@example.com")
    end

    test "with the code: the account is created", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/register", %{
          "user" => %{
            "email" => "form-code@example.com",
            "password" => "password123",
            "access_code" => "trythegoat"
          }
        })

      assert redirected_to(conn) == ~p"/auth/check-email"
      assert Accounts.get_user_by_email("form-code@example.com")
    end
  end

  describe "POST /api/auth/register" do
    defp api_register(conn, body) do
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/auth/register", Jason.encode!(body))
    end

    test "refuses without the code", %{conn: conn} do
      conn = api_register(conn, %{email: "api-nocode@example.com", password: "password123"})
      assert %{"error" => "access_code_required"} = json_response(conn, 403)
    end

    test "creates the account with it", %{conn: conn} do
      conn =
        api_register(conn, %{
          email: "api-code@example.com",
          password: "password123",
          access_code: "trythegoat"
        })

      assert %{"user_id" => _} = json_response(conn, 201)
    end
  end

  describe "GitHub signup" do
    test "a wrong code never leaves for GitHub", %{conn: conn} do
      conn = post(conn, ~p"/auth/register/github", %{"user" => %{"access_code" => "nope"}})

      assert html_response(conn, 403) =~ "needs a valid access code"
      refute get_session(conn, :registration_access_code)
    end

    test "the right code rides the round trip and creates the account", %{conn: conn} do
      conn = post(conn, ~p"/auth/register/github", %{"user" => %{"access_code" => "trythegoat"}})
      assert redirected_to(conn) == ~p"/auth/oauth/github"

      conn =
        conn
        |> recycle()
        |> assign(:ueberauth_auth, github_auth("gh-code@example.com"))
        |> get(~p"/auth/oauth/github/callback")

      assert redirected_to(conn) == ~p"/start"
      assert Accounts.get_user_by_email("gh-code@example.com")
      refute get_session(conn, :registration_access_code)
    end

    test "a first GitHub sign-in without the code goes back to signup", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> assign(:ueberauth_auth, github_auth("gh-nocode@example.com"))
        |> get(~p"/auth/oauth/github/callback")

      assert redirected_to(conn) == ~p"/auth/register"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "needs an access code"
      refute Accounts.get_user_by_email("gh-nocode@example.com")
    end
  end
end
