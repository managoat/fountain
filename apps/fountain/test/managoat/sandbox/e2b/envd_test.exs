defmodule Managoat.Sandbox.E2B.EnvdTest do
  use ExUnit.Case, async: false

  alias Managoat.Sandbox.E2B.Envd

  setup do
    previous = Application.get_env(:fountain, Managoat.Sandbox.E2B, [])

    Application.put_env(
      :fountain,
      Managoat.Sandbox.E2B,
      api_key: "e2b_test_key",
      base_url: "https://api.test",
      user: "sprite",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )

    on_exit(fn ->
      Application.put_env(:fountain, Managoat.Sandbox.E2B, previous)
    end)

    :ok
  end

  describe "envd HTTP API" do
    test "unary calls, files, and process listing use the documented wire shapes" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw_body})

        case {conn.method, conn.request_path} do
          {"POST", "/process.Process/SendInput"} ->
            Req.Test.json(conn, %{})

          {"POST", "/process.Process/CloseStdin"} ->
            Req.Test.json(conn, %{})

          {"POST", "/process.Process/List"} ->
            Req.Test.json(conn, %{"processes" => [%{"tag" => "turn-1"}]})

          {"POST", "/files"} ->
            Plug.Conn.send_resp(conn, 204, "")

          {"GET", "/files"} ->
            Plug.Conn.send_resp(conn, 200, "contents")
        end
      end)

      assert %Req.Request{} = Envd.req("sbx-1")
      assert {:ok, %{}} = Envd.send_input("sbx-1", "turn-1", ["hel", "lo"])
      assert {:ok, %{}} = Envd.close_stdin("sbx-1", "turn-1")
      assert {:ok, [%{"tag" => "turn-1"}]} = Envd.list_processes("sbx-1")
      assert :ok = Envd.write_file("sbx-1", "/work/file.txt", ["con", "tents"])
      assert {:ok, "contents"} = Envd.read_file("sbx-1", "/work/file.txt")

      assert_received {:request, "POST", "/process.Process/SendInput", _, input_body}

      assert Jason.decode!(input_body) == %{
               "process" => %{"tag" => "turn-1"},
               "input" => %{"stdin" => Base.encode64("hello")}
             }

      assert_received {:request, "POST", "/process.Process/CloseStdin", _, close_body}
      assert Jason.decode!(close_body) == %{"process" => %{"tag" => "turn-1"}}
      assert_received {:request, "POST", "/files", upload_query, _}
      assert upload_query =~ "username=sprite"
      assert_received {:request, "GET", "/files", read_query, _}
      assert read_query =~ "path=%2Fwork%2Ffile.txt"
    end

    test "list defaults missing processes to an empty list" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{}))
      assert {:ok, []} = Envd.list_processes("sbx-1")
    end

    test "file not-found and all endpoint HTTP errors are preserved" do
      {:ok, status} = Agent.start_link(fn -> 404 end)

      Req.Test.stub(__MODULE__, fn conn ->
        code = Agent.get(status, & &1)
        conn |> Plug.Conn.put_status(code) |> Req.Test.json(%{"error" => "failure"})
      end)

      assert {:error, :not_found} = Envd.read_file("sbx-1", "/missing")
      Agent.update(status, fn _ -> 418 end)
      error = {:error, {:api_error, 418, %{"error" => "failure"}}}
      assert Envd.send_input("sbx-1", "tag", "x") == error
      assert Envd.close_stdin("sbx-1", "tag") == error
      assert Envd.list_processes("sbx-1") == error
      assert Envd.write_file("sbx-1", "/file", "x") == error
      assert Envd.read_file("sbx-1", "/file") == error
    end

    test "all endpoint transport errors are preserved" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      assert_transport_error(Envd.send_input("sbx-1", "tag", "x"))
      assert_transport_error(Envd.close_stdin("sbx-1", "tag"))
      assert_transport_error(Envd.list_processes("sbx-1"))
      assert_transport_error(Envd.write_file("sbx-1", "/file", "x"))
      assert_transport_error(Envd.read_file("sbx-1", "/file"))
    end
  end

  describe "Connect envelope codec" do
    test "round-trips a message frame" do
      frame = Envd.encode_frame(%{"hello" => "world"})
      assert {[{:message, %{"hello" => "world"}}], <<>>} = Envd.decode_frames(frame)
    end

    test "decodes multiple frames and keeps an incomplete tail" do
      a = Envd.encode_frame(%{"n" => 1})
      b = Envd.encode_frame(%{"n" => 2})
      <<partial::binary-size(3), _::binary>> = Envd.encode_frame(%{"n" => 3})

      assert {[{:message, %{"n" => 1}}, {:message, %{"n" => 2}}], ^partial} =
               Envd.decode_frames(a <> b <> partial)
    end

    test "flag 2 is the end-of-stream frame" do
      json = Jason.encode!(%{"error" => %{"message" => "boom"}})
      frame = <<2, byte_size(json)::32-big, json::binary>>

      assert {[{:end_stream, %{"error" => %{"message" => "boom"}}}], <<>>} =
               Envd.decode_frames(frame)
    end

    test "an empty or sub-header buffer decodes to nothing" do
      assert {[], <<>>} = Envd.decode_frames(<<>>)
      assert {[], <<0, 0>>} = Envd.decode_frames(<<0, 0>>)

      # A complete header is not a complete frame until its declared payload arrives.
      incomplete_payload = <<0, 5::32-big, "abc">>
      assert {[], ^incomplete_payload} = Envd.decode_frames(incomplete_payload)
    end
  end

  describe "start_request/4" do
    test "builds the tagged process config with envs and cwd" do
      request =
        Envd.start_request("fountain-1", "bash", ["-lc", "true"],
          env: [{"A", "1"}],
          dir: "/home/sprite"
        )

      assert %{
               tag: "fountain-1",
               process: %{
                 cmd: "bash",
                 args: ["-lc", "true"],
                 envs: %{"A" => "1"},
                 cwd: "/home/sprite"
               }
             } = request
    end

    test "omits cwd when absent" do
      request = Envd.start_request("t", "true", [], [])
      refute Map.has_key?(request.process, :cwd)
    end
  end

  describe "Target" do
    test "carries envd's token as a header, and inspect shows only the id" do
      target = %Envd.Target{id: "sbx-1", token: "envd-secret"}

      assert Envd.id_of(target) == "sbx-1"
      assert Envd.id_of("sbx-1") == "sbx-1"
      assert Envd.host(target) == Envd.host("sbx-1")
      assert Req.Request.get_header(Envd.req(target), "x-access-token") == ["envd-secret"]
      assert Req.Request.get_header(Envd.req("sbx-1"), "x-access-token") == []
      assert Req.Request.get_header(Envd.req(%Envd.Target{id: "sbx-1"}), "x-access-token") == []
      refute inspect(target) =~ "envd-secret"
      assert inspect(target) =~ "sbx-1"
    end
  end

  describe "host/1" do
    test "derives the envd host from the control-plane domain" do
      assert Envd.host("sbx123") == "https://49983-sbx123.test"
    end
  end

  defp assert_transport_error({:error, %Req.TransportError{reason: :econnrefused}}), do: :ok
end
