defmodule FountainMicrosoft.BoundaryTest do
  @moduledoc """
  What the extension owes the host, asserted from the extension's side
  (ADR 0043, ADR 0054, #2152).

  `Fountain.ExtensionGuardTest` checks that core names nothing here. This
  checks the other things the move promised: the contract is implemented and
  no wider than two callbacks, the extension is installed where its suite
  runs, and it has no HTTP surface, no migration and no process to leak.
  """
  use ExUnit.Case, async: true

  alias FountainMicrosoft.Extension

  describe "the extension contract" do
    test "implements every Fountain.Extension callback" do
      assert Extension.id() == :microsoft

      for {fun, arity} <- Fountain.Extension.behaviour_info(:callbacks) do
        assert function_exported?(Extension, fun, arity),
               "FountainMicrosoft.Extension is missing #{fun}/#{arity}"
      end
    end

    test "uses two callbacks and widens the seam with none" do
      # A provider is data the host reads. Everything else must still be the
      # `use Fountain.Extension` default, so a review notices the day one of
      # them stops being one.
      assert Extension.enabled?() == true
      assert Extension.api_mounts() == []
      assert Extension.migrations() == []
      assert Extension.openapi_paths() == %{}
      assert Extension.conversation_mcp_servers("whatever", "token") == []
      assert Extension.admin_overview() == []
      assert Extension.admin_user_columns() == []
      assert Extension.oban_cron() == []

      assert Extension.docs() == FountainMicrosoft.Docs

      assert [%Fountain.Connections.Provider{slug: "microsoft"}] =
               Extension.connection_providers()
    end

    test "is installed in this VM, so the suite exercises it through the seam" do
      assert Extension in Fountain.Extensions.installed()
    end

    test "passes the host's boot validation" do
      assert Fountain.Extensions.validate([Extension]) == :ok
    end

    test "starts no process: the application has no callback module" do
      assert Application.spec(:fountain_microsoft, :mod) in [nil, []]
    end
  end
end
