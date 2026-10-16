defmodule Fountain.EnvironmentLayers.HelperInstallTest do
  # Installation reads an operator-configured release directory. Serialize the
  # real-file fixture because the application configuration is global.
  use ExUnit.Case, async: false
  use Mimic
  alias Fountain.EnvironmentLayers.Helper
  alias Managoat.Sandbox

  test "installation identifies the failed step without retaining provider payloads" do
    handle = %Managoat.Sandbox.Handle{provider: :sprites, name: "helper-test"}
    directory = Fountain.TmpDir.mkdir!("helper-fixture")
    previous = Application.fetch_env(:fountain, :environment_layer_helper_dir)
    Application.put_env(:fountain, :environment_layer_helper_dir, directory)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fountain, :environment_layer_helper_dir, value)
        :error -> Application.delete_env(:fountain, :environment_layer_helper_dir)
      end

      File.rm_rf!(directory)
    end)

    binary = Helper.path("amd64")
    File.write!(binary, "trusted fixture")

    steps = [:write_binary, :create_directory, :install_binary, :remove_staging]

    for step <- steps,
        {failure, expected} <- [
          {{:error, {:provider, :sprites, "secret-provider-response"}}, :provider_error},
          {{:error, {:unavailable, {:exec_timeout, 30_000}}}, :timeout},
          {{:error, {:denied, "secret-policy"}}, :denied},
          {{:error, "secret-unexpected"}, :helper_unavailable},
          {{:ok, "secret-command-output", 23}, {:command_exit, 23}}
        ] do
      parent = self()

      stub(Sandbox, :write_file, fn ^handle, _, "trusted fixture", _ ->
        send(parent, {:step, :write_binary})
        if step == :write_binary, do: failure, else: :ok
      end)

      stub(Sandbox, :exec, fn ^handle, command, args, _ ->
        current =
          case {command, args} do
            {"sudo", ["install", "-d" | _]} -> :create_directory
            {"sudo", ["install", "-m" | _]} -> :install_binary
            {"rm", _} -> :remove_staging
          end

        send(parent, {:step, current})
        if step == current, do: failure, else: {:ok, "", 0}
      end)

      assert Helper.install(handle, "amd64") ==
               {:error, {:helper_install_failed, step, expected}}

      {visited, remaining} = Enum.split_while(steps, &(&1 != step))
      for current <- visited ++ [step], do: assert_receive({:step, ^current})
      for current <- tl(remaining), do: refute_received({:step, ^current})
    end

    stub(Sandbox, :write_file, fn ^handle, _, "trusted fixture", opts ->
      assert opts[:mode] == 0o700
      :ok
    end)

    stub(Sandbox, :exec, fn ^handle, _, _, opts ->
      assert opts[:timeout] == 30_000
      {:ok, "", 0}
    end)

    assert :ok = Helper.install(handle, "amd64")
    File.rm!(binary)

    assert Helper.install(handle, "amd64") ==
             {:error, {:helper_install_failed, :read_binary, :not_found}}

    refute_received {:step, _}
  end
end
