defmodule Fountain.Conversations.CodexChatGPTTest do
  @moduledoc """
  How a grant reaches a codex sandbox: the env entry and the `auth.json`
  Fountain writes instead of running `codex login`. The deployment's grant
  (ADR 0047 decision 4) keeps the shared `~/.codex`; a user's subscription
  gets a `CODEX_HOME` of its own per grant and generation (ADR 0060 decision
  6). `async: false` for the one platform row.
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

  test "env/3 exports the grant for codex only, and only when present" do
    creds = %{codex_chatgpt_access_token: @placeholder, openai_api_key: nil}

    # The deployment's grant, and every source that is not a grant at all,
    # says nothing about a home: codex keeps the shared `~/.codex`.
    for source <- [nil, platform_source()] do
      assert CodexChatGPT.env(Managoat.Runtimes.Codex, creds, source) ==
               [{"CODEX_CHATGPT_ACCESS_TOKEN", @placeholder}]

      assert CodexChatGPT.env(Managoat.Runtimes.Codex, %{}, source) == []

      assert CodexChatGPT.env(Managoat.Runtimes.Codex, %{codex_chatgpt_access_token: ""}, source) ==
               []

      assert CodexChatGPT.env(Managoat.Runtimes.OpenCode, creds, source) == []
      assert CodexChatGPT.env(nil, creds, source) == []
    end
  end

  test "prepare_sandbox/5 is :skip for another runtime or a spawn without the grant" do
    assert prepare("claude", [{"CODEX_CHATGPT_ACCESS_TOKEN", "x"}]) == :skip
    assert prepare("codex", [{"OPENAI_API_KEY", "sk-x"}]) == :skip
    assert prepare("codex", [{"CODEX_CHATGPT_ACCESS_TOKEN", ""}]) == :skip

    # A key beside the grant wins, as it does in the transport: the tenant's
    # environment may name OPENAI_API_KEY without holding a credential row.
    assert prepare("codex", [
             {"CODEX_CHATGPT_ACCESS_TOKEN", @placeholder},
             {"OPENAI_API_KEY", "sk-from-vault"}
           ]) == :skip
  end

  test "prepare_sandbox/5 writes the chatgptAuthTokens file with the placeholder and the synthesised id_token" do
    connect!()
    test_pid = self()

    expect(Managoat.Sandbox, :exec, fn @handle, "mkdir", ["-p", "/home/sprite/.codex"], _ ->
      {:ok, "", 0}
    end)

    expect(Managoat.Sandbox, :write_file, fn @handle, path, body, opts ->
      send(test_pid, {:written, path, body, opts})
      :ok
    end)

    assert :ok =
             prepare("codex", [
               {"HOME", "/home/sprite"},
               {"CODEX_CHATGPT_ACCESS_TOKEN", @placeholder}
             ])

    assert_receive {:written, "/home/sprite/.codex/auth.json", body, opts}
    assert opts[:mode] == 0o600

    assert %{
             "auth_mode" => "chatgptAuthTokens",
             "tokens" => %{
               "access_token" => @placeholder,
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

  test "prepare_sandbox/5 reports a sandbox that refuses the write, and a grant that is gone" do
    connect!()

    expect(Managoat.Sandbox, :exec, fn _, "mkdir", _, _ -> {:ok, "read-only", 1} end)

    assert {:error, {:codex_auth_mkdir, 1, "read-only"}} =
             prepare("codex", [{"CODEX_CHATGPT_ACCESS_TOKEN", "p"}])

    Fountain.ChatGPTAccounts.platform_disconnect()

    assert {:error, :platform_chatgpt_not_connected} =
             prepare("codex", [{"CODEX_CHATGPT_ACCESS_TOKEN", "p"}])
  end

  test "Provisioning.prepare_runtime_sprite/7 takes the grant path before the library's login" do
    connect!()

    # The library's `prepare_sandbox/3` would spawn `codex login`; on the
    # grant path it is never reached, so a spawn is a failure here.
    reject(&Managoat.Sandbox.spawn/4)
    stub(Fountain.RuntimeDispatch, :install, fn _, "codex", _ -> :ok end)
    expect(Managoat.Sandbox, :exec, fn _, "mkdir", _, _ -> {:ok, "", 0} end)
    expect(Managoat.Sandbox, :write_file, fn _, _, _, _ -> :ok end)

    assert :ok =
             Provisioning.prepare_runtime_sprite(
               @handle,
               "codex",
               Managoat.Runtimes.Codex,
               %{name: "a"},
               [{"CODEX_CHATGPT_ACCESS_TOKEN", @placeholder}],
               platform_source(),
               nil
             )
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

      for bad <- [%{source | grant_id: nil}, %{source | generation: nil}, %{source | grant_id: "x"}] do
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
        assert {_, 0} =
                 System.cmd("sh", ["-c", CodexChatGPT.link_script(), "sh", shared, home],
                   stderr_to_stdout: true
                 )
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

  defp platform_source do
    %{
      Source.platform()
      | kind: :codex_chatgpt_access_token,
        identity: "platform:chatgpt:" <> Ecto.UUID.generate(),
        revision: Ecto.UUID.generate()
    }
  end
end
