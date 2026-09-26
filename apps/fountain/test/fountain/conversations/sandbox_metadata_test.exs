defmodule Fountain.Conversations.SandboxMetadataTest do
  use Fountain.DataCase, async: true

  import ExUnit.CaptureIO

  alias Fountain.Conversations.Sandbox
  alias Fountain.Release

  test "release inventory reports retained DB facts, leaves disks unverified and changes nothing" do
    first = insert_verified_user()
    second = insert_verified_user()

    ready =
      insert_sandbox(
        user_id: first.id,
        status: "ready",
        build_fingerprint: "none",
        applied_skills_by_runtime: %{"claude" => [%{"content" => "private-skill-content"}]},
        provider_meta: %{"token" => "private-provider-token"}
      )

    sleeping = insert_sandbox(user_id: second.id, status: "suspended")
    failed = insert_sandbox(user_id: first.id, status: "failed", build_fingerprint: "none")
    pending = insert_sandbox(user_id: first.id, status: "pending")
    starting = insert_sandbox(user_id: second.id, status: "starting")
    terminated = insert_sandbox(user_id: first.id, status: "terminated")
    before = Repo.all(from s in Sandbox, order_by: s.id)

    output = capture_io(fn -> Release.inventory_sandbox_metadata() end)
    assert capture_io(fn -> Release.inventory_sandbox_metadata() end) == output
    report = Jason.decode!(output)

    assert report["counts"] == %{
             "retained" => 5,
             "missing_build_fingerprint" => 3,
             "missing_applied_skills" => 4
           }

    assert report["disk_skill_manifests"] == "unverified"
    rows = Map.new(report["sandboxes"], &{&1["sandbox_id"], &1})

    assert Map.keys(rows) |> Enum.sort() ==
             Enum.sort([ready.id, sleeping.id, failed.id, pending.id, starting.id])

    refute Map.has_key?(rows, terminated.id)
    assert rows[sleeping.id]["user_id"] == second.id
    assert rows[sleeping.id]["status"] == "suspended"
    refute rows[sleeping.id]["build_fingerprint_recorded"]
    refute rows[sleeping.id]["applied_skills_recorded"]
    assert rows[ready.id]["build_fingerprint_recorded"]
    assert rows[ready.id]["applied_skills_recorded"]
    refute output =~ "private-skill-content"
    refute output =~ "private-provider-token"
    assert Repo.all(from s in Sandbox, order_by: s.id) == before
  end
end
