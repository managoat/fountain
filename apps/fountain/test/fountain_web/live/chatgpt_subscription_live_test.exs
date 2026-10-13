defmodule FountainWeb.ChatGPTSubscriptionLiveTest do
  @moduledoc """
  The ChatGPT subscription card (ADR 0070) on `/account/inference-credentials`
  and `/admin/inference`: the device-code sign-in polled by the page's own
  process, the pasted `auth.json`, and disconnect. auth.openai.com is a
  `Req.Test` stub the LiveView process is allowed to use.
  """

  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.{Accounts, Audit, ChatGPT}

  @auth_claim "https://api.openai.com/auth"

  test "a user links with a device code the page polls for", %{conn: conn} do
    user = insert_verified_user()
    {:ok, view, html} = live(login_user(conn, user), ~p"/account/inference-credentials")
    assert html =~ "ChatGPT subscription"
    Req.Test.allow(Fountain.ChatGPT.OAuth, self(), view.pid)

    test = self()

    Req.Test.stub(Fountain.ChatGPT.OAuth, fn conn ->
      send(test, {:auth, conn.request_path})

      case conn.request_path do
        "/api/accounts/deviceauth/usercode" ->
          Req.Test.json(conn, %{
            "user_code" => "ABCD-1234",
            "device_auth_id" => "dev_1",
            "interval" => 1
          })

        "/api/accounts/deviceauth/token" ->
          Req.Test.json(conn, %{"authorization_code" => "code_1", "code_verifier" => "ver_1"})

        "/oauth/token" ->
          Req.Test.json(conn, %{
            "access_token" => "at_1",
            "refresh_token" => "rt_1",
            "id_token" => id_token()
          })
      end
    end)

    html = view |> element("button", "Link with a code") |> render_click()
    assert html =~ "ABCD-1234"
    refute ChatGPT.active?({:user, user.id})

    # The poll the page scheduled for itself, delivered now.
    %{chatgpt_device: %{ref: ref}} = :sys.get_state(view.pid).socket.assigns
    send(view.pid, {:chatgpt_poll, ref})
    html = render(view)

    assert html =~ "ChatGPT subscription linked."
    refute html =~ "ABCD-1234"
    assert ChatGPT.active?({:user, user.id})
    assert_received {:auth, "/oauth/token"}

    assert Enum.any?(
             Audit.list_recent_for_user(user.id),
             &(&1.action == "chatgpt_subscription.connected" and &1.actor == "ui" and
                 &1.metadata["method"] == "device_code")
           )

    html =
      view
      |> element("button", "Disconnect")
      |> render_click()

    assert html =~ "Disconnected."
    refute ChatGPT.get({:user, user.id})
  end

  test "a pasted auth.json links, and a wrong one says why", %{conn: conn} do
    user = insert_verified_user()
    {:ok, view, _html} = live(login_user(conn, user), ~p"/account/inference-credentials")

    html =
      view
      |> form("#chatgpt-paste", auth_json: ~s({"auth_mode":"apikey","tokens":{}}))
      |> render_submit()

    assert html =~ "not a ChatGPT sign-in"

    html = view |> form("#chatgpt-paste", auth_json: auth_json()) |> render_submit()
    assert html =~ "ChatGPT subscription linked."
    assert %{account_id: "acct_1", plan_type: "plus"} = ChatGPT.get({:user, user.id})
  end

  test "an admin links the deployment's subscription", %{conn: conn} do
    {:ok, admin} = Accounts.update_user_role(insert_active_user(), "admin")
    {:ok, view, html} = live(login_user(conn, admin), ~p"/admin/inference")
    assert html =~ "The deployment&#39;s ChatGPT subscription"

    view |> form("#chatgpt-paste", auth_json: auth_json()) |> render_submit()

    assert %{user_id: nil} = ChatGPT.get(:platform)
    assert ChatGPT.get({:user, admin.id}) == nil

    assert [%{event_type: "admin.platform_chatgpt.connected"} | _] =
             Audit._unsafe_list_recent_admin(5)
  end

  defp id_token do
    payload =
      %{@auth_claim => %{"chatgpt_account_id" => "acct_1", "chatgpt_plan_type" => "plus"}}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    "eyJhbGciOiJub25lIn0." <> payload <> ".sig"
  end

  defp auth_json do
    Jason.encode!(%{
      "auth_mode" => "chatgpt",
      "tokens" => %{"id_token" => id_token(), "access_token" => "at_1", "refresh_token" => "rt_1"}
    })
  end
end
