defmodule FountainWeb.VerifyPendingLiveTest do
  use FountainWeb.ConnCase, async: true
  use Oban.Testing, repo: Fountain.Repo

  import Phoenix.LiveViewTest

  alias Fountain.Accounts
  alias Fountain.Repo
  alias Fountain.Workers.VerificationEmail

  # Every advance off this page is out of band: the LiveView re-reads the row
  # on a broadcast or on its own poll, redirects, and the test proxy relays
  # that to this process. `assert_redirect/2` waits ExUnit's
  # `assert_receive_timeout` — 100 ms — for the whole round trip, which is
  # thin under a partition running 20 cases at once. Measured over 20 advances
  # on a loaded machine: 0-34 ms, median 3, and one full-suite run in eight (#1592)
  # went over the 100. Nothing here is racing; the redirect either happens or
  # it does not, so the only question is how long to wait for it.
  @advance_timeout 2_000

  setup %{conn: conn} do
    user = insert_user()
    %{conn: login_user(conn, user), user: user}
  end

  describe "the waiting page" do
    test "names the address the link was sent to", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/auth/verify-pending")

      assert html =~ "Check your email"
      assert html =~ user.email
    end

    test "offers a way out for someone who used the wrong address", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      assert lv |> element("a[href='/auth/logout']") |> has_element?()
    end

    # The trap this route is shaped around: TenantSessionAuth sends unverified
    # sessions here, so routing this page through that pipeline would make it
    # redirect to itself forever. It is deliberately outside :browser_authenticated.
    test "does not redirect to itself", %{conn: conn} do
      assert {:ok, _lv, _html} = live(conn, ~p"/auth/verify-pending")
    end

    # Logout has to stay reachable without verification or the escape hatch
    # above is decorative.
    test "signing out works without being verified", %{conn: conn} do
      conn = get(conn, ~p"/auth/logout")
      assert redirected_to(conn) == "/auth/login"

      # Asserted by replaying the dropped cookie rather than reading
      # get_session/2, which still shows the old value — configure_session
      # drop only takes effect when the response is written.
      next = conn |> recycle() |> get(~p"/auth/verify-pending")
      assert redirected_to(next) == "/auth/login"
    end
  end

  describe "the controller pipeline" do
    test "an unverified session is turned away from a session-authenticated route", %{conn: conn} do
      conn = patch(conn, ~p"/api/settings/theme", %{"theme" => "dark"})

      assert redirected_to(conn) == "/auth/verify-pending"
    end
  end

  describe "auto-advance" do
    test "verification elsewhere sends the page on without a second login", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      # Stands in for the emailed link being clicked in another tab or on a
      # phone: verify_email/1 is what every verification route ends up calling.
      {:ok, _verified} = Accounts.verify_email(user)

      assert_redirect(lv, "/dashboard", @advance_timeout)
    end

    test "the poll advances even when the broadcast never arrives", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      # Stamp the column directly, bypassing verify_email/1 — this is the
      # cross-node case where the PubSub message is emitted on another node
      # that this one is not clustered with.
      {:ok, _} =
        user
        |> Ecto.Changeset.change(email_verified_at: DateTime.utc_now(:second))
        |> Repo.update()

      send(lv.pid, :check_verification)

      assert_redirect(lv, "/dashboard", @advance_timeout)
    end

    test "a broadcast that does not match the database does not advance", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      # The message is a trigger to re-read, never the evidence itself.
      Phoenix.PubSub.broadcast(
        Fountain.PubSub,
        Accounts.verification_topic(user.id),
        {:email_verified, user.id}
      )

      assert render(lv) =~ "Check your email"
    end
  end

  describe "resend" do
    test "enqueues a fresh verification email and says so", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      html = lv |> element("button[phx-click='resend']") |> render_click()

      assert html =~ "on its way"
      assert_enqueued(worker: VerificationEmail, args: %{user_id: user.id})
    end

    test "refuses past the hourly budget instead of enqueueing forever", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/auth/verify-pending")

      # The bucket allows 5 an hour, keyed by user id. Oban's own 60s
      # uniqueness collapses the burst into a single job, so the count of jobs
      # says nothing here — the refusal on the sixth click is the assertion.
      for _ <- 1..5 do
        html = lv |> element("button[phx-click='resend']") |> render_click()
        assert html =~ "on its way"
      end

      html = lv |> element("button[phx-click='resend']") |> render_click()
      assert html =~ "lot of resends"
    end
  end
end
