defmodule FountainWeb.StartLivePlatformBannerTest do
  @moduledoc """
  The `/start` credential banner with a platform key configured.

  `async: false`: the platform key lives in the global application
  environment, and an async module that writes it races every other module
  that reads it (`platform_inference_test.exs` is `async: false` for the
  same reason).

  The case: an agent pointed at an explicit set that holds nothing, an
  `ANTHROPIC_API_KEY` in the agent's environment, and a platform key. A
  launch admits this agent on the environment's key (`:tenant_secret`), so
  the banner must stay hidden. Asked with the set alone, the resolver
  refuses the empty explicit set rather than substituting the platform key
  and the page warns about a launch that works.
  """
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fountain.{Agents, Crypto, Environments, InferenceCredentials}

  setup %{conn: conn} do
    previous = Application.get_env(:fountain, :platform_anthropic_api_key)
    Application.put_env(:fountain, :platform_anthropic_api_key, "sk-platform")

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:fountain, :platform_anthropic_api_key),
        else: Application.put_env(:fountain, :platform_anthropic_api_key, previous)
    end)

    user = insert_verified_user()
    {:ok, conn: login_user(conn, user), user: user}
  end

  test "an empty explicit set with the key in the environment shows no banner",
       %{conn: conn, user: user} do
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    {:ok, set} = InferenceCredentials.create_set(user.id, "Empty")
    env = insert_env(user_id: user.id)

    {:ok, _} =
      Environments.upsert_secret(
        env,
        %{"key" => "ANTHROPIC_API_KEY", "value" => "sk-ant-env-key-000000000000"},
        dek
      )

    starter = Agents.get_agent_by_name("starter", user.id)

    {:ok, _} =
      Agents.update_agent(starter, %{
        "inference_credential_id" => set.id,
        "environment_id" => env.id
      })

    {:ok, _lv, html} = live(conn, ~p"/start")

    refute html =~ "no inference credential yet"
  end

  test "an empty explicit set with nothing in the environment still warns",
       %{conn: conn, user: user} do
    {:ok, set} = InferenceCredentials.create_set(user.id, "Empty")
    starter = Agents.get_agent_by_name("starter", user.id)
    {:ok, _} = Agents.update_agent(starter, %{"inference_credential_id" => set.id})

    {:ok, _lv, html} = live(conn, ~p"/start")

    assert html =~ "no inference credential yet"
  end
end
