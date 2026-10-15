defmodule Managoat.Sandbox.E2BTest do
  # Full-stack against a Req.Test plug: adapter -> Api/Envd -> stubbed HTTP,
  # including the Connect streaming path through the CommandServer. Mutates
  # global app env and uses shared Req.Test ownership (the CommandServer is
  # its own process), so not async.
  use ExUnit.Case, async: false
  use Mimic

  alias Managoat.Sandbox.Command
  alias Managoat.Sandbox.E2B, as: Adapter
  alias Managoat.Sandbox.E2B.Api
  alias Managoat.Sandbox.E2B.Envd
  alias Managoat.Sandbox.NetworkPolicy

  @name "fountain-abc12345-deadbeef"

  setup :set_req_test_to_shared

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  setup do
    previous = Application.get_env(:fountain, Managoat.Sandbox.E2B, [])

    Application.put_env(
      :fountain,
      Managoat.Sandbox.E2B,
      Keyword.merge(previous,
        api_key: "e2b_test_key",
        req_options: [plug: {Req.Test, __MODULE__}],
        # Req's plug adapter runs Plug.Parsers, which chokes on the binary
        # Connect envelope behind any +json content type.
        stream_content_type: "application/octet-stream"
      )
    )

    on_exit(fn -> Application.put_env(:fountain, Managoat.Sandbox.E2B, previous) end)

    # A sandbox's detail is where envd's access token comes from. Most tests
    # here are about something else, so by default the sandbox is one created
    # without `secure` (no token), as hosted E2B's were before 0.5.5; the
    # access-token tests below say otherwise.
    stub(Api, :get_sandbox, fn _id -> {:ok, %{}} end)
    :ok
  end

  defp handle, do: Adapter.build_handle(@name)

  defp listed(state, id \\ "sbx1") do
    %{"sandboxID" => id, "state" => state, "metadata" => %{"fountain_name" => @name}}
  end

  defp end_stream_frame(map \\ %{}) do
    json = Jason.encode!(map)
    <<2, byte_size(json)::32-big, json::binary>>
  end

  defp stream_body(frames) do
    Enum.map_join(frames, "", &Envd.encode_frame/1) <> end_stream_frame()
  end

  describe "create/2" do
    test "creates when the name is unclaimed" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [])
          {"POST", "/sandboxes"} -> Req.Test.json(conn, %{"sandboxID" => "sbx-new"})
        end
      end)

      assert {:ok, %{provider: :e2b, name: @name, private: "sbx-new"}} =
               Adapter.create(@name, [])
    end

    test "adopts an existing sandbox with the same fountain name" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running", "sbx-old")])
        end
      end)

      assert {:ok, %{private: "sbx-old"}} = Adapter.create(@name, [])
    end

    test "accepts the alternate sandboxId spelling returned by create" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [])
          {"POST", "/sandboxes"} -> Req.Test.json(conn, %{"sandboxId" => "sbx-new"})
        end
      end)

      assert {:ok, %{private: "sbx-new"}} = Adapter.create(@name, [])
    end

    test "lookup and create failures are normalized" do
      {:ok, mode} = Agent.start_link(fn -> :lookup end)

      Req.Test.stub(__MODULE__, fn conn ->
        case {Agent.get(mode, & &1), conn.method} do
          {:lookup, "GET"} ->
            conn |> Plug.Conn.put_status(418) |> Req.Test.json(%{"error" => "lookup"})

          {:create, "GET"} ->
            Req.Test.json(conn, [])

          {:create, "POST"} ->
            conn |> Plug.Conn.put_status(418) |> Req.Test.json(%{"error" => "create"})
        end
      end)

      assert {:error, {:invalid, {:http, 418, %{"error" => "lookup"}}}} =
               Adapter.create(@name, [])

      Agent.update(mode, fn _ -> :create end)

      assert {:error, {:invalid, {:http, 418, %{"error" => "create"}}}} =
               Adapter.create(@name, [])
    end
  end

  describe "get/1, suspend/1, resume/1, destroy/1" do
    test "an unclaimed name is definitively not found" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, []) end)
      assert {:error, :not_found} = Adapter.get(handle())
      assert {:error, :not_found} = Adapter.suspend(handle())
    end

    test "lookup failures remain tagged across lifecycle and listing operations" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(418) |> Req.Test.json(%{"error" => "teapot"})
      end)

      error = {:error, {:invalid, {:http, 418, %{"error" => "teapot"}}}}
      assert Adapter.get(handle()) == error
      assert Adapter.destroy(handle()) == error
      assert Adapter.suspend(handle()) == error
      assert Adapter.list_all_names() == error
    end

    test "paused normalizes to :suspended" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, [listed("paused")]) end)
      assert {:ok, %{status: :suspended}} = Adapter.get(handle())
    end

    test "running and unfamiliar provider states normalize without leaking strings" do
      {:ok, state} = Agent.start_link(fn -> "running" end)

      Req.Test.stub(
        __MODULE__,
        &Req.Test.json(&1, [listed(Agent.get(state, fn value -> value end))])
      )

      assert {:ok, %{status: :running}} = Adapter.get(handle())
      Agent.update(state, fn _ -> "starting" end)
      assert {:ok, %{status: :unknown}} = Adapter.get(handle())
    end

    test "suspend pauses a running sandbox and no-ops on a paused one" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"POST", "/sandboxes/sbx1/pause"} ->
            send(test, :paused)
            Req.Test.json(conn, %{})
        end
      end)

      assert :ok = Adapter.suspend(handle())
      assert_received :paused

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, [listed("paused")]) end)
      assert :ok = Adapter.suspend(handle())
    end

    test "resume connects a paused sandbox" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("paused")])

          {"POST", "/sandboxes/sbx1/connect"} ->
            send(test, :connected)
            Req.Test.json(conn, %{})
        end
      end)

      assert {:ok, %{private: "sbx1"}} = Adapter.resume(handle())
      assert_received :connected
    end

    test "resume preserves a failed reconnect as a tagged error" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("paused")])

          {"POST", "/sandboxes/sbx1/connect"} ->
            conn |> Plug.Conn.put_status(418) |> Req.Test.json(%{"error" => "transitioning"})
        end
      end)

      assert {:error, {:invalid, {:http, 418, %{"error" => "transitioning"}}}} =
               Adapter.resume(handle())
    end

    test "destroying an unclaimed name is :ok without a delete call" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.method do
          "GET" -> Req.Test.json(conn, [])
        end
      end)

      assert :ok = Adapter.destroy(handle())
    end

    test "destroy deletes the resolved sandbox" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"DELETE", "/sandboxes/sbx1"} ->
            send(test, :deleted)
            Req.Test.json(conn, %{})
        end
      end)

      assert :ok = Adapter.destroy(handle())
      assert_received :deleted
    end
  end

  describe "identity and files" do
    test "provider identity and public URL capability are explicit" do
      assert Adapter.provider() == :e2b
      assert {:error, :unsupported} = Adapter.public_url(handle())
    end

    test "write_file resolves the sandbox and uploads multipart data" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"POST", "/files"} ->
            send(test, {:upload, conn.query_string})
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert :ok = Adapter.write_file(handle(), "/work/file.txt", ["con", "tents"], mode: 0o600)
      assert_received {:upload, query}
      assert query =~ "path=%2Fwork%2Ffile.txt"
    end

    test "file operations preserve resolution and upload failures" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.method do
          "GET" -> Req.Test.json(conn, [])
        end
      end)

      assert {:error, :not_found} = Adapter.write_file(handle(), "/file", "x", [])

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.method do
          "GET" -> Req.Test.json(conn, [listed("running")])
          "POST" -> conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
        end
      end)

      assert {:error, {:unavailable, {:http, 503, %{"error" => "down"}}}} =
               Adapter.write_file(handle(), "/file", "x", [])

      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(418) |> Req.Test.json(%{"error" => "lookup failed"})
      end)

      assert {:error, {:invalid, {:http, 418, %{"error" => "lookup failed"}}}} =
               Adapter.write_file(handle(), "/file", "x", [])
    end
  end

  describe "list_all_names/0" do
    test "follows x-next-token pagination and returns the full set" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["nextToken"] do
          nil ->
            conn
            |> Plug.Conn.put_resp_header("x-next-token", "page2")
            |> Req.Test.json([listed("running", "a")])

          "page2" ->
            Req.Test.json(conn, [
              %{
                "sandboxID" => "b",
                "state" => "paused",
                "metadata" => %{"fountain_name" => "fountain-second"}
              }
            ])
        end
      end)

      assert {:ok, names} = Adapter.list_all_names()
      assert names == MapSet.new([@name, "fountain-second"])
    end
  end

  describe "exec/4 — the Connect streaming path end to end" do
    test "collects stdout and the exit code through the CommandServer" do
      body =
        stream_body([
          %{"event" => %{"start" => %{"pid" => 42}}},
          %{"event" => %{"data" => %{"stdout" => Base.encode64("he")}}},
          %{"event" => %{"data" => %{"stdout" => Base.encode64("llo")}}},
          %{"event" => %{"data" => %{"stderr" => Base.encode64("dropped")}}},
          %{"event" => %{"end" => %{"exitCode" => 3}}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"POST", "/process.Process/Start"} ->
            Plug.Conn.resp(conn, 200, body)
        end
      end)

      assert {:ok, "hello", 3} = Adapter.exec(handle(), "bash", ["-lc", "x"], [])

      assert {:ok, "hellodropped", 3} =
               Adapter.exec(handle(), "bash", ["-lc", "x"], stderr_to_stdout: true)
    end

    test "a stream error is returned instead of partial output" do
      body =
        stream_body([
          %{"event" => %{"start" => %{"pid" => 42}}},
          %{"event" => %{"data" => %{"stdout" => Base.encode64("partial")}}}
        ])

      json = Jason.encode!(%{"error" => "stream unavailable"})
      body = binary_part(body, 0, byte_size(body) - byte_size(end_stream_frame()))
      body = body <> <<2, byte_size(json)::32-big, json::binary>>

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running")])
          {"POST", "/process.Process/Start"} -> Plug.Conn.resp(conn, 200, body)
        end
      end)

      assert {:error, {:provider, :e2b, "stream unavailable"}} =
               Adapter.exec(handle(), "bash", ["-lc", "x"], [])
    end

    test "a silent command stream is killed at the caller's timeout" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"POST", "/process.Process/Start"} ->
            Process.sleep(250)
            Plug.Conn.resp(conn, 200, "")
        end
      end)

      assert {:error, {:unavailable, {:exec_timeout, 20}}} =
               Adapter.exec(handle(), "sleep", ["10"], timeout: 20)
    end

    test "a paused sandbox is resumed before the exec reaches envd" do
      test = self()
      body = stream_body([%{"event" => %{"end" => %{"exitCode" => 0}}}])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("paused")])

          {"POST", "/sandboxes/sbx1/connect"} ->
            send(test, :connected)
            Req.Test.json(conn, %{})

          {"POST", "/process.Process/Start"} ->
            Plug.Conn.resp(conn, 200, body)
        end
      end)

      assert {:ok, "", 0} = Adapter.exec(handle(), "true", [], [])
      assert_received :connected
    end
  end

  describe "spawn/4 and stdin" do
    test "spawn delivers frames to the owner and write_stdin is total after exit" do
      body =
        stream_body([
          %{"event" => %{"start" => %{"pid" => 42}}},
          %{"event" => %{"data" => %{"stdout" => Base.encode64("ready")}}},
          %{"event" => %{"end" => %{"exitCode" => 0}}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running")])
          {"POST", "/process.Process/Start"} -> Plug.Conn.resp(conn, 200, body)
        end
      end)

      assert {:ok, %Command{provider: :e2b, ref: ref} = command} =
               Adapter.spawn(handle(), "claude-agent-acp", [], owner: self(), stdin: true)

      assert_receive {:stdout, %{ref: ^ref}, "ready"}, 1_000
      assert_receive {:exit, %{ref: ^ref}, 0}, 1_000

      # The CommandServer stopped with the stream; a late write must come
      # back as an error rather than exiting the caller (#603 semantics).
      wait_for_down(command.private.pid)
      assert {:error, :command_exited} = Adapter.write_stdin(command, "late\n")
    end

    test "a stream that ends with no exit event is an error, not exit 0" do
      # envd finished the stream without an `end` event: the process may
      # still be running sandbox-side, and calling that a clean exit is the
      # #880 failure mode — a failed command reported as a successful one.
      body =
        stream_body([
          %{"event" => %{"start" => %{"pid" => 42}}},
          %{"event" => %{"data" => %{"stdout" => Base.encode64("partial")}}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running")])
          {"POST", "/process.Process/Start"} -> Plug.Conn.resp(conn, 200, body)
        end
      end)

      assert {:ok, %Command{ref: ref}} =
               Adapter.spawn(handle(), "claude-agent-acp", [], owner: self(), stdin: true)

      assert_receive {:stdout, %{ref: ^ref}, "partial"}, 1_000
      assert_receive {:error, %{ref: ^ref}, :closed_before_exit}, 1_000
      refute_receive {:exit, %{ref: ^ref}, _}, 50
    end

    test "attach: the shim's exit file outlives the stream and still answers" do
      # The one case where a close with no exit event is not an unknown: the
      # replayer ended because the shim had written the real code, and that
      # file is readable after the stream is gone.
      body =
        stream_body([
          %{"event" => %{"start" => %{"pid" => 42}}},
          %{"event" => %{"data" => %{"stdout" => Base.encode64("replayed")}}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running")])
          {"POST", "/process.Process/Start"} -> Plug.Conn.resp(conn, 200, body)
          {"GET", "/files"} -> Plug.Conn.resp(conn, 200, "17\n")
        end
      end)

      assert {:ok, %Command{ref: ref}} = Adapter.attach(handle(), "tag-1", owner: self())

      assert_receive {:stdout, %{ref: ^ref}, "replayed"}, 1_000
      assert_receive {:exit, %{ref: ^ref}, 17}, 1_000
      refute_receive {:error, %{ref: ^ref}, _}, 50
    end

    test "attach: an unreadable exit file leaves the fate unknown" do
      body = stream_body([%{"event" => %{"start" => %{"pid" => 42}}}])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running")])
          {"POST", "/process.Process/Start"} -> Plug.Conn.resp(conn, 200, body)
          {"GET", "/files"} -> Plug.Conn.resp(conn, 404, "")
        end
      end)

      assert {:ok, %Command{ref: ref}} = Adapter.attach(handle(), "tag-1", owner: self())

      assert_receive {:error, %{ref: ^ref}, :closed_before_exit}, 1_000
      refute_receive {:exit, %{ref: ^ref}, _}, 50
    end

    test "spawn does not return :ok before envd acks the process" do
      # A stream that dies without ever sending the start event: the process
      # never existed, so spawn must surface an error — returning :ok here is
      # the race that let the ACP peer's first write 404 against envd and
      # fail prod turns in ~300ms.
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running")])
          {"POST", "/process.Process/Start"} -> Plug.Conn.resp(conn, 200, end_stream_frame())
        end
      end)

      assert {:error, _reason} =
               Adapter.spawn(handle(), "claude-agent-acp", [], owner: self(), stdin: true)
    end

    test "detachable spawn wraps shell-safe argv in the journaling shim" do
      test = self()

      body =
        stream_body([
          %{"event" => %{"start" => %{"pid" => 42}}},
          %{"event" => %{"end" => %{"exitCode" => 0}}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"POST", "/process.Process/Start"} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test, {:start_request, raw})
            Plug.Conn.resp(conn, 200, body)
        end
      end)

      assert {:ok, %Command{}} =
               Adapter.spawn(handle(), "bash", ["a'b"], owner: self(), detachable: true)

      assert_received {:start_request, raw}
      assert {[{:message, request}], <<>>} = Envd.decode_frames(raw)
      assert request["process"]["cmd"] == "bash"
      ["-lc", script] = request["process"]["args"]
      assert script =~ "tee -a /tmp/fountain/"
      assert script =~ "'a'\\''b'"
    end

    test "close and stop are total after a command process exits" do
      dead = spawn(fn -> :ok end)
      monitor = Process.monitor(dead)
      assert_receive {:DOWN, ^monitor, :process, ^dead, _reason}

      command = %Command{provider: :e2b, ref: make_ref(), private: %{pid: dead}}
      assert :ok = Adapter.close_stdin(command)
      assert :ok = Adapter.stop_command(command)

      {:ok, live} = Agent.start_link(fn -> :ok end)
      live_command = %Command{provider: :e2b, ref: make_ref(), private: %{pid: live}}
      assert :ok = Adapter.stop_command(live_command)
      refute Process.alive?(live)
    end
  end

  describe "sessions and attach" do
    test "list_sessions filters provider processes and normalizes command lines" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"POST", "/process.Process/List"} ->
            Req.Test.json(conn, %{
              "processes" => [
                %{"tag" => "other", "config" => %{"cmd" => "ignored", "args" => []}},
                %{
                  "tag" => "fountain-42",
                  "config" => %{"cmd" => "bash", "args" => ["-lc", "true"]}
                },
                %{"tag" => "fountain-43"}
              ]
            })
        end
      end)

      assert {:ok, sessions} = Adapter.list_sessions(handle())

      assert Enum.map(sessions, &{&1.id, &1.command}) == [
               {"fountain-42", "bash -lc true"},
               {"fountain-43", nil}
             ]
    end

    test "attach replays through a tagged command and reads the original exit sentinel" do
      body =
        stream_body([
          %{"event" => %{"start" => %{"pid" => 42}}},
          %{"event" => %{"data" => %{"stdout" => Base.encode64("replayed")}}},
          %{"event" => %{"end" => %{"exitCode" => 0}}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running")])
          {"POST", "/process.Process/Start"} -> Plug.Conn.resp(conn, 200, body)
          {"GET", "/files"} -> Plug.Conn.send_resp(conn, 200, "7\n")
        end
      end)

      assert {:ok, %Command{private: %{tag: "fountain-42"}} = command} =
               Adapter.attach(handle(), "fountain-42", owner: self())

      assert_receive {:stdout, %{ref: ref}, "replayed"} when ref == command.ref
      assert_receive {:exit, %{ref: ref}, 7} when ref == command.ref
    end

    test "session-list API failures are normalized" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/v2/sandboxes" ->
            Req.Test.json(conn, [listed("running")])

          "/process.Process/List" ->
            conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
        end
      end)

      assert {:error, {:unavailable, {:http, 503, %{"error" => "down"}}}} =
               Adapter.list_sessions(handle())
    end
  end

  describe "envd access token" do
    test "a secure sandbox's envd calls carry its token, and only to its envd" do
      test_pid = self()
      stub(Api, :get_sandbox, fn "sbx1" -> {:ok, %{"envdAccessToken" => "envd-secret"}} end)

      body = stream_body([%{"event" => %{"end" => %{"exitCode" => 0}}}])

      Req.Test.stub(__MODULE__, fn conn ->
        send(
          test_pid,
          {:token, conn.method, conn.request_path,
           Plug.Conn.get_req_header(conn, "x-access-token")}
        )

        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running")])
          {"POST", "/files"} -> Plug.Conn.send_resp(conn, 200, "[]")
          {"POST", "/process.Process/Start"} -> Plug.Conn.resp(conn, 200, body)
          {"PUT", "/sandboxes/sbx1/network"} -> Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert :ok = Adapter.write_file(handle(), "/tmp/x", "data", [])
      assert {:ok, "", 0} = Adapter.exec(handle(), "true", [], [])
      assert :ok = Adapter.apply_network_policy(handle(), %NetworkPolicy{allow: ["hex.pm"]})

      assert_received {:token, "POST", "/files", ["envd-secret"]}
      assert_received {:token, "POST", "/process.Process/Start", ["envd-secret"]}
      # The control plane is authenticated by the API key, never the envd token.
      assert_received {:token, "GET", "/v2/sandboxes", []}
      assert_received {:token, "PUT", "/sandboxes/sbx1/network", []}
    end

    test "a sandbox whose detail can't be read is reached by its bare id" do
      test_pid = self()
      stub(Api, :get_sandbox, fn _id -> {:error, {:api_error, 500, %{}}} end)

      Req.Test.stub(__MODULE__, fn conn ->
        send(
          test_pid,
          {:token, conn.request_path, Plug.Conn.get_req_header(conn, "x-access-token")}
        )

        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running")])
          {"POST", "/files"} -> Plug.Conn.send_resp(conn, 200, "[]")
        end
      end)

      assert :ok = Adapter.write_file(handle(), "/tmp/x", "data", [])
      assert_received {:token, "/files", []}
    end
  end

  describe "network policy" do
    test "allow: [] sends the explicit deny-all body — never a no-op" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"PUT", "/sandboxes/sbx1/network"} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test, {:network, Jason.decode!(raw)})
            Req.Test.json(conn, %{})
        end
      end)

      assert :ok = Adapter.apply_network_policy(handle(), %NetworkPolicy{allow: []})
      assert_received {:network, %{"denyOut" => ["0.0.0.0/0"], "allowOut" => []}}
    end
  end

  describe "capabilities" do
    test "suspend, network policy and attach are real" do
      caps = Adapter.capabilities()
      assert MapSet.member?(caps, :suspend)
      assert MapSet.member?(caps, :network_policy)
      assert MapSet.member?(caps, :attach)
    end
  end

  defp wait_for_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1_000 -> flunk("command server did not stop")
    end
  end
end
