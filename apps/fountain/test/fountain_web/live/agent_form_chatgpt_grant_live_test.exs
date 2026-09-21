defmodule FountainWeb.AgentFormChatGPTGrantLiveTest do
  # ADR 0060 decision 2: "a set with a grant and no key is eligible for Codex
  # and `:missing` for the rest, and says so at selection". The agent form's
  # missing-credential card is where selection says it. `async: false`: the
  # broker is application env.
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fountain.InferenceCredentials

  setup %{conn: conn} do
    previous = Application.get_env(:fountain, :broker_listen_port)
    Application.put_env(:fountain, :broker_listen_port, 14_322)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:fountain, :broker_listen_port),
        else: Application.put_env(:fountain, :broker_listen_port, previous)
    end)

    user = insert_verified_user()
    grant = Fountain.ChatGPTFixtures.user_grant!(user.id)
    {:ok, default} = InferenceCredentials.create_set(user.id, "Default")
    {:ok, subscription} = InferenceCredentials.create_set(user.id, "Subscription")
    {:ok, subscription} = InferenceCredentials.set_grant(subscription, grant.id)

    %{conn: login_user(conn, user), user: user, default: default, subscription: subscription}
  end

  test "a codex agent on a set that names a grant is not asked for an OpenAI key", ctx do
    agent =
      insert_agent(
        user_id: ctx.user.id,
        runtime: "codex",
        inference_credential_id: ctx.subscription.id
      )

    {:ok, view, _} = live(ctx.conn, "/agents/#{agent.id}/edit")
    refute has_element?(view, "form[phx-submit=save_credential]")

    # The same agent pointed at a set with neither is asked, in the same render.
    view
    |> form("#agent-form", %{"agent" => %{"inference_credential_id" => ctx.default.id}})
    |> render_change()

    assert has_element?(view, "form[phx-submit=save_credential]")

    view
    |> form("#agent-form", %{"agent" => %{"inference_credential_id" => ctx.subscription.id}})
    |> render_change()

    refute has_element?(view, "form[phx-submit=save_credential]")
  end

  test "an opencode agent on an OpenAI model is still asked: the grant is not a key", ctx do
    agent =
      insert_agent(
        user_id: ctx.user.id,
        runtime: "opencode",
        model: "openai/gpt-5",
        inference_credential_id: ctx.subscription.id
      )

    {:ok, view, _} = live(ctx.conn, "/agents/#{agent.id}/edit")
    assert has_element?(view, "form[phx-submit=save_credential]")
  end
end
