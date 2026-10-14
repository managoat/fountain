defmodule Fountain.MixedRuntimeRetireMigrationTest do
  @moduledoc """
  The migration that goes with removing mixed-runtime guests (#2676): every
  live persistent machine that has carried a conversation of another agent
  has its guests ended and is stamped `destroying`, so no conversation keeps
  running beside another runtime's credential file once the co-tenant
  redaction is gone.
  """

  use Fountain.DataCase, async: true

  import ExUnit.CaptureLog

  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.Repo
  alias Fountain.Repo.Migrations.RetireMixedRuntimeMachines, as: Migration

  @version 20_261_014_150_000

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261014150000_retire_mixed_runtime_machines.exs",
      __DIR__
    )
  end

  setup do
    user = insert_verified_user()
    host = insert_agent(user_id: user.id, runtime: "codex")
    guest = insert_agent(user_id: user.id, runtime: "claude")
    %{user: user, host: host, guest: guest}
  end

  # `mode` and `runtime` are no longer mapped on `Sandbox` (ADR 0073), so a
  # home of the previous release is written in SQL.
  defp home(ctx, overrides \\ []) do
    sandbox =
      insert_sandbox(
        [user_id: ctx.user.id, agent_id: ctx.host.id, status: "suspended"] ++ overrides
      )

    Repo.query!(
      "UPDATE sandboxes SET mode = 'persistent', runtime = 'codex' WHERE id = $1",
      [Ecto.UUID.dump!(sandbox.id)]
    )

    sandbox
  end

  defp conv(agent, sandbox, status \\ "idle"),
    do: insert_conversation(agent: agent, sandbox: sandbox, status: status)

  test "ends the guests on a mixed home and stamps it destroying", ctx do
    mixed = home(ctx)
    own = conv(ctx.host, mixed)
    guest = conv(ctx.guest, mixed)
    ended_guest = conv(ctx.guest, mixed, "terminated")

    run_up()

    assert Repo.get!(Conversation, guest.id).status == "terminated"
    assert Repo.get!(Conversation, ended_guest.id).status == "terminated"
    assert Repo.get!(Conversation, own.id).status == "idle"

    sandbox = Repo.get!(Sandbox, mixed.id)
    assert {sandbox.transition, sandbox.transition_reason} == {"destroying", "reclaimed"}
    assert sandbox.status == "suspended"
  end

  test "a home that only kept a departed guest's descriptor is retired too", ctx do
    mixed = home(ctx)
    own = conv(ctx.host, mixed)

    Repo.query!(
      "UPDATE sandboxes SET departed_conversations = $2 WHERE id = $1",
      [Ecto.UUID.dump!(mixed.id), [%{"agent_id" => ctx.guest.id, "runtime" => "claude"}]]
    )

    run_up()

    assert Repo.get!(Sandbox, mixed.id).transition == "destroying"
    assert Repo.get!(Conversation, own.id).status == "idle"
  end

  test "leaves single-agent homes, ephemeral and terminal machines alone", ctx do
    single = home(ctx)
    conv(ctx.host, single)

    # Its own agent's departed descriptor is no guest.
    Repo.query!(
      "UPDATE sandboxes SET departed_conversations = $2 WHERE id = $1",
      [Ecto.UUID.dump!(single.id), [%{"agent_id" => ctx.host.id, "runtime" => "codex"}]]
    )

    ephemeral = insert_sandbox(user_id: ctx.user.id, agent_id: ctx.host.id, status: "ready")
    other = conv(ctx.guest, ephemeral)

    gone = home(ctx, status: "terminated")
    gone_guest = conv(ctx.guest, gone, "idle")

    run_up()

    for id <- [single.id, ephemeral.id, gone.id],
        do: assert(Repo.get!(Sandbox, id).transition == nil)

    assert Repo.get!(Conversation, other.id).status == "idle"
    assert Repo.get!(Conversation, gone_guest.id).status == "idle"
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
