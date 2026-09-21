defmodule Fountain.Broker.Native.LegacyDrainTest do
  @moduledoc """
  ADR 0052 decision 5's rollout fixture: "invalidate and drain legacy
  managed-grant sessions ... no old socket is grandfathered into the HTTP-only
  path."

  Before the deployment's ChatGPT grant moved onto the protected path, a codex
  conversation on it carried the bearer inside its broker session as a
  `substitute` rule. `20260921025746` deletes those sessions, and only those.
  A token still held by a sandbox process then resolves to nothing, and the
  conversation's next server start mints a session that records the grant and
  holds no bearer.

  `async: false`: the platform row and the broker's application env.
  """

  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog
  import Fountain.ChatGPTFixtures

  alias Fountain.Broker
  alias Fountain.Broker.Native.{Session, Sessions}
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Repo.Migrations.DrainLegacyChatgptBrokerSessions, as: Migration
  alias Managoat.Broker.Rule

  @version 20_260_921_025_746

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../../priv/repo/migrations/20260921025746_drain_legacy_chatgpt_broker_sessions.exs",
      __DIR__
    )
  end

  setup do
    previous =
      for key <- [:broker_listen_port, :broker_proxy_url],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    Application.put_env(:fountain, :broker_listen_port, 0)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")

    user = insert_verified_user()
    {:ok, user: user}
  end

  defp conversation(user, source) do
    conv =
      insert_conversation(
        user_id: user.id,
        agent: insert_agent(user_id: user.id, runtime: "codex"),
        runtime: "codex"
      )

    conv
    |> Ecto.Changeset.change(inference_source: source && Source.dump(source))
    |> Repo.update!()
  end

  defp platform_source(grant) do
    %{
      Source.platform()
      | kind: :codex_chatgpt_access_token,
        identity: "platform:chatgpt:" <> grant.id,
        revision: grant.generation
    }
  end

  # A session exactly as the previous release minted one for the grant: the
  # bearer as a substitution rule, and no authorization data.
  defp legacy_session!(conv, user, bearer) do
    {:ok, session} =
      Sessions.create(%{
        conversation_id: conv.id,
        user_id: user.id,
        ttl_seconds: 600,
        rules: [
          %Rule{
            name: "codex-chatgpt-access-token-chatgpt-com",
            pattern: "chatgpt.com",
            scheme: :substitute,
            placeholder: "__codex_chatgpt_access_token__",
            credential: bearer
          }
        ]
      })

    session
  end

  defp drain do
    capture_log(fn ->
      Ecto.Migration.Runner.run(Repo, Repo.config(), @version, Migration, :forward, :up, :up,
        log: false
      )
    end)
  end

  test "drains the sessions that hold the grant's bearer as a rule, and no other", %{user: user} do
    access = access_token()
    grant = connect!(%{access_token: access})
    source = platform_source(grant)

    on_grant = conversation(user, source)
    legacy = legacy_session!(on_grant, user, access)
    assert {:ok, %{rules: [%Rule{credential: ^access}]}} = Sessions.lookup(legacy.token)

    # A conversation on an API key, and one already on the protected path.
    on_key = conversation(user, %{Source.credential() | kind: :openai_api_key})
    {:ok, ordinary} = Broker.prepare(on_key.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
    protected_conv = conversation(user, source)

    {:ok, managed} =
      Broker.prepare(protected_conv.id, %{}, %{},
        user_id: user.id,
        managed: %{owner: :platform, grant_id: grant.id, generation: grant.generation}
      )

    drain()

    # The token a sandbox process may still hold resolves to nothing.
    assert :error = Sessions.lookup(legacy.token)
    assert {:ok, _} = Sessions.lookup(ordinary.token)
    assert {:ok, %{protected: %{}}} = Sessions.lookup(managed.token)

    assert Repo.aggregate(from(s in Session, where: s.conversation_id == ^on_grant.id), :count) ==
             0

    # What the conversation gets when its server next starts: a session that
    # records the grant, and holds its bearer nowhere.
    {:ok, fresh} =
      Broker.prepare(
        on_grant.id,
        %{},
        %{},
        Fountain.Conversations.Egress.session_opts(%{
          broker_network: :unrestricted,
          user_id: user.id,
          inference_source: source
        })
      )

    assert {:ok, %{rules: [], http_only: true, authorization: {:managed, _}}} =
             Sessions.lookup(fresh.token)

    row = Repo.one!(from s in Session, where: s.conversation_id == ^on_grant.id)
    assert row.managed_grant_id == grant.id
    assert is_nil(row.managed_grant_owner_id)
  end

  test "is a no-op where there is nothing to drain, and running it again is harmless", %{
    user: user
  } do
    on_key = conversation(user, nil)
    {:ok, ordinary} = Broker.prepare(on_key.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

    drain()
    drain()

    assert {:ok, _} = Sessions.lookup(ordinary.token)
  end
end
