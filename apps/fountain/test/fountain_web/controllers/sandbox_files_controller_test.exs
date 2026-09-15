defmodule FountainWeb.SandboxFilesControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Crypto
  alias Fountain.Vaults

  @home "/home/sprite"

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    {_key, sprite_key} = insert_sprite_api_key(user)
    agent = insert_agent(user_id: user.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, status: "ready", agent_id: agent.id)
    {:ok, user: user, raw_key: raw_key, sprite_key: sprite_key, agent: agent, sandbox: sandbox}
  end

  defp exec_returns(output, code \\ 0) do
    expect(Managoat.Sandbox, :exec, fn _handle,
                                       "bash",
                                       ["-c", _script, "fountain-files" | args],
                                       _opts ->
      send(self(), {:exec_args, args})
      {:ok, output, code}
    end)
  end

  defp b64(bytes), do: Base.encode64(bytes)

  defp record(code, path), do: code <> " " <> path <> <<0>>

  describe "GET /api/sandboxes/:id/files" do
    test "lists the working directory by default", ctx do
      exec_returns("directory\t\tsrc\0file\t5\tREADME\0")

      data =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/sandboxes/#{ctx.sandbox.id}/files")
        |> json_response(200)
        |> Map.fetch!("data")

      assert_received {:exec_args, [@home, @home, "sandbox:" <> @home]}

      assert data == %{
               "path" => @home,
               "truncated" => false,
               "entries" => [
                 %{"name" => "src", "type" => "directory", "size" => nil},
                 %{"name" => "README", "type" => "file", "size" => 5}
               ]
             }
    end

    test "resolves a relative path and refuses one outside the sandbox", ctx do
      exec_returns("")

      ctx.conn
      |> authed_with_key(ctx.raw_key)
      |> get("/api/sandboxes/#{ctx.sandbox.id}/files?path=src/lib")
      |> json_response(200)

      assert_received {:exec_args, [@home <> "/src/lib", @home, "sandbox:" <> @home]}

      reject(&Managoat.Sandbox.exec/4)

      assert %{"error" => "path_outside_sandbox"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/files?path=/etc")
               |> json_response(422)
    end

    test "a sprite-scoped key is refused — the escalation path (ADR 0039)", ctx do
      reject(&Managoat.Sandbox.exec/4)

      assert %{"reason" => "insufficient_scope"} =
               ctx.conn
               |> authed_with_key(ctx.sprite_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/files")
               |> json_response(403)
    end

    test "a foreign sandbox is not found, indistinguishably", ctx do
      foreign = insert_sandbox(user_id: insert_verified_user().id, status: "ready")
      reject(&Managoat.Sandbox.exec/4)

      assert %{"error" => "not_found"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{foreign.id}/files")
               |> json_response(404)

      assert ctx.conn
             |> authed_with_key(ctx.raw_key)
             |> get("/api/sandboxes/not-a-uuid/files")
             |> json_response(404)
    end

    test "a parked sandbox is not woken for a read", ctx do
      parked = insert_sandbox(user_id: ctx.user.id, status: "suspended", agent_id: ctx.agent.id)
      reject(&Managoat.Sandbox.exec/4)

      assert %{"error" => "sandbox_not_ready", "status" => "suspended"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{parked.id}/files")
               |> json_response(409)
    end

    test "a missing directory is 404 and a file is 422", ctx do
      exec_returns("", 3)

      assert %{"error" => "path_not_found"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/files?path=gone")
               |> json_response(404)

      exec_returns("", 4)

      assert %{"error" => "not_a_directory"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/files?path=README")
               |> json_response(422)
    end

    test "an unreachable provider is 503 with a retry hint", ctx do
      expect(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:error, {:unavailable, :timeout}} end)

      conn =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/sandboxes/#{ctx.sandbox.id}/files")

      assert %{"error" => "sandbox_unreachable"} = json_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == ["10"]
    end
  end

  describe "GET /api/sandboxes/:id/file" do
    test "returns the file, redacted against the sandbox's vault", ctx do
      {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
      vault = insert_vault(user_id: ctx.user.id)

      {:ok, _} =
        Vaults.upsert_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_0123456789"}, dek)

      sandbox =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          agent_id: ctx.agent.id,
          vault_id: vault.id
        )

      body = "url=https://ghp_0123456789@github.com/x\n"
      exec_returns("#{byte_size(body)}\n" <> b64(body))

      data =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/sandboxes/#{sandbox.id}/file?path=.git/config&max_bytes=1000")
        |> json_response(200)
        |> Map.fetch!("data")

      # 1000 plus the overlap, one byte less than `ghp_0123456789`, so a value
      # lying across the cap is whole when redaction runs (#1907).
      assert_received {:exec_args, ["1013", @home <> "/.git/config", @home, "sandbox:" <> @home]}

      assert data == %{
               "path" => @home <> "/.git/config",
               "size" => byte_size(body),
               "truncated" => false,
               "encoding" => "utf-8",
               "content" => "url=https://[REDACTED]@github.com/x\n"
             }
    end

    test "path is required — the operation says so, and the cast plug enforces it", ctx do
      reject(&Managoat.Sandbox.exec/4)

      # The cast plug renders `{error, errors}` like every other validation
      # failure now (#1431), so the field is a key rather than a pointer.
      assert %{"error" => "validation_failed", "errors" => %{"path" => [_ | _]}} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/file")
               |> json_response(422)
    end

    test "a directory is 422 and a sprite key is 403", ctx do
      exec_returns("", 4)

      assert %{"error" => "is_a_directory"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/file?path=src")
               |> json_response(422)

      reject(&Managoat.Sandbox.exec/4)

      assert ctx.conn
             |> authed_with_key(ctx.sprite_key)
             |> get("/api/sandboxes/#{ctx.sandbox.id}/file?path=.env")
             |> json_response(403)
    end
  end

  describe "GET /api/sandboxes/:id/diff" do
    test "diffs the working directory's repository, with staged and ref as flags", ctx do
      diff = "diff --git a/f b/f\n+x\n"
      exec_returns(@home <> <<0>> <> b64(diff))

      data =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/sandboxes/#{ctx.sandbox.id}/diff?staged=true&ref=main")
        |> json_response(200)
        |> Map.fetch!("data")

      assert_received {:exec_args, [@home, "262145", "main", "1", @home, "sandbox:" <> @home]}

      assert data == %{
               "path" => @home,
               "repo_root" => @home,
               "staged" => true,
               "ref" => "main",
               "diff" => diff,
               "truncated" => false
             }
    end

    test "an unknown ref is 404, a plain directory 422, and a bad ref is 422 before anything runs",
         ctx do
      exec_returns("", 7)

      assert %{"error" => "ref_not_found"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/diff?ref=nope")
               |> json_response(404)

      exec_returns("", 6)

      assert %{"error" => "not_a_repository"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/diff?path=plain")
               |> json_response(422)

      # Mimic serves expectations in order, so the reject goes last.
      reject(&Managoat.Sandbox.exec/4)

      assert %{"error" => "invalid_ref"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/diff?ref=--output=x")
               |> json_response(422)
    end

    test "a failing command carries its exit code and output", ctx do
      exec_returns("fatal: detected dubious ownership", 128)

      assert %{
               "error" => "sandbox_command_failed",
               "exit_code" => 128,
               "output" => "fatal: " <> _
             } =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/diff")
               |> json_response(422)
    end
  end

  describe "GET /api/sandboxes/:id/git-status" do
    test "reports untracked and deleted paths, which no diff shows together", ctx do
      exec_returns(
        @home <>
          <<0>> <>
          "main" <>
          <<0>> <>
          record("??", "notes.md") <> record(" D", "gone.txt") <> record("A ", "new.ex")
      )

      data =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/sandboxes/#{ctx.sandbox.id}/git-status?untracked=all")
        |> json_response(200)
        |> Map.fetch!("data")

      # Mapped and sandbox roots trail the arguments: the script confines the repository it
      # discovers to them, not just the path the caller asked for.
      assert_received {:exec_args, [@home, "1048577", "all", @home, "sandbox:" <> @home]}

      assert data == %{
               "path" => @home,
               "repo_root" => @home,
               "branch" => "main",
               "untracked" => "all",
               "truncated" => false,
               "entries" => [
                 %{
                   "path" => "gone.txt",
                   "index" => "unchanged",
                   "worktree" => "deleted",
                   "renamed_from" => nil
                 },
                 %{
                   "path" => "new.ex",
                   "index" => "added",
                   "worktree" => "unchanged",
                   "renamed_from" => nil
                 },
                 %{
                   "path" => "notes.md",
                   "index" => "untracked",
                   "worktree" => "untracked",
                   "renamed_from" => nil
                 }
               ]
             }
    end

    test "an untracked mode the enum does not name is refused before anything runs", ctx do
      reject(&Managoat.Sandbox.exec/4)

      assert %{"error" => "validation_failed", "errors" => %{"untracked" => [_ | _]}} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/git-status?untracked=--ignored")
               |> json_response(422)
    end

    test "a plain directory is 422, and a sprite key is 403", ctx do
      exec_returns("", 6)

      assert %{"error" => "not_a_repository"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/git-status?path=plain")
               |> json_response(422)

      reject(&Managoat.Sandbox.exec/4)

      assert %{"reason" => "insufficient_scope"} =
               ctx.conn
               |> authed_with_key(ctx.sprite_key)
               |> get("/api/sandboxes/#{ctx.sandbox.id}/git-status")
               |> json_response(403)
    end

    test "a parked sandbox is not woken for it either", ctx do
      parked = insert_sandbox(user_id: ctx.user.id, status: "suspended", agent_id: ctx.agent.id)
      reject(&Managoat.Sandbox.exec/4)

      assert %{"error" => "sandbox_not_ready", "status" => "suspended"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes/#{parked.id}/git-status")
               |> json_response(409)
    end
  end
end
