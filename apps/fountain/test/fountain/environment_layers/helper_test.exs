defmodule Fountain.EnvironmentLayers.HelperTest do
  use ExUnit.Case, async: true
  use Mimic
  alias Fountain.EnvironmentLayers.Helper
  alias Managoat.Sandbox

  test "export transport waits for its bounded helper budget without extending restore" do
    handle = %Managoat.Sandbox.Handle{provider: :sprites, name: "helper-test"}
    parent = self()

    stub(Sandbox, :write_file, fn ^handle, file, json, opts ->
      assert opts[:mode] == 0o600
      request = Jason.decode!(json)
      assert request["cleanup_file"] == file
      send(parent, {:operation, request["operation"]})
      :ok
    end)

    stub(Sandbox, :exec, fn ^handle, "sh", _, opts ->
      assert_receive {:operation, operation}
      assert opts[:timeout] == if(operation == "export", do: 305_000, else: 125_000)
      {:ok, ~s({"ok":true,"result":{}}), 0}
    end)

    for operation <- ["export", "restore", "fetch", "snapshot"] do
      assert {:ok, _} = Helper.call(handle, %{operation: operation})
    end
  end
end
