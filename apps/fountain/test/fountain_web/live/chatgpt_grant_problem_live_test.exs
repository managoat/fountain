defmodule FountainWeb.ChatGPTGrantProblemLiveTest do
  @moduledoc """
  The `/start` banner and the agent form, for a codex agent on a credential
  set whose named ChatGPT subscription cannot serve (ADR 0060 decision 4,
  stage 4b). Stage 2 left both quiet: the banner answered "will reach a
  model" for a launch that would be refused, and the form asked for an
  OpenAI key resolution would never use.

  `async: false`: the broker is application env.
  """

  use FountainWeb.ConnCase, async: false

  import Fountain.BrokerTestHelpers
  import Fountain.ChatGPTFixtures
  import Phoenix.LiveViewTest

  alias Fountain.{Agents, ChatGPTAccounts, InferenceCredentials}

  @codex_model "openai/gpt-5.3-codex"

  setup %{conn: conn} do
    enable_broker()
    user = insert_verified_user()

    {:ok, grant} = ChatGPTAccounts.connect_for_user(user.id, "Work", user_tokens("acct-work"))
    {:ok, set} = InferenceCredentials.create_set(user.id, "Default")
    {:ok, set} = InferenceCredentials.set_grant(set, grant.grant_id)

    {:ok, agent} =
      "starter"
      |> Agents.get_agent_by_name(user.id)
      |> Agents.update_agent(%{"runtime" => "codex", "model" => @codex_model})

    %{conn: login_user(conn, user), user: user, grant: grant, set: set, agent: agent}
  end

  describe "/start" do
    test "says nothing while the named subscription can serve", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/start")

      refute has_element?(view, "#start-grant-problem")
      refute html =~ "no inference credential yet"
    end

    test "names a disconnected subscription, and does not ask for a key", %{
      conn: conn,
      user: user,
      grant: grant
    } do
      :ok = ChatGPTAccounts.disconnect_for_user(grant.grant_id, user.id)
      {:ok, view, html} = live(conn, ~p"/start")

      banner = view |> element("#start-grant-problem") |> render()
      assert banner =~ "cannot serve a run right now"
      assert banner =~ "&quot;Work&quot; is disconnected"
      assert banner =~ "Fountain does not switch to another subscription"
      assert banner =~ ~s(href="/account/inference-credentials")
      refute html =~ "no inference credential yet"
    end

    test "says so for an account that may not use a subscription, which the turn would refuse",
         %{conn: conn, user: user} do
      user
      |> Ecto.Changeset.change(suspended_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Fountain.Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/start")
      banner = view |> element("#start-grant-problem") |> render()

      assert banner =~ "cannot be used by this account right now"
      assert banner =~ "Until that changes, the request below is refused."
    end

    test "says so on a deployment with no broker", %{conn: conn} do
      disable_broker()
      {:ok, view, _html} = live(conn, ~p"/start")

      assert view |> element("#start-grant-problem") |> render() =~
               "does not run the egress broker a subscription needs"
    end
  end

  describe "the agent form" do
    test "is quiet while the named subscription can serve", %{conn: conn, agent: agent} do
      {:ok, view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      refute has_element?(view, "#agent-grant-problem")
      refute html =~ "No OpenAI credential on this account yet"
    end

    test "names a disconnected subscription instead of asking for a key it would refuse", %{
      conn: conn,
      user: user,
      grant: grant,
      agent: agent
    } do
      :ok = ChatGPTAccounts.disconnect_for_user(grant.grant_id, user.id)
      {:ok, view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      notice = view |> element("#agent-grant-problem") |> render()
      assert notice =~ "This agent&#39;s conversations will not start."
      assert notice =~ "&quot;Work&quot; is disconnected"
      refute html =~ "No OpenAI credential on this account yet"

      # The notice follows the form: another runtime does not run on the
      # subscription, so it has a different problem, a missing key.
      html =
        view
        |> element("#agent-form")
        |> render_change(%{"agent" => %{"runtime" => "opencode", "model" => "openai/gpt-5"}})

      refute has_element?(view, "#agent-grant-problem")
      assert html =~ "No OpenAI credential on this account yet"

      view
      |> element("#agent-form")
      |> render_change(%{"agent" => %{"runtime" => "codex", "model" => @codex_model}})

      assert has_element?(view, "#agent-grant-problem")
    end

    test "the answer is resolved again when what it depends on changes, not on every keystroke",
         %{conn: conn, user: user, grant: grant, agent: agent} do
      :ok = ChatGPTAccounts.disconnect_for_user(grant.grant_id, user.id)
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      assert has_element?(view, "#agent-grant-problem")

      # The subscription comes back while the form is open. Typing a name is
      # not a reason to resolve again, under the lock a turn is admitted under.
      {:ok, _} =
        ChatGPTAccounts.reconnect_for_user(grant.grant_id, user.id, user_tokens("acct-work"))

      view |> element("#agent-form") |> render_change(%{"agent" => %{"name" => "Typing"}})
      assert has_element?(view, "#agent-grant-problem")

      # The runtime is: away and back asks again, and the answer is the new one.
      view
      |> element("#agent-form")
      |> render_change(%{"agent" => %{"runtime" => "opencode", "model" => "openai/gpt-5"}})

      view
      |> element("#agent-form")
      |> render_change(%{"agent" => %{"runtime" => "codex", "model" => @codex_model}})

      refute has_element?(view, "#agent-grant-problem")
    end

    test "on a deployment with no broker it says that, and asks for no key", %{
      conn: conn,
      agent: agent
    } do
      disable_broker()
      {:ok, view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      assert view |> element("#agent-grant-problem") |> render() =~
               "does not run the egress broker a subscription needs"

      refute html =~ "No OpenAI credential on this account yet"
    end
  end
end
