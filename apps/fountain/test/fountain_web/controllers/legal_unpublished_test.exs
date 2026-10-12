# async: false — these tests mutate the global :legal app env, which
# concurrent tests (the front door) also read.
defmodule FountainWeb.LegalUnpublishedTest do
  use FountainWeb.ConnCase, async: false

  setup do
    legal = Application.get_env(:fountain, :legal)
    on_exit(fn -> Application.put_env(:fountain, :legal, legal) end)

    :ok
  end

  describe "legal identity unset (self-host default)" do
    setup do
      Application.put_env(:fountain, :legal, nil)
      :ok
    end

    test "/terms renders a neutral 404 instead of placeholders", %{conn: conn} do
      body = conn |> get(~p"/terms") |> html_response(404)
      assert body =~ "No published terms"
      refute body =~ "{{"
      refute body =~ "Terms of Service"
    end

    test "/privacy renders a neutral 404 instead of placeholders", %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(404)
      assert body =~ "No published terms"
      refute body =~ "{{"
      refute body =~ "Privacy Policy"
    end

    test "registration form hides the terms/privacy agreement line", %{conn: conn} do
      body = conn |> get(~p"/auth/register") |> html_response(200)
      refute body =~ ~p"/terms"
      refute body =~ ~p"/privacy"
      refute body =~ "By signing up you agree"
    end

    test "marketing footer hides the terms/privacy links", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      refute body =~ ~p"/terms"
      refute body =~ ~p"/privacy"
    end
  end
end
