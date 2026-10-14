defmodule Fountain.Machines.PolicyTest do
  @moduledoc """
  What a reclaim does to a machine (ADR 0058 stage 7a; ADR 0017). Since
  persistent homes were removed (ADR 0073), every machine is one
  conversation's: an idle one parks where the provider can, and the ceiling
  destroys.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations.Lifecycle
  alias Fountain.Machines.Policy

  defp can_park, do: stub(Managoat.Sandbox, :supports?, fn _p, cap -> cap == :suspend end)
  defp cannot_park, do: stub(Managoat.Sandbox, :supports?, fn _p, _cap -> false end)

  describe "idle_action/1" do
    test "a provider that can park, parks" do
      can_park()
      assert Policy.idle_action(:sprites) == :suspend
    end

    test "a provider that cannot, destroys — the cost control wins" do
      cannot_park()
      assert Policy.idle_action(:sprites) == :destroy
    end
  end

  describe "reclaim_action/2" do
    test "the idle bound parks where the provider can, and destroys where it cannot" do
      can_park()
      assert Policy.reclaim_action(:idle, :sprites) == :park
      cannot_park()
      assert Policy.reclaim_action(:idle, :sprites) == :destroy
    end

    test "the ceiling destroys, whatever the provider" do
      can_park()
      assert Policy.reclaim_action(:max_lifetime, :sprites) == :destroy
      cannot_park()
      assert Policy.reclaim_action(:max_lifetime, :sprites) == :destroy
    end
  end

  describe "the call sites delegate" do
    test "Lifecycle.idle_action/1 is this one" do
      cannot_park()
      assert Lifecycle.idle_action(:sprites) == Policy.idle_action(:sprites)
    end

    test "Lifecycle.idle_machine_action/1 is reclaim_action(:idle, …)" do
      can_park()
      handle = Managoat.Sandbox.build_handle(:sprites, "whatever")
      assert Lifecycle.idle_machine_action(handle) == :park
    end
  end
end
