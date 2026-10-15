defmodule Managoat.Sandbox.SpritesCheckpointsTest do
  # Checkpoints need `:checkpoint_creation_enabled`, which is global application
  # env, so they live in this async: false sibling of sprites_test.exs (see the
  # async guardrail).
  use ExUnit.Case, async: false
  use Mimic

  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.Sprites, as: Adapter

  @name "fountain-abc12345-deadbeef"

  defp handle, do: %Handle{provider: :sprites, name: @name}

  defp stub_client do
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{token: "test-token"} end)
  end

  setup do
    prior = Application.get_env(:fountain, Adapter)
    Application.put_env(:fountain, Adapter, checkpoint_creation_enabled: true)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:fountain, Adapter, prior),
        else: Application.delete_env(:fountain, Adapter)
    end)

    :ok
  end

  describe "checkpoints, enabled" do
    test "create drains the stream then resolves the id from the listing" do
      stub_client()
      stub(Sprites, :create_checkpoint, fn _sprite, [comment: "env x"] -> {:ok, []} end)

      stub(Sprites, :list_checkpoints, fn _sprite ->
        {:ok,
         [
           %Sprites.Checkpoint{id: "Current", create_time: ~U[2026-08-14 12:00:00Z]},
           %Sprites.Checkpoint{
             id: "v2",
             comment: "env x",
             create_time: ~U[2026-08-14 11:00:00Z]
           },
           %Sprites.Checkpoint{id: "v1", comment: "env x", create_time: ~U[2026-08-14 10:00:00Z]}
         ]}
      end)

      assert {:ok, "v2"} = Adapter.create_checkpoint(handle(), comment: "env x")
    end

    test "create with no resolvable id is an error" do
      stub_client()
      stub(Sprites, :create_checkpoint, fn _sprite, _opts -> {:ok, []} end)
      stub(Sprites, :list_checkpoints, fn _sprite -> {:ok, []} end)

      assert {:error, {:provider, :sprites, :no_checkpoint_id}} =
               Adapter.create_checkpoint(handle(), comment: "env x")
    end

    test "create failures and a failed follow-up listing remain errors" do
      stub_client()
      stub(Sprites, :create_checkpoint, fn _sprite, _opts -> {:error, :timeout} end)
      assert {:error, {:unavailable, :timeout}} = Adapter.create_checkpoint(handle(), [])

      stub(Sprites, :create_checkpoint, fn _sprite, _opts -> {:ok, []} end)
      stub(Sprites, :list_checkpoints, fn _sprite -> {:error, :timeout} end)

      assert {:error, {:provider, :sprites, :no_checkpoint_id}} =
               Adapter.create_checkpoint(handle(), [])
    end

    test "restore succeeds only when the stream reports no error element" do
      stub_client()
      stub(Sprites, :restore_checkpoint, fn _sprite, "v1" -> {:ok, [%{type: "info"}]} end)
      assert :ok = Adapter.restore_checkpoint(handle(), "v1")
    end

    test "a reported-failed restore is an error, not :ok" do
      stub_client()

      stub(Sprites, :restore_checkpoint, fn _sprite, "v1" ->
        {:ok, [%{type: "info"}, %{type: "error", error: "no such checkpoint"}]}
      end)

      assert {:error, {:restore_failed, "no such checkpoint"}} =
               Adapter.restore_checkpoint(handle(), "v1")

      stub(Sprites, :restore_checkpoint, fn _sprite, "v1" ->
        {:ok, [%{type: "info", error: "restore aborted"}]}
      end)

      assert {:error, {:restore_failed, "restore aborted"}} =
               Adapter.restore_checkpoint(handle(), "v1")
    end

    test "restore call and lazy stream failures are returned, not raised" do
      stub_client()
      stub(Sprites, :restore_checkpoint, fn _sprite, "v1" -> {:error, :timeout} end)
      assert {:error, {:unavailable, :timeout}} = Adapter.restore_checkpoint(handle(), "v1")

      broken = Stream.map([:item], fn _ -> raise "stream broke" end)
      stub(Sprites, :restore_checkpoint, fn _sprite, "v1" -> {:ok, broken} end)

      assert {:error, {:provider, :sprites, {:stream_raised, %RuntimeError{}}}} =
               Adapter.restore_checkpoint(handle(), "v1")
    end
  end

  describe "checkpoints, disabled" do
    # Unadvertised means refused, before the SDK is reached: the conformance
    # case's capability-coherence rule, which the live suite found Sprites
    # breaking with the flag off.
    test "create and restore are refused without touching the SDK" do
      Application.put_env(:fountain, Adapter, checkpoint_creation_enabled: false)
      reject(&Sprites.create_checkpoint/2)
      reject(&Sprites.restore_checkpoint/2)

      refute MapSet.member?(Adapter.capabilities(), :checkpoint)
      assert {:error, :not_supported} = Adapter.create_checkpoint(handle(), [])
      assert {:error, :not_supported} = Adapter.restore_checkpoint(handle(), "v1")
    end
  end
end
