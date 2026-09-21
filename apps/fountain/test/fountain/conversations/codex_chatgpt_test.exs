defmodule Fountain.Conversations.CodexChatGPTTest do
  @moduledoc """
  How a grant reaches a codex sandbox: the env entry and the `auth.json`
  Fountain writes instead of running `codex login`. The deployment's grant
  (ADR 0047 decision 4) and a user's subscription each get a `CODEX_HOME` of
  their own per grant and generation (ADR 0060 decision 6). `async: false`
  for the one platform row.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import Fountain.ChatGPTFixtures

  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.Reserved
  alias Fountain.Conversations.{CodexChatGPT, Provisioning}
  alias Fountain.InferenceCredentials.Source
  alias Managoat.Sandbox.Handle

  @handle %Handle{provider: :fake, name: "sbx"}
  @placeholder "__codex_chatgpt_access_token__"

  test "env/3 exports a grant for codex only, and only from a source that is one" do
    creds = %{codex_chatgpt_access_token: @placeholder, openai_api_key: nil}

    # The credentials map alone exports nothing: the source is the authority.
    for source <- [nil, Source.credential(), Source.platform()] do
      assert CodexChatGPT.env(Managoat.Runtimes.Codex, creds, source) == []
    end

    assert CodexChatGPT.env(Managoat.Runtimes.OpenCode, creds, platform_source()) == []
    assert CodexChatGPT.env(nil, creds, platform_source()) == []
  end

  describe "the deployment's grant: a CODEX_HOME of its own too" do
    setup do
      grant = connect!()
      {:ok, grant: grant, source: platform_source(grant)}
    end

    test "env/3 exports its placeholder and home, from the source", %{grant: grant} = ctx do
      assert CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, ctx.source) == [
               {"CODEX_CHATGPT_ACCESS_TOKEN", Reserved.placeholder(grant.id)},
               {"CODEX_HOME", "/home/sprite/.codex-grants/#{grant.id}.#{grant.generation}"}
             ]

      assert CodexChatGPT.managed_grant(ctx.source, nil) == %{
               owner: :platform,
               grant_id: grant.id,
               generation: grant.generation
             }

      assert CodexChatGPT.own_home?(ctx.source)
      # It stays under the machine's one-source binding (ADR 0047 decision 6).
      refute CodexChatGPT.outside_machine_binding?(ctx.source)
    end

    test "prepare_sandbox/5 is :skip for another runtime or another source", ctx do
      env = CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, ctx.source)
      assert CodexChatGPT.prepare_sandbox(@handle, "claude", env, ctx.source, nil) == :skip
      assert prepare("codex", [{"OPENAI_API_KEY", "sk-x"}]) == :skip
      assert prepare("codex", [{"CODEX_CHATGPT_ACCESS_TOKEN", @placeholder}]) == :skip
    end

    test "prepare_sandbox/5 refuses a key beside the grant, and touches no sandbox", ctx do
      # `:skip` here once meant the key wins. The spawn would still carry the
      # grant's `CODEX_HOME`, which a skip never creates, and its broker
      # session would still be the grant's HTTP-only one.
      reject(&Managoat.Sandbox.exec/4)
      reject(&Managoat.Sandbox.write_file/4)
      env = CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, ctx.source)
      assert {"CODEX_HOME", _} = List.keyfind(env, "CODEX_HOME", 0)

      assert {:error, :codex_grant_key_conflict} =
               CodexChatGPT.prepare_sandbox(
                 @handle,
                 "codex",
                 env ++ [{"OPENAI_API_KEY", "sk-from-vault"}],
                 ctx.source,
                 nil
               )
    end

    test "prepare_sandbox/5 writes the chatgptAuthTokens file into the grant's own home",
         %{grant: grant} = ctx do
      test_pid = self()
      home = "/home/sprite/.codex-grants/#{grant.id}.#{grant.generation}"

      expect(Managoat.Sandbox, :exec, fn @handle, "sh", ["-c", _, "sh", shared, ^home], _ ->
        assert shared == "/home/sprite/.codex"
        {:ok, "", 0}
      end)

      expect(Managoat.Sandbox, :write_file, fn @handle, path, body, opts ->
        send(test_pid, {:written, path, body, opts})
        :ok
      end)

      env = [
        {"HOME", "/home/sprite"} | CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, ctx.source)
      ]

      assert :ok = CodexChatGPT.prepare_sandbox(@handle, "codex", env, ctx.source, nil)

      assert_receive {:written, path, body, opts}
      assert path == home <> "/auth.json"
      assert opts[:mode] == 0o600
      placeholder = Reserved.placeholder(grant.id)

      assert %{
               "auth_mode" => "chatgptAuthTokens",
               "tokens" => %{
                 "access_token" => ^placeholder,
                 "refresh_token" => "",
                 "account_id" => "acct_platform_1",
                 "id_token" => id_token
               },
               "last_refresh" => last_refresh
             } = Jason.decode!(body)

      assert {:ok, %{"account_id" => "acct_platform_1", "email" => nil}} =
               Fountain.PlatformChatGPT.Tokens.claims(id_token)

      assert {:ok, _, _} = DateTime.from_iso8601(last_refresh)
      # Nothing but the placeholder stands where a token would.
      refute body =~ "rt_original"
    end

    test "prepare_sandbox/5 reports a sandbox that refuses, and a grant that is gone", ctx do
      env = CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, ctx.source)
      expect(Managoat.Sandbox, :exec, fn _, "sh", _, _ -> {:ok, "read-only", 1} end)

      assert {:error, {:codex_home_prepare, 1, "read-only"}} =
               CodexChatGPT.prepare_sandbox(@handle, "codex", env, ctx.source, nil)

      Fountain.ChatGPTAccounts.platform_disconnect()

      assert {:error, :platform_chatgpt_not_connected} =
               CodexChatGPT.prepare_sandbox(@handle, "codex", env, ctx.source, nil)

      # A reconnect is a new generation: the old pin finds nothing, and is
      # never answered from the new sign-in.
      connect!(%{account_id: "acct_other", id_token: id_token(%{account_id: "acct_other"})})

      assert {:error, :platform_chatgpt_not_connected} =
               CodexChatGPT.prepare_sandbox(@handle, "codex", env, ctx.source, nil)
    end

    test "refusal_stage/3 leaves the deployment's fenced mint to the caller's own words", ctx do
      # The issuance fence refuses the deployment's grant as it does a user's
      # (an admin disconnected it between the resolve and the mint). It has no
      # sentence of stage 2's, so the caller reports the reason as it always
      # has; what it must not do is fall through the user's clauses.
      Fountain.ChatGPTAccounts.platform_disconnect()
      fenced = {:broker, :session, :managed_grant_inactive}

      assert CodexChatGPT.refusal_stage(fenced, nil, ctx.source) == nil
      assert CodexChatGPT.refusal_stage(fenced, insert_verified_user().id, ctx.source) == nil
    end

    test "Provisioning.prepare_runtime_sprite/7 takes the grant path before the library's login",
         ctx do
      # The library's `prepare_sandbox/3` would spawn `codex login`; on the
      # grant path it is never reached, so a spawn is a failure here.
      reject(&Managoat.Sandbox.spawn/4)
      stub(Fountain.RuntimeDispatch, :install, fn _, "codex", _ -> :ok end)
      expect(Managoat.Sandbox, :exec, fn _, "sh", _, _ -> {:ok, "", 0} end)
      expect(Managoat.Sandbox, :write_file, fn _, _, _, _ -> :ok end)

      assert :ok =
               Provisioning.prepare_runtime_sprite(
                 @handle,
                 "codex",
                 Managoat.Runtimes.Codex,
                 %{name: "a"},
                 CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, ctx.source),
                 ctx.source,
                 nil
               )
    end
  end

  describe "a user's subscription: a CODEX_HOME per grant and generation" do
    setup do
      user = insert_verified_user()
      grant = user_grant!(user.id, %{name: "Personal"})
      {:ok, user: user, grant: grant, source: grant_source(grant)}
    end

    test "env/3 exports the grant's own placeholder and home, from the source alone",
         %{grant: grant, source: source} do
      home = "/home/sprite/.codex-grants/#{grant.id}.#{grant.generation}"

      # Whatever the credentials map holds: the source is the authority.
      for creds <- [%{}, %{codex_chatgpt_access_token: "anything"}] do
        assert CodexChatGPT.env(Managoat.Runtimes.Codex, creds, source) == [
                 {"CODEX_CHATGPT_ACCESS_TOKEN", Reserved.placeholder(grant.id)},
                 {"CODEX_HOME", home}
               ]
      end

      assert CodexChatGPT.env(Managoat.Runtimes.OpenCode, %{}, source) == []
      assert Reserved.placeholder?(Reserved.placeholder(grant.id))
      assert Reserved.conflict?(Reserved.placeholder(grant.id))
      refute Reserved.placeholder(grant.id) == @placeholder
    end

    test "two grants, and two sign-ins of one grant, have different homes", %{user: user} = ctx do
      other = user_grant!(user.id)
      {:ok, first} = CodexChatGPT.home(ref(ctx.grant))
      {:ok, second} = CodexChatGPT.home(ref(other))
      {:ok, reconnected} = CodexChatGPT.home(%{ref(ctx.grant) | generation: Ecto.UUID.generate()})
      assert length(Enum.uniq([first, second, reconnected])) == 3
      assert Enum.all?([first, second, reconnected], &String.starts_with?(&1, "/home/sprite/"))
    end

    test "an id that is not a UUID makes no path" do
      for bad <- ["../../etc", "a b", "", "$(id)"] do
        assert :error = CodexChatGPT.home(%{grant_id: bad, generation: Ecto.UUID.generate()})
        assert :error = CodexChatGPT.home(%{grant_id: Ecto.UUID.generate(), generation: bad})
      end
    end

    test "prepare_sandbox/5 links the shared configuration and writes this grant's own file",
         %{user: user, grant: grant, source: source} do
      platform = connect!()
      test_pid = self()
      home = "/home/sprite/.codex-grants/#{grant.id}.#{grant.generation}"

      expect(Managoat.Sandbox, :exec, fn @handle, "sh", argv, [] ->
        send(test_pid, {:exec, argv})
        {:ok, "", 0}
      end)

      expect(Managoat.Sandbox, :write_file, fn @handle, path, body, opts ->
        send(test_pid, {:written, path, body, opts})
        :ok
      end)

      env = CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, source)
      assert :ok = CodexChatGPT.prepare_sandbox(@handle, "codex", env, source, user.id)

      # The script is a constant; the two paths are arguments to it.
      assert_receive {:exec, ["-c", script, "sh", "/home/sprite/.codex", ^home]}
      assert script == CodexChatGPT.link_script()
      refute script =~ grant.id
      refute script =~ "/home/sprite"
      assert script =~ ~s([ "$n" = auth.json ] && continue)

      assert_receive {:written, path, body, opts}
      assert path == home <> "/auth.json"
      assert opts[:mode] == 0o600

      assert %{
               "auth_mode" => "chatgptAuthTokens",
               "tokens" => %{
                 "access_token" => access,
                 "refresh_token" => "",
                 "account_id" => account_id,
                 "id_token" => id_token
               }
             } = Jason.decode!(body)

      assert access == Reserved.placeholder(grant.id)
      assert account_id == grant.account_id
      refute account_id == platform.account_id

      assert {:ok, %{"account_id" => ^account_id}} =
               Fountain.PlatformChatGPT.Tokens.claims(id_token)

      refute body =~ "rt_user"
    end

    test "prepare_sandbox/5 is pinned: another sign-in, another owner and a gone grant write nothing",
         %{user: user, grant: grant, source: source} do
      connect!()
      reject(&Managoat.Sandbox.exec/4)
      reject(&Managoat.Sandbox.write_file/4)
      env = CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, source)
      grant_id = grant.id

      # Another account's conversation cannot write this user's account file.
      stranger = insert_verified_user()

      assert {:error, {:chatgpt_grant_unusable, %{grant_id: ^grant_id, reason: :not_found}}} =
               CodexChatGPT.prepare_sandbox(@handle, "codex", env, source, stranger.id)

      # A reconnect is a new generation: the old conversation's pin finds
      # nothing. The grant is fine and this conversation's source is not it,
      # which is the answer `ensure_fresh/2` gives the same fact.
      {:ok, _} =
        ChatGPTAccounts.reconnect_for_user(grant.id, user.id, %{
          access_token: access_token(),
          refresh_token: "rt_again",
          id_token: id_token(%{account_id: grant.account_id})
        })

      assert {:error, :inference_source_changed} =
               CodexChatGPT.prepare_sandbox(@handle, "codex", env, source, user.id)

      assert {:error, :inference_source_changed} = CodexChatGPT.ensure_fresh(user.id, source)

      # At another generation and not active: it is the grant that cannot serve.
      Repo.update_all(from(a in Fountain.PlatformChatGPT.Account, where: a.id == ^grant_id),
        set: [status: "revoked"]
      )

      assert {:error,
              {:chatgpt_grant_unusable,
               %{grant_id: ^grant_id, name: "Personal", reason: :reconnect_required}}} =
               CodexChatGPT.prepare_sandbox(@handle, "codex", env, source, user.id)

      Repo.update_all(from(a in Fountain.PlatformChatGPT.Account, where: a.id == ^grant_id),
        set: [status: "active"]
      )

      :ok = ChatGPTAccounts.disconnect_for_user(grant.id, user.id)

      assert {:error, {:chatgpt_grant_unusable, %{name: "Personal", reason: :disconnected}}} =
               CodexChatGPT.prepare_sandbox(@handle, "codex", env, source, user.id)
    end

    # What a provision or a wake publishes when the broker's fence minted no
    # session. Through two real servers in `codex_grant_peers_test.exs`; here,
    # the reasons only the row and the credential read can tell apart.
    test "refusal_stage/3 names why the fence refused, and answers nil for any other reason",
         %{user: user, grant: grant, source: source} do
      fenced = {:broker, :session, :managed_grant_inactive}
      grant_id = grant.id

      for other <- [{:broker, :session, :timeout}, :enospc, fenced] do
        assert CodexChatGPT.refusal_stage(other, user.id, nil) == nil
      end

      assert CodexChatGPT.refusal_stage({:broker, :session, :timeout}, user.id, source) == nil

      # The row is what was resolved and its owner may no longer use it.
      Repo.update_all(from(u in Fountain.Accounts.User, where: u.id == ^user.id),
        set: [suspended_at: DateTime.utc_now()]
      )

      assert %{
               reason: "chatgpt_grant_unusable",
               grant_reason: "owner_ineligible",
               grant_id: ^grant_id,
               retryable: false
             } = CodexChatGPT.refusal_stage(fenced, user.id, source)

      Repo.update_all(from(u in Fountain.Accounts.User, where: u.id == ^user.id),
        set: [suspended_at: nil]
      )

      Repo.update_all(from(a in Fountain.PlatformChatGPT.Account, where: a.id == ^grant_id),
        set: [status: "revoked"]
      )

      assert %{grant_reason: "revoked", retryable: false, message: message} =
               CodexChatGPT.refusal_stage(fenced, user.id, source)

      assert message =~ "Personal"

      # Nobody else's conversation learns anything of it, its name included.
      stranger = insert_verified_user()

      assert %{grant_reason: "not_found", retryable: false, message: message} =
               CodexChatGPT.refusal_stage(fenced, stranger.id, source)

      refute message =~ "Personal"
    end

    # The shared path ends in the deployment's account file. A user's source
    # that pins nothing must not reach it, connected platform grant or not.
    test "a :grant source that pins nothing is refused, and never takes the shared path",
         %{user: user, source: source} do
      # Connected, so the shared path would have a file to write, and handed
      # the entry it keys on: it writes with these two calls or not at all.
      connect!()
      reject(&Managoat.Sandbox.exec/4)
      reject(&Managoat.Sandbox.write_file/4)
      placeholder = [{"CODEX_CHATGPT_ACCESS_TOKEN", @placeholder}]

      unpinned = [
        {source, nil},
        {%{source | grant_id: nil}, user.id},
        {%{source | generation: nil}, user.id}
      ]

      for {source, user_id} <- unpinned do
        assert {:error, :invalid_codex_home} =
                 CodexChatGPT.prepare_sandbox(@handle, "codex", placeholder, source, user_id)
      end

      # And what it exports is nothing: not the entry the shared path keys on.
      creds = %{codex_chatgpt_access_token: @placeholder}

      for bad <- [
            %{source | grant_id: nil},
            %{source | generation: nil},
            %{source | grant_id: "x"}
          ] do
        assert CodexChatGPT.env(Managoat.Runtimes.Codex, creds, bad) == []
      end
    end

    test "prepare_sandbox/5 refuses an API key beside the grant, and reports a sandbox that refuses",
         %{user: user, source: source} do
      env = CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, source)

      assert {:error, :codex_grant_key_conflict} =
               CodexChatGPT.prepare_sandbox(
                 @handle,
                 "codex",
                 env ++ [{"OPENAI_API_KEY", "sk-from-vault"}],
                 source,
                 user.id
               )

      expect(Managoat.Sandbox, :exec, fn _, "sh", _, _ -> {:ok, "read-only", 1} end)

      assert {:error, {:codex_home_prepare, 1, "read-only"}} =
               CodexChatGPT.prepare_sandbox(@handle, "codex", env, source, user.id)

      assert CodexChatGPT.prepare_sandbox(@handle, "claude", env, source, user.id) == :skip
    end

    # Env values reach a self-hosted runner verbatim, and `/home/sprite` is not
    # a path on its machine (`Provisioning.broker_ca_files/1`).
    test "a runner's spawn is given the home where its machine keeps it", %{source: source} do
      stub(Managoat.Sandbox, :host_path, fn @handle, "/home/sprite" <> rest ->
        "/Users/me/sandboxes/sbx" <> rest
      end)

      [_placeholder, {"CODEX_HOME", home}] =
        CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, source)

      state = %{broker: %{}, handle: @handle}

      assert {:ok, opts} =
               Fountain.Conversations.CodexTransport.spawn_opts(state, "codex",
                 env: CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, source)
               )

      "/home/sprite" <> rest = home
      assert {"CODEX_HOME", "/Users/me/sandboxes/sbx" <> rest} in opts[:env]

      # A tenant's own CODEX_HOME is theirs, wherever it points.
      assert {:ok, opts} =
               Fountain.Conversations.CodexTransport.spawn_opts(state, "codex",
                 env: [{"CODEX_HOME", "/home/sprite/.codex"}]
               )

      assert {"CODEX_HOME", "/home/sprite/.codex"} in opts[:env]
    end

    test "sandbox_auth/1 answers for the pinned sign-in only, for either owner", %{grant: grant} do
      platform = connect!()

      assert {:ok, %{account_id: account_id}} = ChatGPTAccounts.sandbox_auth(ref(grant))
      assert account_id == grant.account_id

      assert {:ok, %{account_id: "acct_platform_1"}} =
               ChatGPTAccounts.sandbox_auth(%{
                 owner: :platform,
                 grant_id: platform.id,
                 generation: platform.generation
               })

      for bad <- [
            %{ref(grant) | generation: Ecto.UUID.generate()},
            %{ref(grant) | owner: :platform},
            %{ref(grant) | owner: {:user, Ecto.UUID.generate()}},
            %{
              owner: {:user, grant.user_id},
              grant_id: platform.id,
              generation: platform.generation
            },
            %{ref(grant) | grant_id: "not-a-uuid"}
          ] do
        assert :none = ChatGPTAccounts.sandbox_auth(bad)
      end
    end
  end

  # The real script, against a real directory tree: what is shared, what is
  # not, and that running it again changes nothing.
  describe "the link script" do
    test "links everything but auth.json, keeps two homes apart, and is idempotent" do
      tmp = Fountain.TmpDir.mkdir!("codex-grant-homes")
      shared = Path.join(tmp, ".codex")
      File.mkdir_p!(Path.join(shared, "skills/fountain"))
      File.write!(Path.join(shared, "config.toml"), "model = \"gpt\"")
      File.write!(Path.join(shared, "AGENTS.md"), "be brief")
      File.write!(Path.join(shared, ".hidden"), "dot")
      File.write!(Path.join(shared, "auth.json"), ~s({"shared":"platform"}))
      homes = for name <- ["one", "two"], do: Path.join([tmp, ".codex-grants", name])

      for home <- homes, _ <- 1..2 do
        assert {_, 0} = link(shared, home)
      end

      for {home, body} <- Enum.zip(homes, ["one", "two"]) do
        File.write!(Path.join(home, "auth.json"), body)
      end

      for {home, body} <- Enum.zip(homes, ["one", "two"]) do
        assert File.read!(Path.join(home, "auth.json")) == body
        assert File.read!(Path.join(home, "config.toml")) == "model = \"gpt\""
        assert File.read!(Path.join(home, ".hidden")) == "dot"
        assert File.dir?(Path.join(home, "skills/fountain"))
        assert File.lstat!(Path.join(home, "sessions")).type == :symlink
        assert File.lstat!(Path.join(home, "auth.json")).type == :regular
        assert File.stat!(home).mode |> Bitwise.band(0o777) == 0o700
      end

      # One peer's rollout is where the other's `thread/resume` looks.
      [one, two] = homes
      File.write!(Path.join(one, "sessions/rollout.jsonl"), "{}")
      assert File.read!(Path.join(two, "sessions/rollout.jsonl")) == "{}"
      assert File.read!(Path.join(shared, "auth.json")) == ~s({"shared":"platform"})
    end

    # Two conversations on one sign-in share a home and may prepare it at
    # once: the check and the `ln` are two steps, and the loser's `ln` meets
    # a link the winner just made. The `ln` here is that loser, every time.
    test "a link a peer made first is not a failure; an ln that made nothing still is" do
      tmp = Fountain.TmpDir.mkdir!("codex-grant-race")
      shared = Path.join(tmp, ".codex")
      File.mkdir_p!(shared)
      File.write!(Path.join(shared, "config.toml"), "model = \"gpt\"")
      home = Path.join([tmp, ".codex-grants", "one"])

      lost_the_race = with_ln(tmp, ~s("$real" "$@"\nexit 1))
      assert {_, 0} = link(shared, home, lost_the_race)
      assert File.lstat!(Path.join(home, "config.toml")).type == :symlink
      assert File.lstat!(Path.join(home, "sessions")).type == :symlink

      broken = with_ln(tmp, "exit 1")
      other = Path.join([tmp, ".codex-grants", "two"])
      assert {_, code} = link(shared, other, broken)
      assert code != 0

      # And really at once, against the real `ln`.
      crowded = Path.join([tmp, ".codex-grants", "three"])
      for n <- 1..50, do: File.write!(Path.join(shared, "file-#{n}"), "")

      results =
        1..8
        |> Task.async_stream(fn _ -> link(shared, crowded) end, max_concurrency: 8)
        |> Enum.map(fn {:ok, {_out, code}} -> code end)

      assert results == List.duplicate(0, 8)
      assert File.lstat!(Path.join(crowded, "file-50")).type == :symlink
    end

    # Everything under the sandbox's home is the agent's to write, so a home
    # can be planted before Fountain prepares it.
    test "a home that is a symbolic link is refused, and a planted auth.json link is removed" do
      tmp = Fountain.TmpDir.mkdir!("codex-grant-planted")
      shared = Path.join(tmp, ".codex")
      File.mkdir_p!(shared)
      File.write!(Path.join(shared, "config.toml"), "model = \"gpt\"")
      root = Path.join(tmp, ".codex-grants")
      File.mkdir_p!(root)

      # Another grant's home, wearing this one's name.
      victim = Path.join(root, "victim")
      File.mkdir_p!(victim)
      File.write!(Path.join(victim, "auth.json"), "victim's account")
      home = Path.join(root, "mine")
      File.ln_s!(victim, home)

      assert {out, 3} = link(shared, home)
      assert out =~ "symbolic link"
      assert File.ls!(victim) == ["auth.json"]

      # The directory of homes, moved somewhere else.
      elsewhere = Path.join(tmp, "elsewhere")
      File.mkdir_p!(elsewhere)
      moved = Path.join(tmp, "moved-grants")
      File.ln_s!(elsewhere, moved)
      assert {_, 3} = link(shared, Path.join(moved, "mine"))
      assert File.ls!(elsewhere) == []

      # A real home whose auth.json points at the victim's: the link goes, so
      # the write that follows lands here; what it pointed at is untouched.
      File.rm!(home)
      File.mkdir_p!(home)
      File.ln_s!(Path.join(victim, "auth.json"), Path.join(home, "auth.json"))
      assert {_, 0} = link(shared, home)
      refute File.exists?(Path.join(home, "auth.json"))
      assert {:error, :enoent} = File.lstat(Path.join(home, "auth.json"))
      assert File.read!(Path.join(victim, "auth.json")) == "victim's account"

      # A regular file is left for the write to replace: a peer may be reading it.
      File.write!(Path.join(home, "auth.json"), "mine")
      assert {_, 0} = link(shared, home)
      assert File.read!(Path.join(home, "auth.json")) == "mine"
    end
  end

  defp link(shared, home, opts \\ []) do
    System.cmd(
      "sh",
      ["-c", CodexChatGPT.link_script(), "sh", shared, home],
      [stderr_to_stdout: true] ++ opts
    )
  end

  # An `ln` first on PATH that does what `body` says, given the real one.
  defp with_ln(tmp, body) do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    real = System.find_executable("ln")
    File.write!(Path.join(bin, "ln"), "#!/bin/sh\nreal=#{real}\n#{body}\n")
    File.chmod!(Path.join(bin, "ln"), 0o755)
    [env: [{"PATH", bin <> ":" <> System.get_env("PATH")}]]
  end

  defp prepare(runtime, sprite_env),
    do: CodexChatGPT.prepare_sandbox(@handle, runtime, sprite_env, nil, nil)

  defp ref(grant),
    do: %{owner: {:user, grant.user_id}, grant_id: grant.id, generation: grant.generation}

  defp grant_source(grant) do
    %{
      Source.grant()
      | kind: :codex_chatgpt_access_token,
        identity: "chatgpt_grant:" <> grant.id,
        revision: grant.generation,
        grant_id: grant.id,
        generation: grant.generation
    }
  end

  defp platform_source(grant \\ %{id: Ecto.UUID.generate(), generation: Ecto.UUID.generate()}) do
    %{
      Source.platform()
      | kind: :codex_chatgpt_access_token,
        identity: "platform:chatgpt:" <> grant.id,
        revision: grant.generation
    }
  end
end
