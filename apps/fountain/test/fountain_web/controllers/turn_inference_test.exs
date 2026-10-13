defmodule FountainWeb.TurnInferenceTest do
  @moduledoc """
  The turn's read-only `inference` object (ADR 0060 decision 6): which
  inference source served the turn, from `turns.inference_source`, written
  once when the turn opens.

  The turns here are opened through `TurnMachine.open/6` on a source the
  resolver gave, so the stored map is the one production stores, identity
  and revision and all, and the assertion that none of it reaches a body is
  about the real thing.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Conversations.{Turn, TurnMachine}
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Repo

  setup do
    user = insert_active_user()
    {_key, raw_key} = insert_api_key(user)
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    {:ok, set} = InferenceCredentials.create_set(user.id, "Keys")
    {:ok, set} = InferenceCredentials.put_credential_in(set, dek, :openai_api_key, "sk-own")
    agent = insert_agent(user_id: user.id, runtime: "codex", inference_credential_id: set.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox_id: sandbox.id,
        runtime: "codex"
      )

    %{user: user, raw_key: raw_key, set: set, agent: agent, sandbox: sandbox, conv: conv}
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

  test "a turn names the source that served it, and no fencing value", %{conn: conn} = ctx do
    turn = run_turn(ctx, "on a key")
    stored = Repo.get!(Turn, turn.id).inference_source
    assert %{"identity" => identity, "revision" => revision} = stored

    assert [%{"inference" => inference}] = turns(conn, ctx)
    assert inference == %{"origin" => "own", "scope" => "credential"}

    body =
      conn
      |> authed_with_key(ctx.raw_key)
      |> get("/api/conversations/#{ctx.conv.id}/turns")
      |> response(200)

    refute body =~ identity
    refute body =~ revision
    refute body =~ "revision"
  end

  test "a restart that reattaches a running turn does not relabel it", %{conn: conn} = ctx do
    {source, row} = open_turn(ctx, "on a key")

    # What a server that restarted holds for the turn it found running: the
    # row, and whatever source its context now names. The peer's report just
    # before the prompt goes out is the one write that stamps a turn.
    machine = %TurnMachine{
      conversation_id: ctx.conv.id,
      sandbox_id: ctx.sandbox.id,
      row: Repo.get!(Turn, row.id),
      metrics: TurnMachine.start_metrics("codex", :runner, System.monotonic_time(:millisecond))
    }

    other = %{source | scope: :tenant_secret, identity: "vault:other", revision: "2"}

    {_machine, []} =
      TurnMachine.handle(
        machine,
        {:model_selected, ctx.agent.model, ctx.agent.model, "runtime"},
        %{inference: other, model: ctx.agent.model}
      )

    assert Repo.get!(Turn, row.id).inference_source == Source.dump(source)
    assert [%{"inference" => %{"scope" => "credential"}}] = turns(conn, ctx)
  end

  test "a key, the platform and a row with no source", %{conn: conn} = ctx do
    run_turn(ctx, "on a key")

    insert_turn(ctx.conv,
      turn_number: 2,
      inference_source: Source.dump(%{Source.platform() | kind: :openai_api_key})
    )

    insert_turn(ctx.conv, turn_number: 3)

    assert [
             %{"inference" => %{"origin" => "own", "scope" => "credential"}},
             %{"inference" => %{"origin" => "platform", "scope" => "platform"}},
             %{"inference" => nil}
           ] = turns(conn, ctx)
  end

  # A turn the retired ChatGPT subscriptions (ADR 0060) ran is history: it is
  # still listed, under the scope today's subscriptions use (ADR 0070).
  test "a turn that ran on a retired ChatGPT subscription is still listed",
       %{conn: conn} = ctx do
    grant_id = Ecto.UUID.generate()

    insert_turn(ctx.conv,
      turn_number: 1,
      inference_source: %{
        "scope" => "grant",
        "kind" => "codex_chatgpt_access_token",
        "identity" => "chatgpt_grant:" <> grant_id,
        "revision" => Ecto.UUID.generate(),
        "grant_id" => grant_id,
        "generation" => Ecto.UUID.generate(),
        "origin" => "own"
      }
    )

    insert_turn(ctx.conv,
      turn_number: 2,
      inference_source: %{
        "scope" => "platform",
        "kind" => "codex_chatgpt_access_token",
        "identity" => "platform:chatgpt:" <> grant_id,
        "origin" => "platform"
      }
    )

    assert [
             %{"inference" => %{"origin" => "own", "scope" => "grant"}},
             %{"inference" => %{"origin" => "platform", "scope" => "platform"}}
           ] = turns(conn, ctx)

    assert %{"data" => %{"id" => _}} =
             conn
             |> authed_with_key(ctx.raw_key)
             |> get("/api/conversations/#{ctx.conv.id}")
             |> json_response(200)
  end

  test "another account's turns are 404", %{conn: conn} = ctx do
    run_turn(ctx, "on a key")
    {_key, other_key} = insert_api_key(insert_active_user())

    conn = conn |> authed_with_key(other_key) |> get("/api/conversations/#{ctx.conv.id}/turns")
    assert json_response(conn, 404)
  end

  test "Source.summary/1 reads an older row, and refuses a scope it does not know" do
    # Rows from before `"origin"` was stored derive it from the scope.
    assert %{origin: "platform", scope: "platform"} =
             Source.summary(%{"scope" => "platform", "kind" => "openai_api_key"})

    assert %{origin: "own", scope: "tenant_secret"} =
             Source.summary(%{"scope" => "tenant_secret"})

    assert Source.summary(%{"scope" => "something_new"}) == nil
    assert Source.summary(nil) == nil
  end
end
