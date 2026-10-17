defmodule Fountain.Broker.MaterializedRulesTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts.UserDataKey
  alias Fountain.Broker.Native.Session
  alias Fountain.Broker.Native.Sessions
  alias Fountain.Crypto
  alias Managoat.Broker.Rule

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    {:ok, session} =
      Sessions.create(%{
        user_id: user.id,
        conversation_id: conv.id,
        ttl_seconds: 600,
        rules: rules("first"),
        meta: %{"owner" => user.id}
      })

    %{user: user, conv: conv, token: session.token}
  end

  test "warm reads retain one authority query and skip both decryptions", %{token: token} do
    parent = self()
    handler = "cache-query-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:fountain, :repo, :query],
      fn _, _, _, _ ->
        if self() == parent, do: send(parent, :query)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, first} = Sessions.lookup(token)
    assert_receive :query
    refute_receive :query
    assert {:ok, ^first} = Sessions.lookup(token)
    assert_receive :query
    refute_receive :query
  end

  test "rotation and policy use the current row; release cannot hit cached authority", ctx do
    assert {:ok, %{rules: [%{credential: "first"}]}} = Sessions.lookup(ctx.token)

    assert {:ok, 1} =
             Sessions.update_rules(ctx.conv.id, ctx.user.id, rules("second"), %{"new" => true})

    assert {:ok, %{rules: [%{credential: "second"}], meta: %{"new" => true}}} =
             Sessions.lookup(ctx.token)

    Repo.update_all(Session, set: [unmatched_host_policy: "deny"])
    assert {:ok, %{unmatched_host_policy: :deny}} = Sessions.lookup(ctx.token)
    assert :ok = Sessions.release_session(ctx.user.id, ctx.conv.id, ctx.token)
    assert :error = Sessions.lookup(ctx.token)
  end

  test "expiry is checked even with warm rules", %{token: token} do
    assert {:ok, _} = Sessions.lookup(token)
    Repo.update_all(Session, set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])
    assert :error = Sessions.lookup(token)
  end

  test "changed or removed tenant key cannot reuse plaintext", %{token: token, user: user} do
    assert {:ok, _} = Sessions.lookup(token)

    from(k in UserDataKey, where: k.user_id == ^user.id)
    |> Repo.update_all(set: [wrapped_key: Crypto.wrap_dek(Crypto.generate_dek())])

    assert :error = Sessions.lookup(token)
    from(k in UserDataKey, where: k.user_id == ^user.id) |> Repo.delete_all()
    assert :error = Sessions.lookup(token)
  end

  defp rules(value),
    do: [%Rule{name: "test", pattern: "example.com", scheme: :bearer, credential: value}]
end
