defmodule Fountain.Workers.SandboxResetReconcilerTest do
  @moduledoc """
  The one-release shim (ADR 0058 stage 9b; 9b-ii deletes it with this file).
  A job the previous release enqueued, in either of its two shapes, completes
  and touches nothing.
  """
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Workers.SandboxResetReconciler

  test "a sweep job from the previous release completes and does nothing" do
    reject(&Fountain.Conversations.retry_pending_sandbox_reset/2)
    assert :ok = perform_job(SandboxResetReconciler, %{})
  end

  test "a per-sandbox job from the previous release completes and does nothing" do
    reject(&Fountain.Conversations.retry_pending_sandbox_reset/2)
    home = insert_sandbox(mode: "persistent", status: "ready")

    home
    |> Ecto.Changeset.change(transition: "destroying", transition_reason: "reset")
    |> Repo.update!()

    assert :ok = perform_job(SandboxResetReconciler, %{sandbox_id: home.id})
    assert Repo.reload!(home).status == "ready"
  end

  test "nothing on this release enqueues it" do
    crontab =
      :fountain
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
        _ -> nil
      end)

    refute Enum.any?(crontab, &(elem(&1, 1) == SandboxResetReconciler))
  end
end
