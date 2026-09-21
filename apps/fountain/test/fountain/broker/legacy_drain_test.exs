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

  The migration runs once and a replica still on the previous release can
  write such a session after it, so `Sessions` drains continuously too: rules
  that name the reserved credential are served by nothing, and the row goes.

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
        rules: [legacy_rule(bearer)]
      })

    session
  end

  defp legacy_rule(bearer) do
    %Rule{
      name: "codex-chatgpt-access-token-chatgpt-com",
      pattern: "chatgpt.com",
      scheme: :substitute,
      placeholder: "__codex_chatgpt_access_token__",
      credential: bearer
    }
  end

  defp sessions_of(conv),
    do: Repo.aggregate(from(s in Session, where: s.conversation_id == ^conv.id), :count)

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
    # Not looked up before the migration runs: a lookup would drain it first.
    assert sessions_of(on_grant) == 1

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

    assert sessions_of(on_grant) == 0

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

  describe "after the migration has run, a replica on the previous release" do
    setup do
      Fountain.LogThrottle.reset()
      drain()
      :ok
    end

    test "mints another legacy session: refused at the lookup and removed, in one line", %{
      user: user
    } do
      access = access_token()
      grant = connect!(%{access_token: access})
      conv = conversation(user, platform_source(grant))

      first = legacy_session!(conv, user, access)
      second = legacy_session!(conv, user, access)

      log =
        capture_log(fn ->
          assert :error = Sessions.lookup(first.token)
          assert :error = Sessions.lookup(first.token)
          assert :error = Sessions.lookup(second.token)
        end)

      assert sessions_of(conv) == 0
      assert [_once] = Regex.scan(~r/held a managed ChatGPT credential as a rule/, log)
      refute log =~ access
    end

    test "is refused whatever else its rules hold, and by a custom rule's brokered map", %{
      user: user
    } do
      access = access_token()
      conv = conversation(user, nil)

      {:ok, session} =
        Sessions.create(%{
          conversation_id: conv.id,
          user_id: user.id,
          ttl_seconds: 600,
          rules: [
            %Rule{name: "gh", pattern: "api.github.com", scheme: :bearer, credential: "g"},
            %Rule{
              name: "export",
              pattern: "example.com",
              scheme: :custom,
              template: %{"x-export" => "{{ GH_TOKEN }}"},
              credential: %{"GH_TOKEN" => "g", "CODEX_CHATGPT_ACCESS_TOKEN" => access}
            }
          ]
        })

      capture_log(fn -> assert :error = Sessions.lookup(session.token) end)
      assert sessions_of(conv) == 0
    end

    test "rewrites a managed session's rules on a rotation: denied per request and removed", %{
      user: user
    } do
      access = access_token()
      grant = connect!(%{access_token: access})
      conv = conversation(user, platform_source(grant))

      {:ok, managed} =
        Broker.prepare(conv.id, %{}, %{},
          user_id: user.id,
          managed: %{owner: :platform, grant_id: grant.id, generation: grant.generation}
        )

      # A tunnel opened before the rewrite holds the reference already.
      assert {:ok, %{authorization: reference}} = Sessions.lookup(managed.token)
      assert {:ok, []} = Sessions.authorize(reference, %{protected: false})

      # What the previous release's rotation does: every live session of the
      # conversation, this one included, gets the bearer as a rule.
      assert {:ok, 1} = Sessions.update_rules(conv.id, user.id, [legacy_rule(access)], %{})

      capture_log(fn ->
        assert {:error, :denied} = Sessions.authorize(reference, %{protected: false})
      end)

      assert sessions_of(conv) == 0
      assert :error = Sessions.lookup(managed.token)
    end

    test "does not touch a session whose secret's value mentions the reserved name", %{
      user: user
    } do
      conv = conversation(user, nil)
      value = "export CODEX_CHATGPT_ACCESS_TOKEN=unset # a tenant's own script"
      {:ok, ordinary} = Broker.prepare(conv.id, %{"GH_TOKEN" => value}, %{}, user_id: user.id)

      assert {:ok, %{rules: [_ | _]}} = Sessions.lookup(ordinary.token)
      assert sessions_of(conv) == 1
    end
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
