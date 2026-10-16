defmodule FountainWeb.DashboardLiveTest do
  @moduledoc """
  The console's home (#867): the account's own numbers, what is running now,
  and the way out to the Conversations app.
  """

  use FountainWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user = insert_verified_user()

    original = Application.fetch_env(:fountain, :conversations_app_url)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:fountain, :conversations_app_url, v)
        :error -> Application.delete_env(:fountain, :conversations_app_url)
      end
    end)

    Application.put_env(:fountain, :conversations_app_url, "https://apps.test/convs/")

    {:ok, conn: login_user(conn, user), user: user}
  end

  test "a new account gets no getting-started nag", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    refute html =~ "Nothing has answered on this account yet"
    refute html =~ ~s(href="/start")
  end

  test "the API introduction uses this server and links to keys and documentation", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard")

    assert has_element?(
             lv,
             ~s|#api-introduction a[href="#{Fountain.Apps.account_url("api-keys")}"]|
           )

    assert has_element?(lv, ~s|a[href="/docs/quickstart"]|)
    assert has_element?(lv, ~s|#copy-api-example[data-target="api-example"]|)

    example =
      lv |> element("#api-example") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

    assert example =~ FountainWeb.Endpoint.url() <> "/api/auth/me"
    assert example =~ "Authorization: Bearer $MANAGOAT_API_KEY"
    assert example =~ "paste-your-key-here'\ncurl"
  end

  test "recent activity belongs to the user even when they are an admin", %{conn: conn} do
    admin = insert_verified_user(role: "admin")
    other = insert_verified_user()

    for {user, action} <- [{admin, "agent.own-change"}, {other, "agent.other-tenant"}] do
      Fountain.Audit.record!(%{
        user_id: user.id,
        action: action,
        resource_type: "agent",
        actor: "self"
      })
    end

    {:ok, lv, _html} = live(login_user(conn, admin), ~p"/dashboard")
    assert has_element?(lv, "#recent-activity", "agent.own-change")
    refute has_element?(lv, "#recent-activity", "agent.other-tenant")
  end

  # ADR 0076: agents, environments and vaults are configured in the app, the
  # CLI and the API, so the dashboard neither counts them nor links them in.
  test "the app is linked out to, and the retired primitive pages are not", %{
    conn: conn,
    user: user
  } do
    insert_agent(user_id: user.id)
    insert_env(user_id: user.id)
    insert_vault(user_id: user.id)

    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "https://apps.test/convs/"
    assert html =~ "Running now"

    for path <- ["/agents", "/environments", "/vaults"] do
      refute html =~ ~s|href="#{path}"|
    end
  end

  test "with no app configured, it points at the CLI and the API", %{conn: conn} do
    Application.put_env(:fountain, :conversations_app_url, "")

    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "Running now"
    assert html =~ ~s|href="/docs/cli"|
    assert html =~ ~s|href="/docs/api"|
  end

  test "a recent conversation links into the app, not to a page that is gone", %{
    conn: conn,
    user: user
  } do
    agent = insert_agent(user_id: user.id, name: "picard")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "picard"
    assert html =~ "https://apps.test/convs/#/c/#{conv.id}"
    refute html =~ ~s|href="/conversations/#{conv.id}"|
  end

  describe "this month" do
    test "counts conversations, turns and tokens from the tables", %{conn: conn, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      month_start = DateTime.new!(Date.beginning_of_month(DateTime.to_date(now)), ~T[00:00:00])
      last_month = DateTime.add(month_start, -86_400, :second)

      # Two turns this month on one conversation, one last month on another.
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)
      insert_turn(conv)
      old = insert_conversation(user_id: user.id) |> insert_turn()

      Fountain.Repo.update_all(
        from(t in Fountain.Conversations.Turn, where: t.id == ^old.id),
        set: [inserted_at: last_month]
      )

      {:ok, _} =
        Fountain.Conversations._unsafe_record_turn_usage(turn, %{"input" => 1500, "output" => 250})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "This month"
      assert html =~ ~r/Conversations<\/p>\s*<p[^>]*>\s*1\s*<\/p>/
      assert html =~ ~r/Turns<\/p>\s*<p[^>]*>\s*2\s*<\/p>/
      assert html =~ "Tokens"
      # 1,500 in / 250 out, compacted.
      assert html =~ "1.5k / 250"
      # Sandbox time and turn hours are gone with the metering (ADR 0079).
      refute html =~ "Turn hours"
      refute html =~ "sandboxes were awake"
    end

    # The tile shipped reading `input` alone, which for a coding agent is a
    # rounding error next to its cached reads.
    test "the tokens tile counts the prompt cache, not just fresh input", %{
      conn: conn,
      user: user
    } do
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      {:ok, _} =
        Fountain.Conversations._unsafe_record_turn_usage(turn, %{
          "input" => 1_471,
          "cache_read" => 41_317_595,
          "cache_write" => 3_120_406,
          "output" => 545_912
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # 1,471 + 41,317,595 + 3,120,406 = 44,439,472 in; 545,912 out.
      assert html =~ "44.4M / 545.9k"
      refute html =~ "1.5k / 545.9k"
      # …and the breakdown is on hover rather than lost.
      assert html =~ "read from or written to the prompt cache"
    end

    test "an account that has done nothing this month says so", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Nothing yet this month."
      # Tokens with nothing behind them read as a dash. (Asserting the dash
      # itself would pass on the hint text's em-dash, so pin the absence.)
      refute html =~ "0 / 0"
    end

    # "Nothing yet" over a populated tile reads as a bug.
    test "it does not say nothing while a tile says something", %{conn: conn, user: user} do
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      {:ok, _} =
        Fountain.Conversations._unsafe_record_turn_usage(turn, %{"input" => 10, "output" => 2})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "Nothing yet this month."
    end
  end

  test "a deployment with no conversations app links to none of it", %{conn: conn, user: user} do
    Application.put_env(:fountain, :conversations_app_url, "")
    insert_agent(user_id: user.id)
    insert_conversation(user_id: user.id)

    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    refute html =~ "apps.test/convs"
    # And it does not ask for a conversation it has nowhere to start.
    refute html =~ "Start one"
  end

  describe "conversation labels (#1637)" do
    test "renders them as chips beside each conversation", %{conn: conn, user: user} do
      insert_conversation(user_id: user.id, labels: %{"env" => "prod", "drift" => "true"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "env=prod"
      assert html =~ "drift=true"
    end

    test "a conversation with no labels renders no chips", %{conn: conn, user: user} do
      insert_conversation(user_id: user.id)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      refute has_element?(lv, "[data-label-chip]")
    end

    test "the URL filter narrows the list, repeatable and AND-combined", %{
      conn: conn,
      user: user
    } do
      drifted =
        insert_conversation(user_id: user.id, labels: %{"env" => "prod", "drift" => "true"})

      clean = insert_conversation(user_id: user.id, labels: %{"env" => "prod"})
      staging = insert_conversation(user_id: user.id, labels: %{"env" => "staging"})

      {:ok, _lv, one} = live(conn, "/dashboard?label=env:prod")
      assert one =~ drifted.id
      assert one =~ clean.id
      refute one =~ staging.id

      {:ok, _lv, both} = live(conn, "/dashboard?label=env:prod&label=drift:true")
      assert both =~ drifted.id
      refute both =~ clean.id
    end

    test "a filter nothing matches says so rather than showing everything", %{
      conn: conn,
      user: user
    } do
      insert_conversation(user_id: user.id, labels: %{"env" => "prod"})

      {:ok, _lv, html} = live(conn, "/dashboard?label=env:qa")

      assert html =~ "No conversation carries every one of those labels"
    end

    test "a chip links to the same list filtered by it", %{conn: conn, user: user} do
      insert_conversation(user_id: user.id, labels: %{"env" => "prod"})

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      assert lv
             |> element("[data-label-chip='env']")
             |> render_click() =~ "clear"

      assert_patched(lv, "/dashboard?label=env%3Aprod")
    end

    test "an unparseable filter value filters nothing rather than erroring", %{
      conn: conn,
      user: user
    } do
      conv = insert_conversation(user_id: user.id, labels: %{"env" => "prod"})

      {:ok, _lv, html} = live(conn, "/dashboard?label=prod")

      assert html =~ conv.id
    end
  end
end
