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

  test "helper failure protocol keeps only known codes and safe exits" do
    handle = %Managoat.Sandbox.Handle{provider: :sprites, name: "helper-test"}
    stub(Sandbox, :write_file, fn _, _, _, _ -> :ok end)

    for code <-
          ~w(invalid_layer limit_exceeded incompatible_layer authentication_failed unsafe_archive transfer_failed canceled timeout) do
      stub(Sandbox, :exec, fn _, _, _, _ ->
        {:ok, Jason.encode!(%{ok: false, error: code, output: "secret-output"}), 1}
      end)

      assert Helper.call(handle, %{operation: "export"}) == {:error, {:helper_failed, code, 1}}
    end

    for {json, exit_code} <- [
          {~s({"ok":false,"error":"secret-error"}), 1},
          {String.duplicate("secret", 1000), 1},
          {~s({"ok":true,"result":{}}), 1},
          {~s({"ok":false,"error":"timeout"}), 300}
        ] do
      stub(Sandbox, :exec, fn _, _, _, _ -> {:ok, json, exit_code} end)
      assert {:error, :layer_operation_failed} = Helper.call(handle, %{operation: "export"})
    end

    stub(Sandbox, :exec, fn _, _, _, _ -> {:error, :timeout} end)
    assert {:error, :timeout} = Helper.call(handle, %{operation: "export"})
  end
end
