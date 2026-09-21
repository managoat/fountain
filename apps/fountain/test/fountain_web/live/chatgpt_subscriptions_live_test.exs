defmodule FountainWeb.ChatGPTSubscriptionsLiveTest do
  @moduledoc """
  The **ChatGPT subscriptions** card on `/account/inference-credentials` (ADR
  0060 decision 3, stage 4b).

  What the ADR's stage 4 asks of the console: a page reload picks a pending
  sign-in up from its row, nothing secret is rendered, and ownership,
  cancellation and expiry are visible here as they are over the API. The
  auth server is `Fountain.ChatGPTFixtures`' stub and the job is run by hand.

  `async: false`: the broker and the rollout flag are application env, and
  the auth server's stub is in shared mode because the page and the job call
  it from processes of their own.
  """

  use FountainWeb.ConnCase, async: false
  use Oban.Testing, repo: Fountain.Repo

  import Ecto.Query, only: [from: 2]
  import Fountain.BrokerTestHelpers
  import Fountain.ChatGPTFixtures
  import Phoenix.LiveViewTest

  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.LinkAttempt
  alias Fountain.InferenceCredentials
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.Repo
  alias Fountain.Workers.ChatGPTLinkAttempt, as: Worker

  @path "/account/inference-credentials"
  @card "#chatgpt-subscriptions"

  @user_code "WXYZ-9876"
  @device_auth_id "deviceauth_SECRET_console"
  @authorization_code "authcode_SECRET_console"
  @verifier "verifier_SECRET_console"
  @refresh_token "rt_SECRET_console"

  setup %{conn: conn} do
    enable_chatgpt_subscriptions()
    user = insert_verified_user()
    %{conn: login_user(conn, user), user: user, other: insert_verified_user()}
  end

  # The auth server: a device code for every start, and an approval.
  defp stub_sign_in(account_id \\ "acct-console", access \\ access_token()) do
    stub_auth(%{
      "/api/accounts/deviceauth/usercode" => fn _ ->
        {200, %{"user_code" => @user_code, "device_auth_id" => @device_auth_id, "interval" => 5}}
      end,
      "/api/accounts/deviceauth/token" => fn _ ->
        {200, %{"authorization_code" => @authorization_code, "code_verifier" => @verifier}}
      end,
      "/oauth/token" => fn _ ->
        {200,
         %{
           "access_token" => access,
           "refresh_token" => @refresh_token,
           "id_token" => id_token(%{account_id: account_id, email: "owner@example.com"})
         }}
      end
    })

    access
  end

  defp link!(user, name, account_id) do
    {:ok, grant} = ChatGPTAccounts.connect_for_user(user.id, name, user_tokens(account_id))
    grant
  end

  defp start_attempt!(user, target, overrides \\ %{}) do
    {:ok, attempt} =
      ChatGPTAccounts.start_attempt_for_user(user.id, target,
        device_start: device_start(self(), overrides)
      )

    attempt
  end

  defp submit_connect(view, name),
    do: view |> element("#chatgpt-connect") |> render_submit(%{"name" => name})

  defp pending(user), do: ChatGPTAccounts.list_pending_attempts_for_user(user.id)

  # What the job does when the auth server says the code was approved.
  defp approve!(attempt_id, user),
    do: :ok = perform_job(Worker, %{"attempt_id" => attempt_id, "user_id" => user.id})

  defp hostile(view, event, params),
    do: view |> with_target(@card) |> render_click(event, params)

  describe "connecting" do
    test "an account with nothing linked sees the empty card", %{conn: conn} do
      {:ok, view, html} = live(conn, @path)

      assert html =~ "ChatGPT subscriptions"
      assert html =~ "No subscription is linked yet."
      assert view |> element(@card <> "-count") |> render() =~ "0 of 5"
      assert has_element?(view, "#chatgpt-connect")
    end

    test "a name starts a sign-in, and the page shows the code, the page and the expiry",
         %{conn: conn, user: user} do
      stub_sign_in()
      {:ok, view, _html} = live(conn, @path)

      submit_connect(view, "  Work ChatGPT  ")
      html = render(view)

      assert [%{id: attempt_id, name: "Work ChatGPT", expires_at: expires_at}] = pending(user)
      assert has_element?(view, "#chatgpt-attempt-#{attempt_id}")
      assert view |> element("#chatgpt-code-#{attempt_id}") |> render() =~ @user_code

      assert has_element?(
               view,
               ~s(a[href="https://auth.openai.com/codex/device"][rel~="noopener"])
             )

      assert html =~ "Connecting Work ChatGPT"
      assert html =~ "expires at #{Calendar.strftime(expires_at, "%H:%M UTC")}"
      assert html =~ "Approve a code only if you started it yourself"
      refute html =~ @device_auth_id
    end

    test "a refused start says why, in words", %{conn: conn, user: user} do
      link!(user, "Work", "acct-work")
      {:ok, view, _html} = live(conn, @path)

      assert submit_connect(view, "Work") =~
               "Name already names a ChatGPT subscription on this account."

      assert submit_connect(view, "   ") =~ "Name can&#39;t be blank."

      stub_auth(%{"/api/accounts/deviceauth/usercode" => fn _ -> {503, %{}} end})
      assert submit_connect(view, "Personal") =~ "sign-in service did not answer"
      assert pending(user) == []
    end

    test "the count and the ceiling are shown, and a full account is not offered another",
         %{conn: conn, user: user} do
      previous = Application.get_env(:fountain, :chatgpt_grant_ceiling)
      Application.put_env(:fountain, :chatgpt_grant_ceiling, 2)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:fountain, :chatgpt_grant_ceiling, previous),
          else: Application.delete_env(:fountain, :chatgpt_grant_ceiling)
      end)

      link!(user, "Work", "acct-work")
      {:ok, view, _html} = live(conn, @path)
      assert view |> element(@card <> "-count") |> render() =~ "1 of 2"
      assert has_element?(view, "#chatgpt-connect")

      link!(user, "Personal", "acct-personal")
      html = render(view)

      assert view |> element(@card <> "-count") |> render() =~ "2 of 2"
      refute has_element?(view, "#chatgpt-connect")
      assert html =~ "A disconnected one still counts"

      # The form is not the guard: the context refuses, and the page says so.
      assert hostile(view, "connect", %{"name" => "Third"}) =~ "holds 2 of the 2 subscriptions"
    end

    test "a page that is not OpenAI's is never a link", %{conn: conn, user: user} do
      for url <- [
            "https://auth.openai.com.evil.example/codex/device",
            "http://auth.openai.com/codex/device",
            "https://user@auth.openai.com/codex/device",
            "javascript:alert(1)"
          ] do
        attempt = start_attempt!(user, %{name: "Work"}, %{verification_url: url})
        {:ok, view, html} = live(conn, @path)

        assert view |> element("#chatgpt-code-#{attempt.id}") |> render() =~ attempt.user_code
        refute has_element?(view, "#chatgpt-attempt-#{attempt.id} a")
        refute html =~ "evil.example"
        assert html =~ "Type"
        assert html =~ "https://auth.openai.com/codex/device"

        {:ok, _} = ChatGPTAccounts.cancel_attempt_for_user(attempt.id, user.id)
      end
    end
  end

  describe "page reload" do
    test "a fresh mount shows the same code, and a completion flips both pages to connected",
         %{conn: conn, user: user} do
      stub_sign_in("acct-reload")
      {:ok, first, _html} = live(conn, @path)
      submit_connect(first, "Work")
      [%{id: attempt_id}] = pending(user)

      # Nothing of the sign-in lives in the first page's process: a second
      # mount reads the row.
      {:ok, second, html} = live(conn, @path)
      assert html =~ @user_code
      assert second |> element("#chatgpt-code-#{attempt_id}") |> render() =~ @user_code

      approve!(attempt_id, user)

      for view <- [first, second] do
        html = render(view)
        refute html =~ @user_code
        refute has_element?(view, "#chatgpt-attempt-#{attempt_id}")
        assert html =~ "Work is connected."
        assert html =~ "Connected"
        assert html =~ "owner@example.com"
        assert html =~ "(pro)"
      end

      assert [%{name: "Work", status: "active"}] = ChatGPTAccounts.list_for_user(user.id)

      # And a third mount, after the fact, shows the subscription and no code.
      {:ok, _third, html} = live(conn, @path)
      assert html =~ "owner@example.com"
      refute html =~ @user_code
    end

    test "a sign-in started over the API appears on an open page", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, @path)
      refute html =~ "Connecting"

      attempt = start_attempt!(user, %{name: "From the API"})

      assert render(view) =~ "Connecting From the API"
      assert view |> element("#chatgpt-code-#{attempt.id}") |> render() =~ attempt.user_code
    end
  end

  describe "cancellation and expiry" do
    test "Cancel ends the sign-in, and a late approval links nothing", %{conn: conn, user: user} do
      stub_sign_in()
      {:ok, view, _html} = live(conn, @path)
      submit_connect(view, "Work")
      [%{id: attempt_id}] = pending(user)

      view |> element("#chatgpt-attempt-#{attempt_id} button", "Cancel") |> render_click()
      html = render(view)

      assert html =~ "Sign-in cancelled."
      refute html =~ @user_code
      assert %LinkAttempt{state: "cancelled"} = Repo.get!(LinkAttempt, attempt_id)

      approve!(attempt_id, user)
      assert ChatGPTAccounts.list_for_user(user.id) == []
      refute render(view) =~ "is connected"
    end

    test "a code that runs out is taken off the page, which says so", %{conn: conn, user: user} do
      stub_sign_in()
      {:ok, view, _html} = live(conn, @path)
      submit_connect(view, "Work")
      [%{id: attempt_id}] = pending(user)
      assert render(view) =~ @user_code

      past = DateTime.add(DateTime.utc_now(), -60, :second)
      Repo.update_all(from(a in LinkAttempt, where: a.id == ^attempt_id), set: [expires_at: past])

      # The job's next run meets the overdue row, writes it and says so.
      approve!(attempt_id, user)
      html = render(view)

      refute html =~ @user_code
      assert html =~ "The sign-in code for Work expired before it was approved"
      assert ChatGPTAccounts.list_for_user(user.id) == []

      # A reload shows no code for it either.
      {:ok, _view, html} = live(conn, @path)
      refute html =~ @user_code
    end

    test "a sign-in the auth server refuses says so", %{conn: conn, user: user} do
      stub_sign_in()
      {:ok, view, _html} = live(conn, @path)
      submit_connect(view, "Work")
      [%{id: attempt_id}] = pending(user)

      stub_auth(%{
        "/api/accounts/deviceauth/token" => fn _ -> {400, %{"error" => "access_denied"}} end
      })

      approve!(attempt_id, user)
      html = render(view)

      assert html =~ "ChatGPT refused the sign-in for Work"
      refute html =~ "access_denied"
      refute html =~ @user_code
    end
  end

  describe "one subscription" do
    setup %{user: user} do
      %{grant: link!(user, "Work", "acct-work")}
    end

    test "Rename", %{conn: conn, user: user, grant: grant} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("#chatgpt-grant-#{grant.grant_id} form")
      |> render_submit(%{"name" => "Work, renamed"})

      assert render(view) =~ "Renamed to Work, renamed."

      assert {:ok, %{name: "Work, renamed", generation: generation}} =
               ChatGPTAccounts.get_for_user(grant.grant_id, user.id)

      # A label, not a credential.
      assert generation == grant.generation
    end

    test "Disconnect, then Remove", %{conn: conn, user: user, grant: grant} do
      {:ok, view, _html} = live(conn, @path)
      row = "#chatgpt-grant-#{grant.grant_id}"

      refute has_element?(view, row <> " button", "Remove")
      assert view |> element(row <> " button", "Disconnect") |> render() =~ "data-confirm"

      view |> element(row <> " button", "Disconnect") |> render_click()
      html = render(view)

      assert html =~ "Disconnected Work."
      assert view |> element(row) |> render() =~ "Disconnected"
      refute has_element?(view, row <> " button", "Disconnect")

      assert {:ok, %{status: "disconnected"}} =
               ChatGPTAccounts.get_for_user(grant.grant_id, user.id)

      view |> element(row <> " button", "Remove") |> render_click()

      assert render(view) =~ "Removed Work."
      refute has_element?(view, row)
      assert ChatGPTAccounts.list_for_user(user.id) == []
    end

    test "Remove is refused while credential sets name it, and the page names them",
         %{conn: conn, user: user, grant: grant} do
      {:ok, a} = InferenceCredentials.create_set(user.id, "Default")
      {:ok, b} = InferenceCredentials.create_set(user.id, "Second")
      {:ok, _} = InferenceCredentials.set_grant(a, grant.grant_id)
      {:ok, _} = InferenceCredentials.set_grant(b, grant.grant_id)
      :ok = ChatGPTAccounts.disconnect_for_user(grant.grant_id, user.id)

      {:ok, view, _html} = live(conn, @path)

      view
      |> element("#chatgpt-grant-#{grant.grant_id} button", "Remove")
      |> render_click()

      assert render(view) =~
               "Work is still named by the credential sets Default, Second. Point them at another"

      assert {:ok, _still_there} = ChatGPTAccounts.get_for_user(grant.grant_id, user.id)
    end

    test "a connected one cannot be removed by an event the page never sends",
         %{conn: conn, user: user, grant: grant} do
      {:ok, view, _html} = live(conn, @path)

      assert hostile(view, "remove", %{"id" => grant.grant_id}) =~
               "Work still holds a sign-in. Disconnect it before removing it."

      assert {:ok, %{status: "active"}} = ChatGPTAccounts.get_for_user(grant.grant_id, user.id)
    end

    test "a name a user chose is text, not markup", %{conn: conn, user: user} do
      link!(user, "<img src=x onerror=alert(1)>", "acct-markup")
      {:ok, _view, html} = live(conn, @path)

      refute html =~ "<img src=x"
      assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    end
  end

  describe "reconnecting one subscription" do
    setup %{user: user} do
      %{grant: link!(user, "Work", "acct-work")}
    end

    defp reconnect(view, grant),
      do:
        view |> element("#chatgpt-grant-#{grant.grant_id} button", "Reconnect") |> render_click()

    defp bearer(grant, user) do
      case ChatGPTAccounts.credential_for_user(grant.grant_id, user.id, grant.generation,
             refresh: false
           ) do
        {:ok, %{access_token: token}} -> token
        {:error, reason} -> reason
      end
    end

    test "the old credential serves until the new one commits, and then the new one does",
         %{conn: conn, user: user, grant: grant} do
      old = bearer(grant, user)
      assert is_binary(old)
      new = stub_sign_in("acct-work", access_token(3_600, %{"n" => "reconnected"}))

      {:ok, view, _html} = live(conn, @path)
      reconnect(view, grant)
      html = render(view)

      assert [%{id: attempt_id, kind: :reconnect, grant_id: grant_id}] = pending(user)
      assert grant_id == grant.grant_id
      assert html =~ "Reconnecting Work"
      assert html =~ "keeps serving on the sign-in it has"
      assert view |> element("#chatgpt-code-#{attempt_id}") |> render() =~ @user_code

      # One sign-in per subscription: the button is gone while one is open.
      refute has_element?(view, "#chatgpt-grant-#{grant.grant_id} button", "Reconnect")

      # Minutes pass here. The subscription is still connected, on the
      # credential it had, under the generation its conversations are pinned to.
      assert view |> element("#chatgpt-grant-#{grant.grant_id}") |> render() =~ "Connected"
      assert bearer(grant, user) == old

      approve!(attempt_id, user)
      html = render(view)

      assert html =~ "Work is reconnected."
      assert html =~ "start new ones"

      assert {:ok, %{grant_id: ^grant_id, name: "Work", status: "active"} = after_reconnect} =
               ChatGPTAccounts.get_for_user(grant_id, user.id)

      # The same row under a new generation: the old pin reads nothing, the
      # new one reads the new credential.
      assert after_reconnect.generation != grant.generation
      assert bearer(grant, user) == :stale_grant
      assert bearer(after_reconnect, user) == new
      assert [_only_one] = ChatGPTAccounts.list_for_user(user.id)
    end

    test "cancelling a reconnect leaves the subscription as it was",
         %{conn: conn, user: user, grant: grant} do
      stub_sign_in("acct-work")
      old = bearer(grant, user)

      {:ok, view, _html} = live(conn, @path)
      reconnect(view, grant)
      [%{id: attempt_id}] = pending(user)

      view |> element("#chatgpt-attempt-#{attempt_id} button", "Cancel") |> render_click()

      assert has_element?(view, "#chatgpt-grant-#{grant.grant_id} button", "Reconnect")
      assert bearer(grant, user) == old
    end

    test "a disconnected subscription comes back under its id, and its sets still name it",
         %{conn: conn, user: user, grant: grant} do
      {:ok, set} = InferenceCredentials.create_set(user.id, "Default")
      {:ok, _} = InferenceCredentials.set_grant(set, grant.grant_id)
      :ok = ChatGPTAccounts.disconnect_for_user(grant.grant_id, user.id)
      stub_sign_in("acct-work")

      {:ok, view, _html} = live(conn, @path)
      reconnect(view, grant)
      [%{id: attempt_id}] = pending(user)
      approve!(attempt_id, user)

      assert view |> element("#chatgpt-grant-#{grant.grant_id}") |> render() =~ "Connected"
      assert {:ok, %{status: "active"}} = ChatGPTAccounts.get_for_user(grant.grant_id, user.id)
      assert Repo.reload!(set).chatgpt_grant_id == grant.grant_id
    end

    test "a completion that arrives after a newer sign-in is discarded, and the page says so",
         %{conn: conn, user: user, grant: grant} do
      stub_sign_in("acct-work", access_token(3_600, %{"n" => "late"}))

      {:ok, view, _html} = live(conn, @path)
      reconnect(view, grant)
      [%{id: attempt_id}] = pending(user)

      # A newer sign-in lands first, from outside this page.
      newer = user_tokens("acct-work", access: access_token(3_600, %{"n" => "newer"}))
      {:ok, newest} = ChatGPTAccounts.reconnect_for_user(grant.grant_id, user.id, newer)

      approve!(attempt_id, user)
      html = render(view)

      assert html =~ "The sign-in for Work was approved too late"
      assert html =~ "Work was left exactly as it is"
      refute html =~ "stale_grant"
      refute html =~ @user_code

      # The credential that is there is the newer one, untouched.
      assert bearer(newest, user) == newer.access_token

      assert {:ok, %{generation: generation}} =
               ChatGPTAccounts.get_for_user(grant.grant_id, user.id)

      assert generation == newest.generation
    end

    test "an upstream account that is already linked names the subscription to reconnect",
         %{conn: conn, user: user} do
      personal = link!(user, "Personal", "acct-personal")
      # The browser was signed in to the Work account when the code was approved.
      stub_sign_in("acct-work")

      {:ok, view, _html} = live(conn, @path)
      reconnect(view, personal)
      [%{id: attempt_id}] = pending(user)
      approve!(attempt_id, user)
      html = render(view)

      assert html =~ "approved the code for Personal is already linked here as Work"
      assert html =~ "Reconnect Work instead"
      refute html =~ "account_already_linked"
      refute html =~ "acct-work"

      # The same for a new link.
      submit_connect(view, "Third")
      [%{id: attempt_id}] = pending(user)
      approve!(attempt_id, user)

      assert render(view) =~ "approved the code for Third is already linked here as Work"
      assert length(ChatGPTAccounts.list_for_user(user.id)) == 2
    end

    test "another account's subscription cannot be reconnected from here",
         %{conn: conn, other: other} do
      theirs = link!(other, "Theirs", "acct-theirs")
      {:ok, view, _html} = live(conn, @path)

      assert hostile(view, "reconnect", %{"id" => theirs.grant_id}) =~
               "That subscription is no longer on this account."

      assert pending(other) == []
    end

    test "with linking off it still reconnects; with no broker it cannot, and says why",
         %{conn: conn, user: user, grant: grant} do
      stub_sign_in("acct-work")
      chatgpt_subscriptions_flag(false)

      {:ok, view, _html} = live(conn, @path)
      reconnect(view, grant)
      assert [%{kind: :reconnect, id: attempt_id}] = pending(user)
      {:ok, _} = ChatGPTAccounts.cancel_attempt_for_user(attempt_id, user.id)

      disable_broker()
      {:ok, view, html} = live(conn, @path)

      assert html =~ "does not run the egress broker"
      refute has_element?(view, "#chatgpt-grant-#{grant.grant_id} button", "Reconnect")
      assert has_element?(view, "#chatgpt-grant-#{grant.grant_id} button", "Disconnect")

      assert hostile(view, "reconnect", %{"id" => grant.grant_id}) =~
               "cannot be reconnected here"

      assert pending(user) == []
    end
  end

  describe "a credential set picks a subscription" do
    setup %{user: user} do
      %{
        work: link!(user, "Work", "acct-work"),
        personal: link!(user, "Personal", "acct-personal")
      }
    end

    defp pick(view, grant_id),
      do: view |> element("#set-chatgpt-grant-form") |> render_submit(%{"grant_id" => grant_id})

    test "an account with one set names a subscription in it, behind a confirm that says what ends",
         %{conn: conn, user: user, work: work, personal: personal} do
      {:ok, set} = InferenceCredentials.create_set(user.id, "Default")
      {:ok, view, _html} = live(conn, @path)

      # One set, so no set panel, and the picker is there all the same.
      refute has_element?(view, "button[phx-click='select_set']")
      assert has_element?(view, "#set-chatgpt-grant option[selected][value='']", "None")
      assert has_element?(view, "#set-chatgpt-grant option[value='#{work.grant_id}']", "Work")

      assert view |> element("#set-chatgpt-grant-form button") |> render() =~
               "ends the codex conversations now running on that set"

      assert pick(view, work.grant_id) =~ "Default now runs codex on Work."
      assert Repo.reload!(set).chatgpt_grant_id == work.grant_id
      assert has_element?(view, "#set-chatgpt-grant option[selected][value='#{work.grant_id}']")

      assert pick(view, personal.grant_id) =~ "Default now runs codex on Personal."
      assert pick(view, "") =~ "Default names no ChatGPT subscription now."
      assert is_nil(Repo.reload!(set).chatgpt_grant_id)
    end

    test "an account with no set yet gets its default set by naming one",
         %{conn: conn, user: user, work: work} do
      assert InferenceCredentials.list_sets(user.id) == []
      {:ok, view, _html} = live(conn, @path)

      # Clearing what was never there makes nothing.
      pick(view, "")
      assert InferenceCredentials.list_sets(user.id) == []

      assert pick(view, work.grant_id) =~ "Default now runs codex on Work."

      assert [%{name: "Default", is_default: true, chatgpt_grant_id: named}] =
               InferenceCredentials.list_sets(user.id)

      assert named == work.grant_id
    end

    test "a refused first save leaves no set behind, and the next save still works",
         %{conn: conn, user: user, work: work, personal: personal} do
      {:ok, view, _html} = live(conn, @path)

      assert pick(view, "nope") =~
               "That subscription is not a ChatGPT subscription this account can name."

      assert InferenceCredentials.list_sets(user.id) == []
      assert pick(view, work.grant_id) =~ "Default now runs codex on Work."

      assert [%{name: "Default", chatgpt_grant_id: named}] =
               InferenceCredentials.list_sets(user.id)

      assert named == work.grant_id
      assert pick(view, personal.grant_id) =~ "Default now runs codex on Personal."
    end

    test "a first set made in another tab is the one a stale page names in",
         %{conn: conn, user: user, work: work} do
      {:ok, view, _html} = live(conn, @path)
      {:ok, set} = InferenceCredentials.create_set(user.id, "Default")

      assert pick(view, work.grant_id) =~ "Default now runs codex on Work."
      assert [%{id: id, chatgpt_grant_id: named}] = InferenceCredentials.list_sets(user.id)
      assert {id, named} == {set.id, work.grant_id}
    end

    test "the picker is about the selected set", %{conn: conn, user: user, work: work} do
      {:ok, default} = InferenceCredentials.create_set(user.id, "Default")
      {:ok, second} = InferenceCredentials.create_set(user.id, "Second")
      {:ok, view, _html} = live(conn, @path)

      view |> element("button[phx-value-id='#{second.id}']") |> render_click()
      assert pick(view, work.grant_id) =~ "Second now runs codex on Work."

      assert Repo.reload!(second).chatgpt_grant_id == work.grant_id
      assert is_nil(Repo.reload!(default).chatgpt_grant_id)
    end

    test "a disconnected subscription is offered only to the set that already names it",
         %{conn: conn, user: user, work: work, personal: personal} do
      {:ok, set} = InferenceCredentials.create_set(user.id, "Default")
      {:ok, _} = InferenceCredentials.set_grant(set, work.grant_id)
      {:ok, view, _html} = live(conn, @path)

      :ok = ChatGPTAccounts.disconnect_for_user(work.grant_id, user.id)
      :ok = ChatGPTAccounts.disconnect_for_user(personal.grant_id, user.id)
      render(view)

      assert has_element?(
               view,
               "#set-chatgpt-grant option[value='#{work.grant_id}']",
               "Work (disconnected)"
             )

      refute has_element?(view, "#set-chatgpt-grant option[value='#{personal.grant_id}']")

      assert render_submit(view, "set_grant", %{"grant_id" => personal.grant_id}) =~
               "That subscription is disconnected; reconnect it before a set names it."
    end

    test "another account's subscription, and an id that is not one, are the same refusal",
         %{conn: conn, user: user, other: other} do
      theirs = link!(other, "Theirs", "acct-theirs")
      {:ok, set} = InferenceCredentials.create_set(user.id, "Default")
      {:ok, view, _html} = live(conn, @path)
      refusal = "That subscription is not a ChatGPT subscription this account can name."

      assert render_submit(view, "set_grant", %{"grant_id" => theirs.grant_id}) =~ refusal
      assert render_submit(view, "set_grant", %{"grant_id" => "nope"}) =~ refusal

      # A select's value is one string. Anything else is not this page's form.
      for params <- [%{"grant_id" => %{"a" => "b"}}, %{"grant_id" => ["x"]}, %{}] do
        assert render_submit(view, "set_grant", params) =~ "That request was not understood."
      end

      assert is_nil(Repo.reload!(set).chatgpt_grant_id)
      assert Process.alive?(view.pid)
    end
  end

  describe "ownership" do
    test "another account's ids read as not there, change nothing, and the page lives on",
         %{conn: conn, user: user, other: other} do
      theirs = link!(other, "Theirs", "acct-theirs")
      their_attempt = start_attempt!(other, %{name: "Their sign-in"})
      before = Repo.get!(Account, theirs.grant_id)

      {:ok, view, html} = live(conn, @path)
      refute html =~ "Theirs"
      refute html =~ their_attempt.user_code

      id = theirs.grant_id
      gone = "That subscription is no longer on this account."

      assert hostile(view, "rename", %{"grant_id" => id, "name" => "Mine now"}) =~ gone
      assert hostile(view, "disconnect", %{"id" => id}) =~ gone
      assert hostile(view, "remove", %{"id" => id}) =~ gone

      assert hostile(view, "cancel_attempt", %{"id" => their_attempt.id}) =~
               "That sign-in is no longer open."

      assert Repo.get!(Account, id) == before
      assert %LinkAttempt{state: "pending"} = Repo.get!(LinkAttempt, their_attempt.id)
      assert ChatGPTAccounts.list_for_user(user.id) == []

      # Ids that are not ids, and events with nothing in them.
      for {event, params} <- [
            {"disconnect", %{"id" => "nope"}},
            {"disconnect", %{"id" => %{"a" => "b"}}},
            {"remove", %{}},
            {"rename", %{"grant_id" => id}},
            {"cancel_attempt", %{"id" => ["x"]}},
            {"connect", %{}},
            {"no_such_event", %{"id" => id}}
          ] do
        assert hostile(view, event, params) =~ ~r/no longer on this account|not understood/
      end

      assert Process.alive?(view.pid)
      assert Repo.get!(Account, id) == before
    end
  end

  describe "redaction" do
    test "no token, device id, claim, provider account id or fencing column is rendered",
         %{conn: conn, user: user} do
      access = stub_sign_in("acct-SECRET-upstream")
      existing = link!(user, "Existing", "acct-SECRET-existing")

      {:ok, view, first} = live(conn, @path)
      submit_connect(view, "Work")
      [%{id: attempt_id}] = pending(user)
      waiting = render(view)

      approve!(attempt_id, user)
      connected = render(view)
      assert connected =~ "Work is connected."

      [work] = Enum.filter(ChatGPTAccounts.list_for_user(user.id), &(&1.name == "Work"))

      secrets = [
        access,
        @refresh_token,
        @device_auth_id,
        @authorization_code,
        @verifier,
        "rt_acct-SECRET-existing",
        "acct-SECRET-upstream",
        "acct-SECRET-existing",
        existing.generation,
        work.generation,
        "chatgpt_user_id",
        "id_claims"
      ]

      # What the page is handed is what it may render: the projection holds
      # none of it either, so no later template can print what is not there.
      loaded = inspect(FountainWeb.InferenceCredentialsLive.SubscriptionsCard.load(user.id))

      for html <- [first, waiting, connected, loaded], secret <- secrets do
        refute html =~ secret
      end

      # The code is on the page only while the sign-in is open.
      assert waiting =~ @user_code
      refute connected =~ @user_code
    end
  end

  describe "with linking off" do
    test "an account that holds nothing sees no card", %{conn: conn} do
      chatgpt_subscriptions_flag(false)
      {:ok, view, html} = live(conn, @path)

      refute html =~ "ChatGPT subscriptions"
      refute has_element?(view, @card)
    end

    test "an account that holds a subscription keeps the card, without Connect",
         %{conn: conn, user: user} do
      grant = link!(user, "Work", "acct-work")
      chatgpt_subscriptions_flag(false)

      {:ok, view, html} = live(conn, @path)
      row = "#chatgpt-grant-#{grant.grant_id}"

      assert html =~ "ChatGPT subscriptions"
      assert html =~ "Linking another subscription is not available on this account."
      refute has_element?(view, "#chatgpt-connect")

      # The door is closed in the context, not only hidden.
      assert hostile(view, "connect", %{"name" => "Another"}) =~
               "Linking a ChatGPT subscription is not available on this account."

      assert pending(user) == []

      view |> element(row <> " form") |> render_submit(%{"name" => "Still mine"})
      assert {:ok, %{name: "Still mine"}} = ChatGPTAccounts.get_for_user(grant.grant_id, user.id)

      view |> element(row <> " button", "Disconnect") |> render_click()

      assert {:ok, %{status: "disconnected"}} =
               ChatGPTAccounts.get_for_user(grant.grant_id, user.id)

      view |> element(row <> " button", "Remove") |> render_click()
      assert ChatGPTAccounts.list_for_user(user.id) == []
    end

    test "a sign-in that was already open can still be cancelled", %{conn: conn, user: user} do
      attempt = start_attempt!(user, %{name: "Work"})
      chatgpt_subscriptions_flag(false)

      {:ok, view, html} = live(conn, @path)
      assert html =~ attempt.user_code

      view |> element("#chatgpt-attempt-#{attempt.id} button", "Cancel") |> render_click()
      assert %LinkAttempt{state: "cancelled"} = Repo.get!(LinkAttempt, attempt.id)
    end
  end
end
