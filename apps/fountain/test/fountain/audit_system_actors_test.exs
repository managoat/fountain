defmodule Fountain.AuditSystemActorsTest do
  @moduledoc """
  Background paths that mutate tenant data leave a trail too (#551).

  The precedent this follows is `UnverifiedAccountPruner`, which deletes
  through `Accounts.Deletion` with `actor: "system:unverified_pruner"` and gets
  audited for free. Everything here was the opposite: real changes to a
  tenant's data, attributable to nothing but a line in the server log.

  The sharpest case is the retention pruner, which deletes `audit_events`
  itself — so before this the trail could shrink with no record of when or by
  how much.
  """

  use Fountain.DataCase, async: true

  import Ecto.Query

  alias Fountain.{Audit, Repo}
  alias Fountain.Workers.RetentionPruner

  defp system_events(action) do
    Audit._unsafe_list_recent(200) |> Enum.filter(&(&1.action == action))
  end

  defp find_for_user(user_id, action) do
    user_id |> Audit.list_recent_for_user(200) |> Enum.find(&(&1.action == action))
  end

  defp backdate_audit_events(days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    Repo.update_all(from(e in Audit.Event), set: [inserted_at: cutoff])
  end

  describe "the retention pruner accounts for its own deletions" do
    test "a run that deleted rows records a summary with per-table counts" do
      user = insert_verified_user()

      # Give it something to delete: age every audit row past the window.
      # These are the account's own registration/creation events (#544).
      assert Repo.aggregate(from(e in Audit.Event), :count) > 0
      backdate_audit_events(400)

      # perform/1, not prune/1 — the summary is a property of a run, and
      # pruning first would leave the run with nothing to account for.
      :ok = RetentionPruner.perform(%Oban.Job{args: %{}})

      assert [event] = system_events("retention.pruned")
      assert event.actor == "system:retention_pruner"
      assert event.resource_type == "retention_run"

      # A system event spans every tenant, so it belongs to the admin view
      # rather than to any one trail.
      assert event.user_id == nil
      refute find_for_user(user.id, "retention.pruned")
    end

    test "the summary survives the run that wrote it" do
      # Written after the pruning, so a shortened window cannot delete the
      # record of the deletion. This is the property that makes the trail able
      # to account for its own shrinkage.
      insert_verified_user()
      backdate_audit_events(400)

      :ok = RetentionPruner.perform(%Oban.Job{args: %{}})

      assert [event] = system_events("retention.pruned")
      assert event.metadata["total"] > 0
      assert event.metadata["audit_events"] > 0
    end

    test "a run that deleted nothing records nothing" do
      # A daily row saying "removed nothing" would bury the ones that matter.
      :ok = RetentionPruner.perform(%Oban.Job{args: %{}})

      assert system_events("retention.pruned") == []
    end
  end
end
