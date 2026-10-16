defmodule Fountain.EnvironmentLayers.Helper do
  @moduledoc "Trusted Linux helper installation and bounded, file-based control protocol."
  alias Managoat.Sandbox

  @failure_codes ~w(invalid_request key_generation_failed operation_failed invalid_layer limit_exceeded incompatible_layer authentication_failed unsafe_archive transfer_failed canceled timeout)

  @directory "/opt/managoat-layer"
  @binary @directory <> "/helper"

  def path(architecture) when architecture in ["amd64", "arm64"] do
    Application.get_env(
      :fountain,
      :environment_layer_helper_dir,
      Application.app_dir(:fountain, "priv/environment_layers")
    )
    |> Path.join("managoat-layer-linux-" <> architecture)
  end

  # sobelow_skip ["Traversal.FileModule"] — path/1 accepts only two literal architecture
  # names under an operator-configured directory; no tenant-controlled path component.
  def install(handle, architecture) do
    staging = "/tmp/managoat-layer-" <> Ecto.UUID.generate()

    with {:ok, binary} <- File.read(path(architecture)),
         :ok <- Sandbox.write_file(handle, staging, binary, mode: 0o700),
         {:ok, _, 0} <-
           Sandbox.exec(handle, "sudo", ["install", "-d", "-m", "700", @directory],
             timeout: 30_000
           ),
         {:ok, _, 0} <-
           Sandbox.exec(handle, "sudo", ["install", "-m", "700", staging, @binary],
             timeout: 30_000
           ),
         {:ok, _, 0} <- Sandbox.exec(handle, "rm", ["-f", staging], timeout: 30_000) do
      :ok
    else
      {:ok, _, code} when code in 1..255 -> {:error, {:command_exit, code}}
      {:error, {:unavailable, {:exec_timeout, _}}} -> {:error, :timeout}
      {:error, {:unavailable, :timeout}} -> {:error, :timeout}
      _ -> {:error, :helper_unavailable}
    end
  end

  def keygen do
    architecture =
      if String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "aarch64"),
        do: "arm64",
        else: "amd64"

    # The constant request has no secrets; only the captured response has a key.
    case System.cmd(
           "sh",
           [
             "-c",
             ~S(printf '%s' '{"operation":"keygen"}' | exec "$1"),
             "keygen",
             path(architecture)
           ],
           stderr_to_stdout: true
         ) do
      {json, 0} -> decode(json)
      _ -> {:error, :helper_unavailable}
    end
  rescue
    _ -> {:error, :helper_unavailable}
  end

  def call(handle, request) do
    file = "/tmp/managoat-layer-request-" <> Ecto.UUID.generate()

    # The still-running trusted helper removes its control file itself. Running
    # rm/sudo/sh after extraction could execute binaries supplied by the layer.
    request = Map.put(request, :cleanup_file, file)

    with :ok <- Sandbox.write_file(handle, file, Jason.encode!(request), mode: 0o600),
         {:ok, json, code} <-
           Sandbox.exec(
             handle,
             "sh",
             ["-c", ~S(exec sudo /opt/managoat-layer/helper < "$1"), "layer", file],
             timeout: operation_timeout(request.operation)
           ) do
      decode_result(json, code)
    else
      {:error, {:unavailable, {:exec_timeout, _}}} -> {:error, :timeout}
      {:error, {:unavailable, :timeout}} -> {:error, :timeout}
      _ -> {:error, :layer_operation_failed}
    end
  end

  defp decode_result(json, 0), do: decode(json)

  defp decode_result(json, code) when byte_size(json) <= 4096 and code in 1..255 do
    case Jason.decode(json) do
      {:ok, %{"ok" => false, "error" => failure}} when failure in @failure_codes ->
        {:error, {:helper_failed, failure, code}}

      _ ->
        {:error, :layer_operation_failed}
    end
  end

  defp decode_result(_, _), do: {:error, :layer_operation_failed}

  # Leave the helper five seconds to report its own deadline and clean up.
  # The independently leased builder still has a 15-minute total ceiling.
  defp operation_timeout("export"), do: 305_000
  defp operation_timeout(_), do: 125_000

  defp decode(json) when byte_size(json) <= 4096 do
    case Jason.decode(json) do
      {:ok, %{"ok" => true} = result} -> {:ok, result}
      _ -> {:error, :layer_operation_failed}
    end
  end

  defp decode(_), do: {:error, :layer_operation_failed}
end
