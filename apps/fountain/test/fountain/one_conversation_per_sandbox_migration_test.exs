defmodule Fountain.OneConversationPerSandboxMigrationTest do
  @moduledoc """
  The migration that goes with removing persistent homes (ADR 0073): a live
  sandbox that carries several live conversations keeps one (the Team
  conversation, else the one with the newest turn), and the rest are
  detached onto a terminated placeholder of their own, so their next prompt
  provisions a fresh machine.
  """

  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog

  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.Repo
  alias Fountain.Repo.Migrations.OneConversationPerSandbox, as: Migration

  @version 20_261_014_160_000

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261014160000_one_conversation_per_sandbox.exs",
      __DIR__
    )
  end

  setup do
    restore_home_columns!()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)

    home =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        status: "suspended",
        machine_name: "home-#{System.unique_integer([:positive])}"
      )

    %{user: user, agent: agent, home: home}
  end

  defp conv(ctx, overrides) do
    insert_conversation(
      [user_id: ctx.user.id, agent: ctx.agent, sandbox: ctx.home, status: "idle"] ++ overrides
    )
  end

  defp turn_minutes_ago(conv, minutes) do
    turn = insert_turn(conv, status: "completed")
    at = DateTime.utc_now() |> DateTime.add(-minutes * 60) |> DateTime.truncate(:second)
    turn |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end

  test "the Team conversation keeps the machine; the others are detached", ctx do
    team = conv(ctx, channel_id: "fountain:team")
    turn_minutes_ago(team, 600)
    newest = conv(ctx, runtime_session_id: "sess-newest")
    turn_minutes_ago(newest, 1)
    ended = conv(ctx, status: "terminated")

    run_up()

    assert Repo.get!(Conversation, team.id).sandbox_id == ctx.home.id
    assert Repo.get!(Conversation, ended.id).sandbox_id == ctx.home.id

    moved = Repo.get!(Conversation, newest.id)
    refute moved.sandbox_id == ctx.home.id
    assert moved.status == "idle"
    assert is_nil(moved.runtime_session_id)

    placeholder = Repo.get!(Sandbox, moved.sandbox_id)
    assert placeholder.status == "terminated"
    assert placeholder.user_id == ctx.user.id
    assert placeholder.machine_name == ctx.home.machine_name

    assert Repo.get!(Sandbox, ctx.home.id).status == "suspended"
  end

  test "without a Team conversation the most recent turn keeps it", ctx do
    old = conv(ctx, [])
    turn_minutes_ago(old, 600)
    recent = conv(ctx, [])
    turn_minutes_ago(recent, 1)

    run_up()

    assert Repo.get!(Conversation, recent.id).sandbox_id == ctx.home.id
    refute Repo.get!(Conversation, old.id).sandbox_id == ctx.home.id
  end

  test "a machine with one live conversation, and a terminal machine, are left alone", ctx do
    only = conv(ctx, [])
    gone = insert_sandbox(user_id: ctx.user.id, status: "terminated")
    a = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: gone, status: "idle")
    b = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: gone, status: "idle")

    run_up()
    run_up()

    assert Repo.get!(Conversation, only.id).sandbox_id == ctx.home.id
    assert Repo.get!(Conversation, a.id).sandbox_id == gone.id
    assert Repo.get!(Conversation, b.id).sandbox_id == gone.id
  end

  defp run_up do
    capture_log(fn ->
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        @version,
        Migration,
        :forward,
        :up,
        :up,
        log: false
      )
    end)
  end
end
