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
    # A command that answers with `code` once its stdin is closed, as the
    # offline installer does, after sending `out`.
    defp stub_installer(code, out \\ "") do
      test = self()
      ref = make_ref()

      stub(Sandbox, :spawn, fn @handle, "bash", ["-lc", script], opts ->
        send(test, {:spawned, script, opts})
        {:ok, %Sandbox.Command{provider: :sprites, ref: ref, private: opts[:owner]}}
      end)

      stub(Sandbox, :write_stdin, fn %{ref: ^ref}, data ->
        send(test, {:stdin, IO.iodata_to_binary(data)})
        :ok
      end)

      stub(Sandbox, :close_stdin, fn %{ref: ^ref, private: owner} ->
        send(owner, {:stdout, %{ref: ref}, out})
        send(owner, {:exit, %{ref: ref}, code})
        :ok
      end)
    end

    test "streams the host's copy into the offline installer" do
      bytes = :crypto.strong_rand_bytes(600_000)
      :persistent_term.put({BundleCache, @claude_url}, bytes)
      stub_installer(0, "__MANAGOAT_INSTALL__ bundle_hit 1\n")
      reject(&Sandbox.write_file/3)

      assert ACP.preload(@handle, "claude") == :ok
      assert_receive {:spawned, script, opts}

      assert opts[:env] == [{"MANAGOAT_ACP_BUNDLE_STDIN", "1"}, {"MANAGOAT_ACP_OFFLINE", "1"}]
      assert opts[:stdin]
      assert script =~ "dir=/home/sprite/.local/share/managoat/acp/claude-agent-acp@0.81.2"
      assert script =~ ~s(elif [ -n "${MANAGOAT_ACP_OFFLINE:-}" ]; then)

      # In chunks, in order, and all of it.
      assert streamed() == bytes
    end

    test "an install that answers 75 did not preload, and the floor installs instead" do
      :persistent_term.put({BundleCache, @claude_url}, "bundle bytes")
      stub_installer(75)

      assert ACP.preload(@handle, "claude") == {:error, :acp_adapter_not_preloaded}
    end

    test "a command that stops reading still answers with its exit" do
      :persistent_term.put({BundleCache, @claude_url}, :crypto.strong_rand_bytes(600_000))
      stub_installer(75)
      test = self()

      stub(Sandbox, :write_stdin, fn %{ref: ref, private: owner}, _data ->
        send(test, :refused)
        send(owner, {:exit, %{ref: ref}, 75})
        {:error, :command_exited}
      end)

      assert ACP.preload(@handle, "claude") == {:error, :acp_adapter_not_preloaded}
      assert_received :refused
      refute_received :refused
    end

    test "a bundle the host could not get is never sent" do
      Req.Test.stub(BundleCache, &Plug.Conn.send_resp(&1, 503, ""))
      reject(&Sandbox.spawn/4)

      assert {:error, {:acp_adapter_preload, {:bundle_http, 503}}} =
               ACP.preload(@handle, "claude")
    end

    test "nothing is sent where no bundle applies" do
      reject(&Sandbox.spawn/4)

      assert ACP.preload(%{@handle | provider: :e2b}, "claude") == :skip
      assert ACP.preload(@handle, "gemini") == :skip
    end
  end

  defp streamed(acc \\ "") do
    receive do
      {:stdin, data} -> streamed(acc <> data)
    after
      0 -> acc
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
