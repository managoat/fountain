defmodule Managoat.Runtimes.ACPPreloadTest do
  @moduledoc """
  `ACP.preload/2` and the host's bundle copy behind it. Not async: the copy
  lives in `:persistent_term`, which every test on the node can see.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Managoat.Runtimes.{ACP, BundleCache}
  alias Managoat.Sandbox

  setup :verify_on_exit!

  @handle %Sandbox.Handle{provider: :sprites, name: "preload-test"}
  @claude_file "claude-agent-acp@0.81.2.linux-x64-glibc-image.tar.gz"

  setup do
    on_exit(fn -> :persistent_term.erase({BundleCache, @claude_file}) end)
  end

  describe "ACP.preload/2" do
    defp stub_installer(code, out \\ "", handle \\ @handle) do
      test = self()

      stub(Sandbox, :write_file, fn ^handle, path, bytes ->
        send(test, {:uploaded, path, bytes})
        :ok
      end)

      stub(Sandbox, :exec, fn ^handle, "bash", ["-lc", script], opts ->
        send(test, {:installed, script, opts})
        {:ok, out, code}
      end)
    end

    test "uploads the host's copy for the offline installer" do
      bytes = :crypto.strong_rand_bytes(600_000)
      :persistent_term.put({BundleCache, @claude_file}, bytes)
      stub_installer(0, "__MANAGOAT_INSTALL__ bundle_hit 1\n")
      reject(&Sandbox.spawn/4)

      assert ACP.preload(@handle, "claude") == :ok
      assert_receive {:installed, script, opts}

      assert opts[:env] == [
               {"MANAGOAT_ACP_BUNDLE_FILE", "/tmp/managoat-claude-agent-acp@0.81.2.tar.gz"},
               {"MANAGOAT_ACP_DEADLINE_S", "55"},
               {"MANAGOAT_ACP_OFFLINE", "1"}
             ]

      assert opts[:timeout] == 60_000
      assert script =~ "dir=/home/sprite/.local/share/managoat/acp/claude-agent-acp@0.81.2"
      assert script =~ ~s([ -z "${MANAGOAT_ACP_OFFLINE:-}" ] || return 75)

      for removed <- ["curl", "npm", "manifest"] do
        refute script =~ removed
      end

      assert_receive {:uploaded, "/tmp/managoat-claude-agent-acp@0.81.2.tar.gz", ^bytes}
    end

    test "an install that answers 75 did not preload, and the floor installs instead" do
      :persistent_term.put({BundleCache, @claude_file}, "bundle bytes")
      stub_installer(75)

      assert ACP.preload(@handle, "claude") == {:error, :acp_adapter_not_preloaded}
    end

    test "a failed upload does not start the installer" do
      :persistent_term.put({BundleCache, @claude_file}, "bytes")
      expect(Sandbox, :write_file, fn _, _, _ -> {:error, :unavailable} end)
      reject(&Sandbox.exec/4)
      assert ACP.preload(@handle, "claude") == {:error, {:acp_adapter_preload, :unavailable}}
    end

    test "a bundle the release does not carry is never sent" do
      File.rm(Path.join(BundleCache.dir(), @claude_file))
      reject(&Sandbox.write_file/3)
      reject(&Sandbox.exec/4)

      assert ACP.preload(@handle, "claude") ==
               {:error, {:acp_adapter_preload, {:acp_adapter_bundle, :bundle_missing}}}
    end

    test "nothing is sent for a native runtime" do
      reject(&Sandbox.spawn/4)

      assert ACP.preload(@handle, "gemini") == :skip
    end

    test "E2B preloads too: every provider runs the image CLI" do
      :persistent_term.put({BundleCache, @claude_file}, "bundle bytes")
      e2b = %{@handle | provider: :e2b}
      stub_installer(0, "", e2b)

      assert ACP.preload(e2b, "claude") == :ok
      assert_receive {:uploaded, _, "bundle bytes"}
    end
  end

  describe "BundleCache.fetch/3" do
    defp write_bundle(bytes) do
      file = "bundle-#{System.unique_integer([:positive])}.tar.gz"
      path = Path.join(BundleCache.dir(), file)
      File.mkdir_p!(BundleCache.dir())
      File.write!(path, bytes)

      on_exit(fn ->
        File.rm(path)
        :persistent_term.erase({BundleCache, file})
      end)

      {file, path}
    end

    defp sri(bytes), do: "sha512-" <> Base.encode64(:crypto.hash(:sha512, bytes))

    test "keeps a copy that verifies, and serves it without reading again" do
      {file, path} = write_bundle("the bundle")

      assert BundleCache.fetch(file, sri("the bundle"), 10) == {:ok, "the bundle"}
      File.rm!(path)
      assert BundleCache.fetch(file, sri("the bundle"), 10) == {:ok, "the bundle"}
    end

    test "keeps nothing that does not verify" do
      {file, _} = write_bundle("something else")

      assert BundleCache.fetch(file, sri("x"), 14) == {:error, :bundle_integrity}
      assert :persistent_term.get({BundleCache, file}, nil) == nil
    end

    test "refuses a file of the wrong size before hashing it, and keeps nothing" do
      {file, _} = write_bundle("eleven byte")

      assert BundleCache.fetch(file, sri("eleven byte"), 10) == {:error, :bundle_size}
      assert :persistent_term.get({BundleCache, file}, nil) == nil
    end

    test "a missing file is an error, not a download" do
      assert BundleCache.fetch("absent.tar.gz", sri("x"), 1) == {:error, :bundle_missing}
    end
  end
end
