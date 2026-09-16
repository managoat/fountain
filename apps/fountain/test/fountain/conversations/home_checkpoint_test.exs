defmodule Fountain.Conversations.HomeCheckpointTest do
  @moduledoc """
  A persistent home is checkpointed when it parks, where the provider can
  (ADR 0023, #1073). The checkpoint is best-effort and machine-scoped: it is
  recorded on the row and on every live transcript, and a failure never
  blocks the park.

  Since ADR 0058 stage 6b the recording goes through the machine's lease:
  `on_park/2` takes the epoch its caller holds and writes `provider_meta` with
  `Fountain.Machines.Lease.cas_update/3` instead of
  `Conversations.update_sandbox/2`. Every case here therefore claims a lease
  first, which is what the one caller — `Fountain.Machines.Park`, mid-park —
  has already done. The last case in the file is the new half of the contract:
  a checkpoint recorded under an epoch that is no longer the lease writes
  nothing.
  """
  use Fountain.DataCase, async: true
  use Mimic

  import Ecto.Query

  alias Fountain.Conversations.{HomeCheckpoint, LogEvent}
  alias Fountain.Machines.Lease
  alias Fountain.Repo

  defp home(user, overrides \\ %{}) do
    insert_sandbox(
      Map.merge(
        %{user_id: user.id, status: "ready", mode: "persistent", provider: "sprites"},
        overrides
      )
    )
  end

  # The lease `Park` holds when it calls `on_park/2`.
  defp lease(sandbox) do
    {:ok, epoch} = Lease.claim(sandbox.id, "test@nohost", 60_000)
    epoch
  end

  defp stages(conv_id) do
    Repo.all(
      from e in LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == "checkpoint",
        select: {e.state, e.data}
    )
  end

  describe "on_park/2" do
    test "records the checkpoint on the row and on every live transcript" do
      user = insert_verified_user()
      sandbox = home(user)
      a = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      b = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      gone = insert_conversation(user_id: user.id, sandbox: sandbox, status: "terminated")

      stub(Managoat.Sandbox, :supports?, fn :sprites, :checkpoint -> true end)

      stub(Managoat.Sandbox, :create_checkpoint, fn handle, opts ->
        assert handle.name == sandbox.machine_name
        assert opts[:comment] == "home park #{sandbox.id}"
        {:ok, "v7"}
      end)

      assert {:ok, "v7"} = HomeCheckpoint.on_park(sandbox, lease(sandbox))

      reloaded = Repo.reload(sandbox)
      assert reloaded.provider_meta["checkpoint_id"] == "v7"
      assert {:ok, _, _} = DateTime.from_iso8601(reloaded.provider_meta["checkpoint_at"])
      assert %{id: "v7", at: at} = HomeCheckpoint.recorded(reloaded)
      assert at == reloaded.provider_meta["checkpoint_at"]

      for conv <- [a, b] do
        assert [{"done", data}] = stages(conv.id)
        assert Jason.decode!(data)["checkpoint_id"] == "v7"
      end

      assert stages(gone.id) == []
    end

    test "keeps the rest of provider_meta" do
      user = insert_verified_user()
      sandbox = home(user, %{provider_meta: %{"public_url" => "https://x.example"}})
      stub(Managoat.Sandbox, :supports?, fn :sprites, :checkpoint -> true end)
      stub(Managoat.Sandbox, :create_checkpoint, fn _handle, _opts -> {:ok, "v1"} end)

      assert {:ok, "v1"} = HomeCheckpoint.on_park(sandbox, lease(sandbox))
      assert Repo.reload(sandbox).provider_meta["public_url"] == "https://x.example"
    end

    test "an ephemeral sandbox is never checkpointed" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready", mode: "ephemeral")
      stub(Managoat.Sandbox, :supports?, fn _provider, :checkpoint -> true end)
      reject(&Managoat.Sandbox.create_checkpoint/2)

      assert :skipped = HomeCheckpoint.on_park(sandbox, lease(sandbox))
      assert Repo.reload(sandbox).provider_meta == %{}
    end

    test "a provider without checkpoints is skipped" do
      user = insert_verified_user()
      sandbox = home(user, %{provider: "e2b"})
      stub(Managoat.Sandbox, :supports?, fn :e2b, :checkpoint -> false end)
      reject(&Managoat.Sandbox.create_checkpoint/2)

      assert :skipped = HomeCheckpoint.on_park(sandbox, lease(sandbox))
    end

    test "a failed checkpoint is recorded as a failed stage and does not touch the row" do
      user = insert_verified_user()
      sandbox = home(user)
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      stub(Managoat.Sandbox, :supports?, fn :sprites, :checkpoint -> true end)

      stub(Managoat.Sandbox, :create_checkpoint, fn _handle, _opts ->
        {:error, {:invalid, "checkpoints disabled for this sprite"}}
      end)

      assert {:error, {:invalid, _}} = HomeCheckpoint.on_park(sandbox, lease(sandbox))
      assert Repo.reload(sandbox).provider_meta == %{}
      assert [{"failed", data}] = stages(conv.id)
      assert Jason.decode!(data)["reason"] =~ "checkpoints disabled"
    end

    test "a checkpoint taken under a superseded epoch is not recorded" do
      # The compare-and-set half of ADR 0058 applied to this write. The park
      # that asked for the checkpoint lost the machine while the provider was
      # taking it, so the id it came back with describes a machine somebody
      # else now owns — and a reset reading `provider_meta` would roll to it.
      # The checkpoint itself exists at the provider either way; what must not
      # exist is the pointer.
      user = insert_verified_user()
      sandbox = home(user)
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")

      stale = lease(sandbox)
      :ok = Lease.release(sandbox.id, stale)
      _newer = lease(sandbox)

      stub(Managoat.Sandbox, :supports?, fn :sprites, :checkpoint -> true end)
      stub(Managoat.Sandbox, :create_checkpoint, fn _handle, _opts -> {:ok, "v9"} end)

      assert {:ok, "v9"} = HomeCheckpoint.on_park(sandbox, stale)

      assert Repo.reload(sandbox).provider_meta == %{}
      assert HomeCheckpoint.recorded(Repo.reload(sandbox)) == nil
      assert [{"failed", data}] = stages(conv.id)
      assert Jason.decode!(data)["checkpoint_id"] == "v9"
    end
  end

  describe "recorded/1" do
    test "is nil until a park has recorded one" do
      # Two users: a user has one home per identity (the partial unique
      # index), and both of these have the empty identity.
      assert HomeCheckpoint.recorded(home(insert_verified_user())) == nil

      with_url = home(insert_verified_user(), %{provider_meta: %{"public_url" => "u"}})
      assert HomeCheckpoint.recorded(with_url) == nil
    end
  end
end
