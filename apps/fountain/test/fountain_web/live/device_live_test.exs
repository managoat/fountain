defmodule FountainWeb.DeviceLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.OAuth
  alias FountainWeb.Plugs.RateLimit

  setup %{conn: conn} do
    unique = System.unique_integer([:positive, :monotonic])
    ip = {0x2001, 0xDB8, 0, 0, 0, 0, div(unique, 65_536), rem(unique, 65_536)}
    ip_string = ip |> :inet.ntoa() |> to_string()
    info = %{peer_data: %{address: ip}, x_headers: []}
    RateLimit.ensure_table()
    on_exit(fn -> :ets.delete(RateLimit.table(), {"device-lookup", ip_string}) end)
    %{conn: put_private(conn, :live_view_connect_info, info), ip: ip_string}
  end

  describe "/device — the approval half of managoat auth login --device (#1305)" do
    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth/login" <> _}}} = live(conn, ~p"/device")
    end

    test "signed out with ?code=: login round-trips back to the confirmation screen", %{
      conn: conn
    } do
      # The normal case for the flow's primary audience: `managoat auth login
      # --device` opened this URL, but the browser has no console session yet.
      # The login must come back here — the CLI is polling and the code is
      # fifteen minutes from expiry — not land on the dashboard.
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
      user = insert_verified_user(password: "correct horse battery")
      path = "/device?" <> URI.encode_query(code: user_code)

      conn = get(conn, path)
      assert redirected_to(conn) == "/auth/login"
      assert get_session(conn, :return_to) == path

      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{return_to: path})
        |> post("/auth/login", %{"email" => user.email, "password" => "correct horse battery"})

      assert redirected_to(conn) == path

      # Follow the redirect: the confirmation screen, code prefilled.
      {:ok, lv, html} = conn |> recycle() |> live(path)
      assert html =~ "Approve"
      assert html =~ user_code

      lv |> element("button", "Approve") |> render_click()
      assert {:ok, %{api_key: key}} = OAuth.poll_device_grant(device_code)
      assert key.user_id == user.id
    end

    test "the confirmation names the client, as its own claim, only when it gave a name", %{
      conn: conn
    } do
      {:ok, %{user_code: named}} = OAuth.start_device_grant(client_name: "Arugula on geek")
      {:ok, %{user_code: plain}} = OAuth.start_device_grant()
      conn = login_user(conn, insert_verified_user())

      {:ok, lv, _html} = live(conn, ~p"/device")
      lv |> element("form") |> render_submit(%{"code" => named})
      assert lv |> element("#device-client-name") |> render() =~ "Arugula on geek"
      assert lv |> element("#device-client-name") |> render() =~ "cannot verify"

      {:ok, lv, _html} = live(conn, ~p"/device")
      lv |> element("form") |> render_submit(%{"code" => plain})
      refute has_element?(lv, "#device-client-name")
    end

    test "typing the code leads to confirm, approve feeds the waiting poll", %{conn: conn} do
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
      user = insert_verified_user()

      conn = login_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/device")
      assert html =~ "Code shown in your terminal"

      html = lv |> element("form") |> render_submit(%{"code" => user_code})
      assert html =~ user_code
      assert html =~ user.email

      html = lv |> element("button", "Approve") |> render_click()
      assert html =~ "Return to your terminal"

      assert {:ok, %{api_key: key}} = OAuth.poll_device_grant(device_code)
      assert key.user_id == user.id
    end

    test "arriving with ?code= skips the typing but not the decision", %{conn: conn} do
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
      user = insert_verified_user()

      conn = login_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/device?#{[code: user_code]}")

      assert html =~ "Approve"
      assert {:error, :authorization_pending} = OAuth.poll_device_grant(device_code)

      lv |> element("button", "Deny") |> render_click()
      assert {:error, :access_denied} = OAuth.poll_device_grant(device_code)
    end

    test "a wrong code stays on the form with a flash", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/device")

      html = lv |> element("form") |> render_submit(%{"code" => "WRNG-CODE"})
      assert html =~ "Code not found"
      assert html =~ "Code shown in your terminal"
    end

    test "static query-code requests prefill without looking up grant validity", ctx do
      {:ok, %{user_code: code}} = OAuth.start_device_grant()
      conn = login_user(ctx.conn, insert_verified_user())
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:fountain, :repo, :query],
          &__MODULE__.capture_device_lookup/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      for candidate <- [code, "WRNG-CODE"] do
        html = conn |> get(~p"/device?#{[code: candidate]}") |> html_response(200)
        assert html =~ "Code shown in your terminal"
        assert html =~ candidate
        refute html =~ "Code not found"
        refute html =~ "phx-click=\"approve\""
      end

      refute_receive :device_lookup, 0
      assert :ets.lookup(RateLimit.table(), {"device-lookup", ctx.ip}) == []

      assert {:ok, _grant} = OAuth.get_device_grant_for_approval(code)
      assert_receive :device_lookup
    end

    test "query-code mounts consume one lookup and reconnects share the IP budget", ctx do
      {:ok, %{user_code: code}} = OAuth.start_device_grant()
      conn = login_user(ctx.conn, insert_verified_user())
      path = ~p"/device?#{[code: code]}"

      {:ok, view, html} = live(conn, path)
      assert html =~ "Approve"

      assert [{{"device-lookup", _ip}, _started, 1}] =
               :ets.lookup(RateLimit.table(), {"device-lookup", ctx.ip})

      # A new LiveView process must not create a fresh guessing budget.
      GenServer.stop(view.pid)
      for _ <- 1..19, do: RateLimit.bump({"device-lookup", ctx.ip}, %{max: 20, window_ms: 60_000})
      {:ok, reconnected, html} = live(conn, path)
      assert html =~ "Too many code lookups"
      refute has_element?(reconnected, "button", "Approve")
    end

    test "lookup events share their IP budget across accounts and never retain an old grant",
         ctx do
      {:ok, %{user_code: code}} = OAuth.start_device_grant()
      {:ok, view, _} = ctx.conn |> login_user(insert_verified_user()) |> live(~p"/device")

      for _ <- 1..20 do
        assert render_submit(view, "lookup", %{"code" => code}) =~ "Approve"
      end

      html = render_submit(view, "lookup", %{"code" => code})
      assert html =~ "Too many code lookups"
      refute has_element?(view, "button", "Approve")

      other_conn =
        ctx.conn
        |> login_user(insert_verified_user())
        |> put_connect_params(%{"client_ip" => "203.0.113.99"})

      {:ok, other, _} = live(other_conn, ~p"/device")
      assert render_submit(other, "lookup", %{"code" => code}) =~ "Too many code lookups"
      refute has_element?(other, "button", "Approve")

      # A blocked lookup cannot leave an earlier grant available to a forged event.
      render_click(view, "approve", %{})
      assert {:ok, _grant} = OAuth.get_device_grant_for_approval(code)

      # The fixed window expires and the same IP can try again.
      key = {"device-lookup", ctx.ip}
      :ets.insert(RateLimit.table(), {key, System.system_time(:millisecond) - 60_001, 20})
      assert render_submit(other, "lookup", %{"code" => code}) =~ "Approve"
      assert has_element?(other, "button", "Approve")
    end
  end

  def capture_device_lookup(_event, _measurements, metadata, owner) do
    if self() == owner and metadata[:source] == "oauth_device_grants" do
      send(owner, :device_lookup)
    end
  end
end
