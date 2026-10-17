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
  @claude_url "https://github.com/managoat/managoat/releases/download/acp-bundle-claude-0.81.2/" <>
                "claude-agent-acp@0.81.2.linux-x64-glibc-image.tar.gz"
  @claude_push "/tmp/managoat-claude-agent-acp@0.81.2.tar.gz"

  setup do
    on_exit(fn -> :persistent_term.erase({BundleCache, @claude_url}) end)
  end

  describe "ACP.preload/2" do
    test "pushes the host's copy and installs it offline" do
      :persistent_term.put({BundleCache, @claude_url}, "bundle bytes")
      test = self()

      expect(Sandbox, :write_file, fn @handle, @claude_push, "bundle bytes" -> :ok end)

      expect(Sandbox, :exec, fn @handle, "bash", ["-lc", script], opts ->
        send(test, {:exec, script, opts})
        {:ok, "__MANAGOAT_INSTALL__ bundle_hit 1\n", 0}
      end)

      assert ACP.preload(@handle, "claude") == :ok
      assert_receive {:exec, script, opts}

      assert opts[:env] == [
               {"MANAGOAT_ACP_BUNDLE_FILE", @claude_push},
               {"MANAGOAT_ACP_OFFLINE", "1"}
             ]

      assert script =~ "dir=/home/sprite/.local/share/managoat/acp/claude-agent-acp@0.81.2"
      assert script =~ ~s(elif [ -n "${MANAGOAT_ACP_OFFLINE:-}" ]; then)
    end

    test "an install that answers 75 did not preload, and the floor installs instead" do
      :persistent_term.put({BundleCache, @claude_url}, "bundle bytes")
      stub(Sandbox, :write_file, fn _h, _p, _b -> :ok end)
      stub(Sandbox, :exec, fn _h, "bash", _args, _opts -> {:ok, "", 75} end)

      assert ACP.preload(@handle, "claude") == {:error, :acp_adapter_not_preloaded}
    end

    test "a bundle the host could not get is never pushed" do
      Req.Test.stub(BundleCache, &Plug.Conn.send_resp(&1, 503, ""))
      reject(&Sandbox.write_file/3)
      reject(&Sandbox.exec/4)

      assert {:error, {:acp_adapter_preload, {:bundle_http, 503}}} =
               ACP.preload(@handle, "claude")
    end

    test "nothing is pushed where no bundle applies" do
      reject(&Sandbox.write_file/3)
      reject(&Sandbox.exec/4)

      assert ACP.preload(%{@handle | provider: :e2b}, "claude") == :skip
      assert ACP.preload(@handle, "gemini") == :skip
    end
  end

  describe "BundleCache.fetch/2" do
    test "keeps a copy that verifies, and serves it without fetching again" do
      url = "https://bundles.test/verified-#{System.unique_integer([:positive])}"
      on_exit(fn -> :persistent_term.erase({BundleCache, url}) end)
      test = self()

      Req.Test.stub(BundleCache, fn conn ->
        send(test, :fetched)
        Plug.Conn.send_resp(conn, 200, "the bundle")
      end)

      sri = "sha512-" <> Base.encode64(:crypto.hash(:sha512, "the bundle"))
      assert BundleCache.fetch(url, sri) == {:ok, "the bundle"}
      assert BundleCache.fetch(url, sri) == {:ok, "the bundle"}
      assert_received :fetched
      refute_received :fetched
    end

    test "keeps nothing that does not verify" do
      url = "https://bundles.test/tampered-#{System.unique_integer([:positive])}"
      Req.Test.stub(BundleCache, &Plug.Conn.send_resp(&1, 200, "something else"))

      assert BundleCache.fetch(url, "sha512-" <> Base.encode64(:crypto.hash(:sha512, "x"))) ==
               {:error, :bundle_integrity}

      assert :persistent_term.get({BundleCache, url}, nil) == nil
    end
  end
end
