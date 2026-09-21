defmodule FountainWeb.TurnInferenceTest do
  @moduledoc """
  The turn's read-only `inference` object (ADR 0060 decision 6): which
  inference source served the turn, from `turns.inference_source`, written
  once when the turn opens.

  The turns here are opened through `TurnMachine.open/6` on a source the
  resolver gave, so the stored map is the one production stores, generation
  and all, and the assertion that none of it reaches a body is about the real
  thing.

  `async: false`: the broker is application env.
  """

  use FountainWeb.ConnCase, async: false

  import Fountain.ChatGPTFixtures

  alias Fountain.ChatGPTAccounts
  alias Fountain.Conversations.{Turn, TurnMachine}
  alias Fountain.Crypto
  alias Fountain.Exports
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Repo

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

    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    # No handler: a turn here that asked the auth server anything would raise.
    stub_auth(%{})

    user = insert_active_user()
    {_key, raw_key} = insert_api_key(user)
    # Outside their refresh margin, so opening a turn renews nothing.
    work = user_grant!(user.id, %{name: "Work", access_token: access_token()})
    side = user_grant!(user.id, %{name: "Side", access_token: access_token()})
    {:ok, set} = InferenceCredentials.create_set(user.id, "Subscription")
    {:ok, set} = InferenceCredentials.set_grant(set, work.id)
    agent = insert_agent(user_id: user.id, runtime: "codex", inference_credential_id: set.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox_id: sandbox.id,
        runtime: "codex"
      )

    %{
      user: user,
      raw_key: raw_key,
      work: work,
      side: side,
      set: set,
      agent: agent,
      sandbox: sandbox,
      conv: conv
    }
  end

  # Resolve as a launch would, bind the conversation to it, run one turn and
  # end it.
  defp run_turn(ctx, prompt) do
    {_source, turn} = open_turn(ctx, prompt)
    turn |> Ecto.Changeset.change(status: "completed") |> Repo.update!()
  end

  defp open_turn(ctx, prompt) do
    {:ok, %Source{} = source, _} =
      InferenceCredentials.resolve(ctx.user.id, ctx.agent.model, "codex",
        credential_set_id: ctx.set.id
      )

    ctx.conv
    |> Repo.reload!()
    |> Ecto.Changeset.change(inference_source: Source.dump(source))
    |> Repo.update!()

    {:ok, _conv, turn} =
      TurnMachine.open(ctx.conv.id, ctx.sandbox.id, prompt, ctx.agent, nil, source)

    {source, turn}
  end

  defp turns(conn, ctx) do
    conn
    |> authed_with_key(ctx.raw_key)
    |> get("/api/conversations/#{ctx.conv.id}/turns")
    |> json_response(200)
    |> Map.fetch!("data")
    |> Enum.sort_by(& &1["turn_number"])
  end

  test "a turn names the subscription that served it, and no fencing value",
       %{conn: conn} = ctx do
    turn = run_turn(ctx, "on work")
    stored = Repo.get!(Turn, turn.id).inference_source
    assert %{"generation" => generation, "identity" => identity} = stored

    assert [%{"inference" => inference, "usage" => usage}] = turns(conn, ctx)

    assert inference == %{
             "origin" => "own",
             "scope" => "grant",
             "chatgpt_grant_id" => ctx.work.id
           }

    # The grant is on `inference` and nowhere in `usage`, which the pricer reads.
    refute inspect(usage) =~ ctx.work.id

    body =
      conn
      |> authed_with_key(ctx.raw_key)
      |> get("/api/conversations/#{ctx.conv.id}/turns")
      |> response(200)

    refute body =~ generation
    refute body =~ identity
    refute body =~ "generation"
    refute body =~ "revision"
  end

  test "a repoint, a reconnect, a removal and a new turn do not relabel an earlier turn",
       %{conn: conn} = ctx do
    run_turn(ctx, "on work")
    work_id = ctx.work.id
    side_id = ctx.side.id

    # Repoint the set, and run the same conversation's next turn on the other one.
    {:ok, set} = InferenceCredentials.set_grant(ctx.set, side_id)
    run_turn(%{ctx | set: set}, "on side")

    # A new sign-in of the first is a new generation of the same grant.
    {:ok, _} =
      ChatGPTAccounts.reconnect_for_user(work_id, ctx.user.id, user_tokens(ctx.work.account_id))

    assert [
             %{"inference" => %{"scope" => "grant", "chatgpt_grant_id" => ^work_id}},
             %{"inference" => %{"scope" => "grant", "chatgpt_grant_id" => ^side_id}}
           ] = turns(conn, ctx)

    # Gone altogether, the turn still says which one it was.
    :ok = ChatGPTAccounts.disconnect_for_user(work_id, ctx.user.id)
    :ok = ChatGPTAccounts.remove_for_user(work_id, ctx.user.id)

    assert [%{"inference" => %{"chatgpt_grant_id" => ^work_id}}, _] = turns(conn, ctx)
  end

  test "a key, the platform and a row with no source", %{conn: conn} = ctx do
    {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
    {:ok, keys} = InferenceCredentials.create_set(ctx.user.id, "Keys")
    {:ok, keys} = InferenceCredentials.put_credential_in(keys, dek, :openai_api_key, "sk-own")
    run_turn(%{ctx | set: keys}, "on a key")

    insert_turn(ctx.conv,
      turn_number: 2,
      inference_source: Source.dump(%{Source.platform() | kind: :openai_api_key})
    )

    insert_turn(ctx.conv, turn_number: 3)

    assert [
             %{"inference" => %{"origin" => "own", "scope" => "credential"} = own},
             %{"inference" => %{"origin" => "platform", "scope" => "platform"} = platform},
             %{"inference" => nil}
           ] = turns(conn, ctx)

    assert own["chatgpt_grant_id"] == nil
    assert platform["chatgpt_grant_id"] == nil
  end

  test "another account's turns are 404", %{conn: conn} = ctx do
    run_turn(ctx, "on work")
    {_key, other_key} = insert_api_key(insert_active_user())

    conn = conn |> authed_with_key(other_key) |> get("/api/conversations/#{ctx.conv.id}/turns")
    assert json_response(conn, 404)
  end

  test "the export's turn entries carry the same object", ctx do
    turn = run_turn(ctx, "on work")
    generation = Repo.get!(Turn, turn.id).inference_source["generation"]

    doc = Exports.build(ctx.user.id)
    conv = Enum.find(doc["conversations"], &(&1["id"] == ctx.conv.id))

    assert [%{"inference" => inference}] = conv["turns"]

    assert inference == %{
             "origin" => "own",
             "scope" => "grant",
             "chatgpt_grant_id" => ctx.work.id
           }

    refute Jason.encode!(doc) =~ generation
  end

  test "Source.summary/1 reads an older row, and refuses a scope it does not know" do
    # Rows from before `"origin"` was stored derive it from the scope.
    assert %{origin: "platform", scope: "platform", chatgpt_grant_id: nil} =
             Source.summary(%{"scope" => "platform", "kind" => "openai_api_key"})

    assert %{origin: "own", scope: "tenant_secret"} =
             Source.summary(%{"scope" => "tenant_secret"})

    assert Source.summary(%{"scope" => "something_new"}) == nil
    assert Source.summary(nil) == nil

    # `chatgpt_grant_id` is a grant's, and a UUID as the schema says, or null.
    id = Ecto.UUID.generate()

    assert %{chatgpt_grant_id: ^id} = Source.summary(%{"scope" => "grant", "grant_id" => id})
    assert %{chatgpt_grant_id: nil} = Source.summary(%{"scope" => "grant", "grant_id" => "x"})
    assert %{chatgpt_grant_id: nil} = Source.summary(%{"scope" => "grant", "grant_id" => 7})
    assert %{chatgpt_grant_id: nil} = Source.summary(%{"scope" => "grant"})

    assert %{chatgpt_grant_id: nil} =
             Source.summary(%{"scope" => "credential", "grant_id" => id})
  end
end
