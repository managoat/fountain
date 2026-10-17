defmodule Managoat.Runtimes.BundleCache do
  @moduledoc """
  The host's copy of a pinned adapter bundle, read once from the release and
  kept for the node's life, for `Managoat.Runtimes.ACP` to upload into a
  sandbox.

  The release carries every pinned bundle in `priv/runtimes/acp/bundles/`:
  `mix acp.bundles` fetches and verifies them when the release is built, so a
  provision never waits on GitHub (#2970). The SHA-512 is compiled in from the
  bundle record and checked again here before the bytes are kept, and the
  sandbox checks them once more before it extracts them. A file that is
  missing or does not verify keeps nothing and fails the install.

  `:acp_bundle_dir` overrides the directory: dev reads the cache that
  `mix acp.bundles` fills, and the suite a directory of its own.
  """

  @spec fetch(String.t(), String.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def fetch(file, integrity, size) do
    key = {__MODULE__, file}

    case :persistent_term.get(key, nil) do
      nil -> load(key, file, integrity, size)
      bytes -> {:ok, bytes}
    end
  end

  @doc "Where the bundles are read from."
  def dir do
    Application.get_env(:fountain, :acp_bundle_dir) ||
      Application.app_dir(:fountain, "priv/runtimes/acp/bundles")
  end

  # sobelow_skip ["Traversal.FileModule"] — `file` is a pinned bundle's name,
  # compiled into Managoat.Runtimes.ACP from its reviewed record.
  defp load(key, file, integrity, size) do
    case File.read(Path.join(dir(), file)) do
      {:ok, bytes} when byte_size(bytes) != size ->
        {:error, :bundle_size}

      {:ok, bytes} ->
        if "sha512-" <> Base.encode64(:crypto.hash(:sha512, bytes)) == integrity do
          :persistent_term.put(key, bytes)
          {:ok, bytes}
        else
          {:error, :bundle_integrity}
        end

      {:error, :enoent} ->
        {:error, :bundle_missing}

      {:error, reason} ->
        {:error, {:bundle_read, reason}}
    end
  end
end
