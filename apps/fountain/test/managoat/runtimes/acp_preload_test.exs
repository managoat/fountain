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

  setup do
    on_exit(fn -> :persistent_term.erase({BundleCache, @claude_url}) end)
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
      :persistent_term.put({BundleCache, @claude_url}, bytes)
      stub_installer(0, "__MANAGOAT_INSTALL__ bundle_hit 1\n")
      reject(&Sandbox.spawn/4)

      assert ACP.preload(@handle, "claude") == :ok
      assert_receive {:installed, script, opts}

      assert opts[:env] == [
               {"MANAGOAT_ACP_BUNDLE_FILE", "/tmp/managoat-claude-agent-acp@0.81.2.tar.gz"},
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
      :persistent_term.put({BundleCache, @claude_url}, "bundle bytes")
      stub_installer(75)

      assert ACP.preload(@handle, "claude") == {:error, :acp_adapter_not_preloaded}
    end

    test "a failed upload does not start the installer" do
      :persistent_term.put({BundleCache, @claude_url}, "bytes")
      expect(Sandbox, :write_file, fn _, _, _ -> {:error, :unavailable} end)
      reject(&Sandbox.exec/4)
      assert ACP.preload(@handle, "claude") == {:error, {:acp_adapter_preload, :unavailable}}
    end

    test "a bundle the host could not get is never sent" do
      Req.Test.stub(BundleCache, &Plug.Conn.send_resp(&1, 503, ""))
      reject(&Sandbox.spawn/4)

      assert {:error, {:acp_adapter_preload, {:acp_adapter_bundle, {:bundle_http, 503}}}} =
               ACP.preload(@handle, "claude")
    end

    test "nothing is sent for a native runtime" do
      reject(&Sandbox.spawn/4)

      assert ACP.preload(@handle, "gemini") == :skip
    end

    test "E2B preloads too: every provider runs the image CLI" do
      :persistent_term.put({BundleCache, @claude_url}, "bundle bytes")
      e2b = %{@handle | provider: :e2b}
      stub_installer(0, "", e2b)

      assert ACP.preload(e2b, "claude") == :ok
      assert_receive {:uploaded, _, "bundle bytes"}
    end
  end

  describe "BundleCache.fetch/3" do
    test "keeps a copy that verifies, and serves it without fetching again" do
      url = "https://bundles.test/verified-#{System.unique_integer([:positive])}"
      on_exit(fn -> :persistent_term.erase({BundleCache, url}) end)
      test = self()

      Req.Test.stub(BundleCache, fn conn ->
        send(test, :fetched)
        Plug.Conn.send_resp(conn, 200, "the bundle")
      end)

      sri = "sha512-" <> Base.encode64(:crypto.hash(:sha512, "the bundle"))
      assert BundleCache.fetch(url, sri, 10) == {:ok, "the bundle"}
      assert BundleCache.fetch(url, sri, 10) == {:ok, "the bundle"}
      assert_received :fetched
      refute_received :fetched
    end

    test "keeps nothing that does not verify" do
      url = "https://bundles.test/tampered-#{System.unique_integer([:positive])}"
      Req.Test.stub(BundleCache, &Plug.Conn.send_resp(&1, 200, "something else"))

      assert BundleCache.fetch(url, "sha512-" <> Base.encode64(:crypto.hash(:sha512, "x")), 100) ==
               {:error, :bundle_integrity}

      assert :persistent_term.get({BundleCache, url}, nil) == nil
    end

    test "abandons a body longer than the pinned size, and keeps nothing" do
      url = "https://bundles.test/oversize-#{System.unique_integer([:positive])}"
      Req.Test.stub(BundleCache, &Plug.Conn.send_resp(&1, 200, "eleven byte"))
      sri = "sha512-" <> Base.encode64(:crypto.hash(:sha512, "eleven byte"))

      assert BundleCache.fetch(url, sri, 10) == {:error, :bundle_size}
      assert :persistent_term.get({BundleCache, url}, nil) == nil
    end

    test "follows the release redirect without collecting its body" do
      url = "https://bundles.test/redirect-#{System.unique_integer([:positive])}"
      on_exit(fn -> :persistent_term.erase({BundleCache, url}) end)

      Req.Test.stub(BundleCache, fn
        %{host: "assets.test"} = conn ->
          Plug.Conn.send_resp(conn, 200, "the bundle")

        conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://assets.test/blob")
          |> Plug.Conn.send_resp(302, "a redirect page longer than the bundle")
      end)

      sri = "sha512-" <> Base.encode64(:crypto.hash(:sha512, "the bundle"))
      assert BundleCache.fetch(url, sri, 10) == {:ok, "the bundle"}
    end
  end
end
