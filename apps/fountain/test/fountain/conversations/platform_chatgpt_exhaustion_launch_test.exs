defmodule Fountain.Conversations.PlatformChatGPTExhaustionLaunchTest do
  @moduledoc """
  What the two selection switches of #2362 do to a Codex machine that is
  already bound (ADR 0053, review of #2363).

  A new conversation is not always a new sandbox. A persistent launch lands
  on the agent's home (`Launch.home_or_new/5`), and
  `InferenceBinding.compatible_machine/2` keeps that machine bound to the
  Codex source it started on. The binding is kept on purpose, so a switch
  shows up as today's errors, pinned here through the real launch and source
  validation:

    1. grant -> key, once OpenAI confirms the limit: a persistent launch on a
       grant-bound home is `:codex_inference_conflict`, and a grant-bound
       conversation no longer validates (`:inference_source_changed`);
    2. key -> grant, once the reset passes: the same two errors for a home
       and a conversation bound to the key.

  And the supported way to new work in both cases: a launch that does not
  land on the bound home (`sandbox_mode: "ephemeral"`) runs on whatever
  selection says now.

  `/wham/usage` is stubbed through the `Req.Test` seam; nothing reaches
  OpenAI. `async: false` for the one platform row and the shared stub.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import Fountain.ChatGPTFixtures

  alias Fountain.ChatGPTAccounts
  alias Fountain.Conversations.{InferenceResolution, Launch}
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformChatGPT.Account

  setup do
    # These tests are about admission and binding; no server runs.
    stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
      {:ok, spawn(fn -> :ok end)}
    end)

    restore =
      for key <- [:broker_listen_port, :broker_proxy_url, :platform_openai_api_key],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- restore do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")
    stub_auth(%{})

    user = insert_active_user()
    agent = insert_agent(user_id: user.id, runtime: "codex")
    connect!()
    %{user: user, agent: agent}
  end

  defp resolve(user, agent),
    do: InferenceCredentials.resolve(user.id, agent.model, agent.runtime, [])

  # The agent's persistent home, bound to what selection says right now: a
  # machine first provisioned on that source.
  defp home_bound_now(user, agent) do
    {:ok, source, _} = resolve(user, agent)

    insert_sandbox(user_id: user.id, agent_id: agent.id, mode: "persistent", status: "ready")
    |> Ecto.Changeset.change(codex_inference_source: Source.dump(source))
    |> Repo.update!()
  end

  defp launch(user, agent, mode) do
    Launch.start_conversation(%{
      "user_id" => user.id,
      "agent_id" => agent.id,
      "sandbox_mode" => mode
    })
  end

  defp confirm_limit!(user, agent) do
    {:ok, %Source{kind: :codex_chatgpt_access_token} = source, _} = resolve(user, agent)
    reset = DateTime.utc_now() |> DateTime.add(3_600) |> DateTime.truncate(:second)

    stub_auth(%{
      "/backend-api/wham/usage" => fn _ ->
        {200,
         %{
           "rate_limit" => %{
             "allowed" => false,
             "limit_reached" => true,
             "primary_window" => %{"used_percent" => 100, "reset_at" => DateTime.to_unix(reset)}
           },
           "credits" => %{"has_credits" => false, "unlimited" => false}
         }}
      end
    })

    assert :recorded = ChatGPTAccounts.platform_confirm_exhausted(source)
  end

  test "switch 1: a grant-bound home refuses new launches once the limit is confirmed", %{
    user: user,
    agent: agent
  } do
    home = home_bound_now(user, agent)

    assert {:ok, on_grant} = launch(user, agent, "persistent")
    assert on_grant.sandbox_id == home.id
    assert %{"kind" => "codex_chatgpt_access_token"} = on_grant.inference_source

    confirm_limit!(user, agent)

    # The machine keeps its binding: a new persistent conversation lands on
    # the home and is refused rather than moving it to the key.
    assert {:error, :codex_inference_conflict} = launch(user, agent, "persistent")

    assert %{codex_inference_source: %{"kind" => "codex_chatgpt_access_token"}} =
             Repo.reload!(home)

    # The conversation already bound to the grant no longer validates, which
    # is what wake and provision ask.
    assert {:error, :inference_source_changed} =
             InferenceResolution.revalidate(on_grant, agent, [])

    # A launch that does not land on the home runs on the key.
    assert {:ok, fresh} = launch(user, agent, "ephemeral")
    assert fresh.sandbox_id != home.id
    assert %{"kind" => "openai_api_key", "origin" => "platform"} = fresh.inference_source
  end

  test "switch 2: a key-bound home refuses new launches once the reset passes", %{
    user: user,
    agent: agent
  } do
    confirm_limit!(user, agent)
    home = home_bound_now(user, agent)

    assert {:ok, on_key} = launch(user, agent, "persistent")
    assert on_key.sandbox_id == home.id
    assert %{"kind" => "openai_api_key"} = on_key.inference_source

    # The reset passes: selection takes the grant again.
    Repo.update_all(Account,
      set: [
        usage_exhausted_until:
          DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)
      ]
    )

    assert {:error, :codex_inference_conflict} = launch(user, agent, "persistent")
    assert %{codex_inference_source: %{"kind" => "openai_api_key"}} = Repo.reload!(home)

    assert {:error, :inference_source_changed} =
             InferenceResolution.revalidate(on_key, agent, [])

    assert {:ok, fresh} = launch(user, agent, "ephemeral")
    assert fresh.sandbox_id != home.id
    assert %{"kind" => "codex_chatgpt_access_token"} = fresh.inference_source
  end
end
