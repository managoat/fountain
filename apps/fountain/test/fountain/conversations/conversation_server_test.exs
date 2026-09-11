defmodule Fountain.Conversations.ConversationServerTest do
  @moduledoc """
  First tests for `ConversationServer`.

  1,183 lines that provision sandboxes, hold decrypted tenant secrets, mint API
  keys and spend money on sprites — with no test file at all since launch, and
  excluded from the coverage gate on top of that. Every caller `Mimic.copy`'d it
  away, so the module was verified only by running the product.

  These cover the lifecycle: provisioning succeeds and the sandbox reaches
  `ready`; each way provisioning can fail leaves the sandbox and conversation
  marked `failed` rather than stuck; teardown revokes the sprite's callback key;
  and a terminate against a dead server still cleans up the rows.
  """

  use Fountain.ConversationServerCase

  alias Fountain.{Accounts, Environments}
  alias Fountain.Repo

  # A runtime with no ACP adapter entry, which is the only way to reach the
  # legacy turn pipeline since #659. Not a real runtime name on purpose: the
  # four an agent may name all speak ACP now.
  @legacy_runtime "retired-runtime"

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)

    # These tests drive the legacy (non-ACP) turn pipeline through FakeRuntime.
    # gemini was the last runtime that still ran it, and #659 put gemini on ACP
    # too — so **no runtime an agent may name is legacy any more**. The pipeline
    # itself is still reachable (a conversation row whose runtime has no adapter
    # entry, and the peer-died-mid-turn path in `handle_info({:stdout, …})`), so
    # it stays covered here; the conversation's runtime carries no inclusion
    # validation, which is what makes that expressible. The ACP turn pipeline
    # has its own harness in conversation_server_acp_test.exs.
    agent = insert_agent(user_id: user.id, environment_id: env.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, status: "pending")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        runtime: @legacy_runtime,
        sandbox_id: sandbox.id,
        status: "pending"
      )

    {:ok, user: user, env: env, agent: agent, sandbox: sandbox, conv: conv}
  end

  describe "provisioning — happy path" do
    test "drives the sandbox to ready", %{conv: conv, sandbox: sandbox} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
      GenServer.stop(pid)
    end

    test "asks the runtime to write its config and prepare the sprite", %{conv: conv} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      assert_received :write_config
      assert_received :prepare_sandbox
      GenServer.stop(pid)
    end

    test "mints a sprite-scoped callback key and records it on the conversation", %{conv: conv} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      reloaded = Conversations._unsafe_get_conversation!(conv.id)
      assert reloaded.callback_api_key_id

      key = Repo.get(Accounts.ApiKey, reloaded.callback_api_key_id)
      assert key.scopes == ["sprite"]
      assert key.expires_at
      refute key.revoked_at

      GenServer.stop(pid)
    end

    test "runs the first turn when a prompt is supplied", %{conv: conv} do
      stub_happy_sprite()
      # The server reads command.ref, so the spawn result must be a command struct
      # rather than a bare pid.
      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: make_ref()}}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _cmd, _data -> :ok end)
      Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _cmd -> :ok end)

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "hello there")

      assert_received {:build_command, "hello there", _mode, _session, _opts}
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.prompt == "hello there"

      GenServer.stop(pid)
    end

    test "does not start a turn without a prompt", %{conv: conv} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      assert Conversations._unsafe_list_turns(conv.id) == []
      GenServer.stop(pid)
    end

    test "the prompt reaches a server the Horde registry cannot resolve", %{conv: conv} do
      # The #367 regression: queue_initial_prompt used to cast through the
      # Horde registry, and Horde's CRDT registrations propagate
      # asynchronously — a cast fired right after start_child could hit an
      # unresolved via-name and vanish. The server provisioned, the user's
      # first prompt was silently gone. Delivery now targets the pid, which
      # this harness proves by construction: its servers run outside Horde,
      # so the registry genuinely cannot resolve them.
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: make_ref()}}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _cmd, _data -> :ok end)
      Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _cmd -> :ok end)

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "first prompt")

      # Guards the premise, not the fix: the harness must keep its servers
      # out of Horde, or the turn assertion below stops demonstrating
      # anything about registry-independent delivery. It can only fail if
      # the harness changes (#406 item 11).
      assert Horde.Registry.lookup(Fountain.ConversationRegistry, conv.id) == []
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.prompt == "first prompt"

      GenServer.stop(pid)
    end
  end

  describe "the resolved MCP configuration (#1404)" do
    # The server's half of the fix. Resolution happens once, at provision, and
    # the resolved document is carried on state — so the turn path, which
    # re-reads the agent row on every prompt, has the resolved copy to send to
    # `session/new` instead of the raw one. `McpServersTest` covers what that
    # copy then becomes on the wire.
    test "provision resolves the agent's MCP config onto the server state", %{
      user: user,
      env: env,
      sandbox: sandbox
    } do
      {:ok, env} =
        Environments.update_environment(env, %{"env_vars" => %{"SALON_HOST" => "salon.example"}})

      agent =
        insert_agent(
          user_id: user.id,
          environment_id: env.id,
          runtime: "claude",
          mcp_servers: %{
            "salon" => %{
              "type" => "http",
              "url" => "https://${SALON_HOST}/mcp",
              "headers" => %{"Authorization" => "Bearer $${FOUNTAIN_TOKEN}"}
            }
          }
        )

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          runtime: @legacy_runtime,
          sandbox_id: sandbox.id,
          status: "pending"
        )

      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      resolved = :sys.get_state(pid).resolved_mcp_servers

      # The environment reference is resolved by Fountain, and the escaped one
      # is left as a single-`$` reference for the runtime to expand from the
      # sandbox's own process env — where the credential is always current,
      # which is why a reattached or resumed turn cannot send a stale token.
      assert resolved == %{
               "salon" => %{
                 "type" => "http",
                 "url" => "https://salon.example/mcp",
                 "headers" => %{"Authorization" => "Bearer ${FOUNTAIN_TOKEN}"}
               }
             }

      # The stored agent still holds the unresolved document: the resolved
      # values live only on the live conversation path.
      assert Fountain.Agents._unsafe_get_agent!(agent.id).mcp_servers["salon"]["url"] ==
               "https://${SALON_HOST}/mcp"

      GenServer.stop(pid)
    end

    test "an agentless conversation carries no resolved config", %{
      user: user,
      sandbox: sandbox
    } do
      conv =
        insert_conversation(
          user_id: user.id,
          agent_id: nil,
          runtime: @legacy_runtime,
          sandbox_id: sandbox.id,
          status: "pending"
        )

      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      assert :sys.get_state(pid).resolved_mcp_servers == nil

      GenServer.stop(pid)
    end
  end

  describe "provisioning — per-launch environment override (#783)" do
    # The observable difference between two environments at provision is which
    # checkpoint is restored, so that is what the assertion reads.
    test "the conversation's environment_id is provisioned from, not the agent's", %{
      user: user,
      env: agent_env
    } do
      {:ok, _} = Environments.update_environment(agent_env, %{"checkpoint_id" => "cp_agent"})
      override = insert_env(user_id: user.id, checkpoint_id: "cp_override")

      agent = insert_agent(user_id: user.id, environment_id: agent_env.id, runtime: "claude")
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          runtime: @legacy_runtime,
          sandbox_id: sandbox.id,
          environment_id: override.id,
          status: "pending"
        )

      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Fountain.Conversations.Provisioning, :restore_checkpoint, fn _s, id ->
        send(test_pid, {:restore_checkpoint, id})
        :ok
      end)

      {pid, _ref, :alive} = start_server(conv)

      assert_received {:restore_checkpoint, "cp_override"}
      refute_received {:restore_checkpoint, "cp_agent"}
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
      GenServer.stop(pid)
    end

    test "a cross-tenant environment_id on the conversation is not materialised", %{
      user: attacker,
      conv: conv,
      sandbox: sandbox
    } do
      victim = insert_verified_user()
      victim_env = insert_env(user_id: victim.id, checkpoint_id: "cp_victim")

      # Inserted through the bare changeset — start_conversation refuses this,
      # so only a row that bypassed it could carry a foreign id.
      {:ok, conv} =
        conv
        |> Fountain.Conversations.Conversation.changeset(%{"environment_id" => victim_env.id})
        |> Repo.update()

      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Fountain.Conversations.Provisioning, :restore_checkpoint, fn _s, id ->
        send(test_pid, {:restore_checkpoint, id})
        :ok
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {pid, _ref, :alive} = start_server(conv)
          refute_received {:restore_checkpoint, "cp_victim"}
          assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
          GenServer.stop(pid)
        end)

      assert log =~ "not owned by user #{attacker.id}"
    end
  end

  describe "provisioning — tenant isolation" do
    test "a cross-tenant environment_id on the agent is not materialised" do
      attacker = insert_verified_user()
      victim = insert_verified_user()
      victim_env = insert_env(user_id: victim.id, checkpoint_id: "cp_victim")

      # A legacy row from before create_agent validated environment ownership,
      # inserted through the bare changeset the context no longer exposes to
      # cross-tenant ids. The server must refuse to load it.
      {:ok, agent} =
        %Fountain.Agents.Agent{}
        |> Fountain.Agents.Agent.changeset(%{
          "name" => "legacy-cross-tenant",
          "model" => "google/gemini-3.1-pro-preview",
          "runtime" => "gemini",
          "user_id" => attacker.id,
          "environment_id" => victim_env.id
        })
        |> Repo.insert()

      sandbox = insert_sandbox(user_id: attacker.id, status: "pending")

      conv =
        insert_conversation(
          user_id: attacker.id,
          agent: agent,
          sandbox_id: sandbox.id,
          status: "pending"
        )

      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Fountain.Conversations.Provisioning, :restore_checkpoint, fn _s, id ->
        send(test_pid, {:restore_checkpoint, id})
        {:ok, :restored}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {pid, _ref, :alive} = start_server(conv)

          # The victim's checkpoint must never be restored into the
          # attacker's sprite; the conversation still provisions, just
          # without the foreign environment.
          refute_received {:restore_checkpoint, _}
          assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
          GenServer.stop(pid)
        end)

      assert log =~ "not owned by user #{attacker.id}"
    end
  end

  describe "stage metrics — the producer end of #310" do
    # These drive the real server and read the Prometheus scrape before and
    # after. The reporter is node-global and cumulative and other tests in
    # this file emit the very same events, so "a sample exists" is satisfied
    # before these tests even run (#406) — only the delta across this test's
    # own action is evidence the action emitted.
    defp scrape_body do
      # The reporter aggregates synchronously on the telemetry event, but give
      # the handler a moment before scraping.
      Process.sleep(50)
      conn = FountainWeb.MetricsPlug.call(Plug.Test.conn(:get, "/metrics"), [])
      assert conn.status == 200
      conn.resp_body
    end

    # Current value of the {stage, status} counter series, 0 when absent.
    # stage and status are the metric's only tags, so at most one line matches.
    defp stage_count(body, stage, status) do
      body
      |> String.split("\n")
      |> Enum.find_value(0, fn line ->
        if String.starts_with?(line, "fountain_stage_count{") and
             line =~ ~s(stage="#{stage}") and line =~ ~s(status="#{status}") do
          {value, ""} = line |> String.split(" ") |> List.last() |> Integer.parse()
          value
        end
      end)
    end

    # Total observations recorded by a histogram (its _count line), 0 when absent.
    defp histogram_count(body, prefix) do
      body
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.starts_with?(line, prefix) and line =~ "_count"
      end)
      |> Enum.map(fn line ->
        {value, ""} = line |> String.split(" ") |> List.last() |> Integer.parse()
        value
      end)
      |> Enum.sum()
    end

    test "a successful provision lands in the scrape as provision/done", %{conv: conv} do
      stub_happy_sprite()
      before_body = scrape_body()

      {pid, _ref, :alive} = start_server(conv)
      GenServer.stop(pid)

      after_body = scrape_body()

      # Exactly this provision — and a *successful* one: done moved, failed
      # did not.
      assert stage_count(after_body, "provision", "done") ==
               stage_count(before_body, "provision", "done") + 1

      assert stage_count(after_body, "provision", "failed") ==
               stage_count(before_body, "provision", "failed")

      # The span around fresh provisioning feeds the duration histogram.
      assert histogram_count(after_body, "fountain_fresh_provision_stop_duration") ==
               histogram_count(before_body, "fountain_fresh_provision_stop_duration") + 1
    end

    test "a failed provision lands in the scrape as provision/failed", %{conv: conv} do
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts ->
        {:error, :quota_exceeded}
      end)

      before_body = scrape_body()

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      after_body = scrape_body()

      assert stage_count(after_body, "provision", "failed") ==
               stage_count(before_body, "provision", "failed") + 1

      assert stage_count(after_body, "provision", "done") ==
               stage_count(before_body, "provision", "done")
    end

    test "a completed turn lands in the scrape as turn/done", %{conv: conv} do
      stub_happy_sprite()
      cmd_ref = make_ref()

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: cmd_ref}}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _cmd, _data -> :ok end)
      Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _cmd -> :ok end)

      before_body = scrape_body()

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "count me")
      send(pid, {:exit, %{ref: cmd_ref}, 0})
      _ = :sys.get_state(pid)
      GenServer.stop(pid)

      after_body = scrape_body()

      assert stage_count(after_body, "turn", "done") ==
               stage_count(before_body, "turn", "done") + 1
    end
  end

  describe "provisioning — warm start from a checkpoint (#989)" do
    test "the network policy is applied on the warm arm, not skipped with the disk steps", %{
      user: user
    } do
      # A checkpoint captures the disk, so packages, clones and the setup
      # script legitimately do not re-run. An egress policy is configuration on
      # the sandbox, and a warm start creates a *new* sandbox — skipping it
      # turned a `limited` environment into an unrestricted one and still
      # reported `provision/done`.
      stub_happy_sprite()
      test_pid = self()

      env =
        insert_env(
          user_id: user.id,
          networking_type: "limited",
          networking_config: %{"allowed_hosts" => ["github.com"]},
          checkpoint_id: "ckpt-1"
        )

      agent = insert_agent(user_id: user.id, environment_id: env.id, runtime: "claude")
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          runtime: @legacy_runtime,
          sandbox_id: sandbox.id,
          status: "pending"
        )

      # The harness stubs a restore failure by default, which falls through to
      # the cold path; this test is about the warm one.
      Mimic.stub(Fountain.Conversations.Provisioning, :restore_checkpoint, fn _h, _id -> :ok end)

      Mimic.stub(Fountain.Conversations.Provisioning, :apply_network_policy, fn _h, e, _c ->
        send(test_pid, {:network_policy, e.networking_type})
        :ok
      end)

      # The disk steps stay skipped: that part of the warm start is correct.
      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
        send(test_pid, :packages)
        :ok
      end)

      {pid, _ref, :alive} = start_server(conv)

      assert_received {:network_policy, "limited"}
      refute_received :packages
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
      GenServer.stop(pid)
    end
  end

  describe "provisioning — failure paths" do
    test "a sprite that cannot be created marks both rows failed", %{conv: conv, sandbox: sandbox} do
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts ->
        {:error, :quota_exceeded}
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "a failing provisioning step destroys the sprite rather than leaking it", %{conv: conv} do
      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
        {:error, :apt_failed}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
        send(test_pid, {:destroyed, handle.name})
        :ok
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      # The sprite is billed until it is destroyed, so a failed provision that
      # leaves it running costs money indefinitely.
      assert_received {:destroyed, "test-sprite"}
    end

    test "a runtime that fails to prepare marks the sandbox failed", %{
      conv: conv,
      sandbox: sandbox
    } do
      stub_happy_sprite()

      {_pid, ref, _} = start_server(conv, runtime: Managoat.Runtimes.Testing.FailingRuntime)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
    end

    test "a runtime whose config cannot be written marks the sandbox failed", %{
      conv: conv,
      sandbox: sandbox
    } do
      # Used to be `_ =` in the provision `with`: a config-write error was
      # meant to be non-fatal, but the runtime crashed on it instead, and had
      # it not, the agent would have run without its MCP servers under a
      # `provision/done`. Now it is a step like any other.
      stub_happy_sprite()

      {_pid, ref, _} = start_server(conv, runtime: Managoat.Runtimes.Testing.ConfigFailingRuntime)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "an unexpected exception is caught and does not leave the sandbox pending", %{
      conv: conv,
      sandbox: sandbox
    } do
      # The provision path wraps itself in a rescue precisely so a bug in any
      # step cannot strand a conversation in `pending` forever.
      stub_happy_sprite()

      Mimic.stub(Fountain.SandboxSkills, :mount, fn _s, _r, _sk ->
        raise "boom"
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "a limited environment on a backend that cannot enforce it fails before any sandbox exists",
         %{user: user} do
      # `Managoat.Runner.Adapter` does not advertise `:network_policy`, so this
      # pairing could only ever fail. It used to fail several steps into
      # provisioning, after a sandbox had been created and torn down, wearing
      # the shape of a transport error. Now it is refused up front, by name
      # (#935).
      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Managoat.Sandbox.Sprites, :create, fn name, _opts ->
        send(test_pid, {:created, name})
        {:ok, Managoat.Sandbox.Sprites.build_handle(name)}
      end)

      limited =
        insert_env(user_id: user.id, networking_type: "limited", networking_config: %{})

      agent = insert_agent(user_id: user.id, environment_id: limited.id, runtime: "claude")
      sandbox = insert_sandbox(user_id: user.id, status: "pending", provider: "runner")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          runtime: @legacy_runtime,
          sandbox_id: sandbox.id,
          status: "pending"
        )

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"

      # Nothing was provisioned, so there is nothing to bill or to leak.
      refute_received {:created, _}

      events =
        Fountain.Repo.all(
          from(e in Fountain.Conversations.LogEvent,
            where: e.conversation_id == ^conv.id and e.kind == "stage" and e.stage == "network"
          )
        )

      assert [%{state: "failed"} = event] = events
      assert Jason.decode!(event.data)["reason"] == "backend_lacks_network_policy"
    end

    test "unreadable tenant credentials fail the conversation rather than provisioning blind", %{
      conv: conv,
      sandbox: sandbox
    } do
      stub_happy_sprite()
      Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _ -> {:error, :unwrap_failed} end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
    end
  end

  describe "reattach — failure paths (#799)" do
    # A `ready` sandbox routes the server down the reattach branch: probe the
    # sprite, then re-arm. Only a definitive not-found may retire the row —
    # on 2026-08-18 a 70 s DNS outage during a Horde failover ran this path
    # for nine live sandboxes at once, every probe answered nxdomain, and the
    # old error arm marked all nine `failed`, which is what the reaper's
    # destroy pass keys on.
    setup %{sandbox: sandbox, conv: conv} do
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      {:ok, conv} = Conversations.update_conversation(conv, %{status: "idle"})
      {:ok, sandbox: sandbox, conv: conv}
    end

    defp reattach_stage(conv_id) do
      conv_id
      |> Conversations._unsafe_list_log_events()
      |> Enum.find(&(&1.kind == "stage" and &1.stage == "reattach" and &1.state == "failed"))
    end

    test "a transient probe failure leaves the sandbox row untouched", %{
      conv: conv,
      sandbox: sandbox
    } do
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:error, {:unavailable, %Req.TransportError{reason: :nxdomain}}}
      end)

      # The whole point: the disk is still there, so nothing may route it to
      # the reaper's destroy pass.
      Mimic.reject(&Managoat.Sandbox.Sprites.destroy/1)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)

      reloaded = Conversations._unsafe_get_sandbox!(sandbox.id)
      assert reloaded.status == "ready"
      assert is_nil(reloaded.terminated_at)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      # The operator can still see it happened, and that it will be retried.
      assert %{data: data} = reattach_stage(conv.id)
      assert %{"retryable" => true, "reason" => reason} = Jason.decode!(data)
      assert reason =~ "nxdomain"
    end

    test "a 5xx from the provider is transient too", %{conv: conv, sandbox: sandbox} do
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:error, {:unavailable, {:http, 503, %{}}}}
      end)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
    end

    test "a reattach that never reaches the sprite announces nothing", %{conv: conv} do
      # #971: a Horde child is stopped and started by cluster churn, and every
      # rebalance re-enters this path. Announcing on the way in wrote 51
      # `started` events for one conversation in one second — fifty of them
      # describing a process that was replaced before it touched anything.
      # The provider round trip outlives a rebalance, so a start that will be
      # replaced is replaced before the announcement.
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:error, {:unavailable, %Req.TransportError{reason: :nxdomain}}}
      end)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)

      stages =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "reattach"))

      # The failure is announced; the arrival is not.
      assert Enum.map(stages, & &1.state) == ["failed"]
    end

    test "a reattach that reaches the sprite says which node it is on", %{conv: conv} do
      # The other half of #971: with the node stamped, a redistribution storm
      # (many nodes, one conversation) is one query away from a crash loop
      # (one node, restarting), rather than a guess.
      stub_happy_sprite()

      {pid, _ref, _} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      started =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.find(&(&1.kind == "stage" and &1.stage == "reattach" and &1.state == "started"))

      assert %{"node" => node_name, "sprite_name" => _} = Jason.decode!(started.data)
      assert node_name == to_string(node())
    end

    test "a definitive not-found retires the sandbox so the next prompt provisions fresh", %{
      conv: conv,
      sandbox: sandbox
    } do
      stub_happy_sprite()
      Mimic.stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:error, :not_found} end)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)

      reloaded = Conversations._unsafe_get_sandbox!(sandbox.id)
      assert reloaded.status == "failed"
      refute is_nil(reloaded.terminated_at)
      # The conversation itself is not failed — the user can still prompt it.
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      assert %{data: data} = reattach_stage(conv.id)
      assert %{"retryable" => false, "reason" => "not_found"} = Jason.decode!(data)
    end
  end

  describe "turn lifecycle on a running server" do
    defp start_with_turn(conv) do
      stub_happy_sprite()
      ref = make_ref()

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _cmd, _data -> :ok end)
      Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _cmd -> :ok end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "first")
      {pid, ref}
    end

    # The `turn`/`failed` stage event's meta, decoded. Stage events persist
    # their meta as JSON in `data`.
    defp turn_failed_meta(conv_id) do
      conv_id
      |> Conversations._unsafe_list_log_events()
      |> Enum.find(&(&1.kind == "stage" and &1.stage == "turn" and &1.state == "failed"))
      |> then(& &1.data)
      |> Jason.decode!()
    end

    test "a completed command closes the turn and returns the conversation to idle", %{conv: conv} do
      {pid, ref} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "completed"
      assert turn.exit_code == 0
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "the first turn generates a title — except on a teammate's conversation (#807)",
         %{conv: conv, user: user, agent: agent} do
      test = self()

      Mimic.stub(Fountain.Conversations.TitleGenerator, :generate, fn prompt, _creds ->
        send(test, {:title_requested, prompt})
        {:ok, "A Generated Summary"}
      end)

      # An ordinary conversation: the sidebar gets a title.
      {pid, ref} = start_with_turn(conv)
      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)
      assert_receive {:title_requested, "first"}, 1_000
      GenServer.stop(pid)

      # A teammate's conversation: its title is the teammate's name, so no
      # summary is generated over it.
      team_sandbox = insert_sandbox(user_id: user.id, status: "pending")

      team_conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          sandbox_id: team_sandbox.id,
          status: "pending",
          channel_id: Fountain.Team.channel(),
          title: "Ada"
        )

      {pid, ref} = start_with_turn(team_conv)
      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)
      refute_receive {:title_requested, _}, 300
      assert Conversations._unsafe_get_conversation!(team_conv.id).title == "Ada"
      GenServer.stop(pid)
    end

    test "a non-zero exit marks the turn failed but keeps the conversation usable", %{conv: conv} do
      {pid, ref} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 1})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert turn.exit_code == 1

      # A failed turn is not a failed conversation — the user can prompt again.
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "a conversation deleted before provisioning stops the server instead of crash-looping",
         %{
           conv: conv
         } do
      # This used to raise Ecto.NoResultsError out of
      # handle_continue(:provision) — unrescued, restart: :transient, so
      # Horde restarted it straight back into the same raise, burning the
      # supervisor's SHARED restart budget until it terminated and took
      # every conversation on the node with it.
      {:ok, _} = Repo.delete(Repo.get!(Fountain.Conversations.Conversation, conv.id))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_pid, ref, settled} = start_server(conv)
          assert settled == :stopped
          assert assert_stopped(ref) == :normal
        end)

      assert log =~ "row missing before provisioning"
    end

    test "a sandbox deleted before provisioning stops the server instead of crash-looping", %{
      conv: conv,
      sandbox: sandbox
    } do
      {:ok, _} = Repo.delete(Repo.get!(Fountain.Conversations.Sandbox, sandbox.id))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_pid, ref, settled} = start_server(conv)
          assert settled == :stopped
          assert assert_stopped(ref) == :normal
        end)

      assert log =~ "row missing before provisioning"
    end

    test "a spawn that never starts returns the conversation to idle", %{conv: conv} do
      # The conversation is set to "running" just before the spawn attempt.
      # Before this reset, a failed spawn marked the turn failed but left the
      # conversation reporting "running" in the API and UI indefinitely.
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        {:error, :econnrefused}
      end)

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "hello")
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "a spawn failure after reassignment leaves the replacement binding running", %{
      conv: conv
    } do
      stub_happy_sprite()
      replacement = insert_sandbox(user_id: conv.user_id, status: "ready")

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        {:ok, _} =
          Conversations.update_conversation(conv, %{sandbox_id: replacement.id, status: "running"})

        {:error, :econnrefused}
      end)

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "hello")
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "running"
      assert turn.ended_at == nil
      assert turn.exit_code == nil
      current = Conversations._unsafe_get_conversation!(conv.id)
      assert current.sandbox_id == replacement.id
      assert current.status == "running"

      refute Repo.exists?(
               from e in Fountain.Conversations.LogEvent,
                 where:
                   e.conversation_id == ^conv.id and e.stage == "turn" and e.state == "failed"
             )

      GenServer.stop(pid)
      assert Repo.reload!(turn).status == "running"
    end

    test "a runtime that exits before the prompt is written fails the turn (#603)", %{conv: conv} do
      # The real adapter write path against a real command process that stops
      # :normal on the write, which is what Sprites.Command does the moment the
      # runtime's exit frame arrives. Nothing about this path is stubbed.
      #
      # The GenServer.call inside the SDK write used to exit THIS server, and
      # the supervisor's restart then found the sandbox already "ready", took
      # the reattach branch, and orphaned the turn behind a list_sessions error
      # that named nothing real. Against spritzer's one-shot exec that lost
      # roughly half of all turns.
      stub_happy_sprite()
      dead_on_write = spawn(fn -> receive(do: (_ -> exit(:normal))) end)

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        ref = make_ref()

        {:ok,
         %Managoat.Sandbox.Command{
           provider: :sprites,
           ref: ref,
           private: %Sprites.Command{ref: ref, pid: dead_on_write, tty_mode: false}
         }}
      end)

      # :alive is the regression: the prompt is delivered before this returns.
      {pid, _ref, :alive} = start_server(conv, initial_prompt: "hello")
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      refute is_nil(turn.ended_at)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "a runtime that exits before the prompt is written keeps its exit code (#608)", %{
      conv: conv
    } do
      # Same path as #603 above, but about what the failure *says*. A real
      # Sprites.Command sends the owner its {:stderr, ...} and {:exit, ...}
      # frames and only then stops — so by the time the write comes back
      # {:error, :command_exited}, both are already in this server's mailbox.
      #
      # current_command_ref is never assigned on this path, so every
      # handle_info guard misses them and the catch-all used to drop them
      # silently: turns.exit_code stayed NULL and the operator was told
      # ":command_exited" for an expired key, a renamed binary and an OOM
      # kill alike.
      stub_happy_sprite()
      ref = make_ref()

      # Frames first, then stop :normal — the order the library guarantees,
      # and the reason the messages beat the write's failure to the server.
      exits_1_on_write =
        spawn(fn ->
          receive do
            {:"$gen_call", {caller, _tag}, _request} ->
              send(caller, {:stderr, %{ref: ref}, "invalid api key\n"})
              send(caller, {:exit, %{ref: ref}, 1})
              exit(:normal)
          end
        end)

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        {:ok,
         %Managoat.Sandbox.Command{
           provider: :sprites,
           ref: ref,
           private: %Sprites.Command{ref: ref, pid: exits_1_on_write, tty_mode: false}
         }}
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert turn.exit_code == 1

      # The reason still leads with the mechanism — downstream gates match on
      # `:command_exited` — and now carries the cause behind it.
      assert %{"reason" => reason, "exit_code" => 1} = turn_failed_meta(conv.id)
      assert reason =~ ":command_exited"
      assert reason =~ "runtime exited 1"

      # The runtime's last words, attributed to the turn they explain.
      events = Conversations._unsafe_list_log_events(conv.id)
      assert stderr = Enum.find(events, &(&1.stream == "stderr" and &1.data =~ "invalid api key"))
      assert stderr.turn_id == turn.id

      GenServer.stop(pid)
    end

    test "stdout is persisted as log events", %{conv: conv} do
      {pid, ref} = start_with_turn(conv)

      send(pid, {:stdout, %{ref: ref}, "hello from the sprite"})
      _ = :sys.get_state(pid)

      events = Conversations._unsafe_list_log_events(conv.id)
      assert Enum.any?(events, &(&1.data =~ "hello from the sprite"))

      GenServer.stop(pid)
    end

    test "a dropped sprite WebSocket fails the turn and frees the conversation (#413)", %{
      conv: conv
    } do
      # Sprites.Command sends {:error, %{ref: ...}, reason} when the socket
      # drops mid-run, then stops. Pre-#413 the handler logged and kept
      # current_command set, so the turn stayed "running" forever, every
      # prompt got {:error, :busy}, and both reclaim paths were suppressed —
      # the sprite billed until max_lifetime.
      {pid, ref} = start_with_turn(conv)

      send(pid, {:error, %{ref: ref}, :closed})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      refute is_nil(turn.ended_at)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      # The recovery the user actually needs: prompting again works.
      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})
      assert length(Conversations._unsafe_list_turns(conv.id)) == 2

      GenServer.stop(pid)
    end

    test "a close before the exit frame fails the turn, it does not complete it", %{conv: conv} do
      # The frame this replaces. Until managoat_sandbox 0.2.0 a socket that
      # closed with no exit frame was reported as {:exit, _, 0}, so this
      # landed on the :exit handler and wrote a *completed* turn with exit
      # code 0 — a turn that never finished, recorded as a clean one, which
      # is the shape of managoat/fountain#880.
      {pid, ref} = start_with_turn(conv)

      send(pid, {:error, %{ref: ref}, :closed_before_exit})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert is_nil(turn.exit_code)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "an error for a stale command ref does not touch the current turn", %{conv: conv} do
      {pid, ref} = start_with_turn(conv)

      send(pid, {:error, %{ref: make_ref()}, :closed})
      _ = :sys.get_state(pid)

      # Still mid-turn: the running turn is untouched and busy is still busy.
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "running"
      assert {:error, :busy} = GenServer.call(pid, {:send_prompt, "second", []})

      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)
      GenServer.stop(pid)
    end

    test "prompting while a turn is running is refused rather than queued", %{conv: conv} do
      {pid, _ref} = start_with_turn(conv)

      # There is no queue, so a second prompt mid-turn must be rejected rather
      # than silently dropped or interleaved.
      assert {:error, :busy} = GenServer.call(pid, {:send_prompt, "second", []})

      GenServer.stop(pid)
    end

    test "a prompt after the turn finishes starts a new turn", %{conv: conv} do
      {pid, ref} = start_with_turn(conv)
      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)

      assert :ok = GenServer.call(pid, {:send_prompt, "second", []})
      assert length(Conversations._unsafe_list_turns(conv.id)) == 2

      GenServer.stop(pid)
    end

    test "interrupt with nothing running reports idle rather than pretending to act", %{
      conv: conv
    } do
      stub_happy_sprite()
      {pid, _mon, :alive} = start_server(conv)

      assert {:error, :idle} = GenServer.call(pid, :interrupt)
      GenServer.stop(pid)
    end
  end

  describe "secret redaction wiring" do
    test "the server registers the sprite env for redaction", %{conv: conv, env: env} do
      # The registry only protects anything if something populates it. This is
      # the assertion that would have caught Billing.emit/5 having no call
      # sites: verify from the operation, not from the helper.
      {:ok, _} =
        Fountain.Environments.upsert_secret(
          env,
          %{"key" => "LEAKY_TOKEN", "value" => "tenant-secret-cccccccccccc"},
          <<0::256>>
        )

      stub_happy_sprite()
      Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _ -> {:ok, <<0::256>>} end)

      {pid, _ref, :alive} = start_server(conv)

      values = Fountain.Conversations.Redaction.lookup(conv.id)
      assert "tenant-secret-cccccccccccc" in values

      GenServer.stop(pid)
    end

    test "registered values are forgotten when the server stops", %{conv: conv} do
      stub_happy_sprite()

      {pid, ref, :alive} = start_server(conv)
      GenServer.stop(pid)
      assert_stopped(ref)

      assert Fountain.Conversations.Redaction.lookup(conv.id) == []
    end
  end

  describe "teardown" do
    test "revokes the sprite's callback key when the server stops", %{conv: conv} do
      stub_happy_sprite()

      {pid, ref, :alive} = start_server(conv)
      key_id = Conversations._unsafe_get_conversation!(conv.id).callback_api_key_id
      refute Repo.get(Accounts.ApiKey, key_id).revoked_at

      GenServer.stop(pid)
      assert_stopped(ref)

      # Otherwise the sandbox's credential outlives the sandbox.
      assert Repo.get(Accounts.ApiKey, key_id).revoked_at
    end
  end

  describe "terminate/1 with no running server" do
    test "still marks the conversation and sandbox terminated", %{conv: conv, sandbox: sandbox} do
      # After a BEAM restart the GenServer is gone but the rows remain, and a
      # user still needs to be able to clean up.
      assert :ok = ConversationServer.terminate_conversation(conv.id)

      assert Conversations._unsafe_get_conversation!(conv.id).status == "terminated"
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "terminated"
    end

    test "reports not_running for an unknown conversation" do
      assert {:error, :not_running} =
               ConversationServer.terminate_conversation(Ecto.UUID.generate())
    end

    test "does not resurrect an already-failed sandbox", %{conv: conv, sandbox: sandbox} do
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

      assert :ok = ConversationServer.terminate_conversation(conv.id)
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
    end
  end

  describe "release_conversation/2 — end the conversation, keep the computer" do
    test "a live server stops without destroying the sprite; the rows say so",
         %{conv: conv, sandbox: sandbox} do
      stub_happy_sprite()
      test = self()
      Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> send(test, :destroyed) && :ok end)

      {pid, ref, :alive} = start_server(conv)
      key_id = Conversations._unsafe_get_conversation!(conv.id).callback_api_key_id

      # The harness's servers are outside Horde, so the client function would
      # not find this one; the call is what release_conversation/2 makes.
      assert :ok = GenServer.call(pid, :release_conv)
      assert_stopped(ref)

      refute_received :destroyed
      assert Conversations._unsafe_get_conversation!(conv.id).status == "terminated"
      # The sandbox row is untouched: ready, no terminated_at — a parked disk.
      reloaded = Conversations._unsafe_get_sandbox!(sandbox.id)
      assert reloaded.status == "ready"
      refute reloaded.terminated_at
      # The retired conversation's credential does not outlive it.
      assert Repo.get(Accounts.ApiKey, key_id).revoked_at
      # The stage event names what happened so a client can tell it from a terminate.
      assert Enum.any?(
               Conversations._unsafe_list_log_events(conv.id),
               &(&1.kind == "stage" and &1.stage == "terminate" and &1.state == "done" and
                   &1.data =~ "released")
             )
    end

    test "refuses while a turn is running and interrupts nothing", %{conv: conv, sandbox: sandbox} do
      stub_happy_sprite()
      ref = make_ref()

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _cmd, _data -> :ok end)
      Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _cmd -> :ok end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "first")

      assert {:error, :busy} = GenServer.call(pid, :release_conv)
      assert Process.alive?(pid)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "running"
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
      assert [%{status: "running"}] = Conversations._unsafe_list_turns(conv.id)

      GenServer.stop(pid)
    end

    test "with no server, marks the conversation alone", %{conv: conv, sandbox: sandbox} do
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})

      assert :ok = ConversationServer.release_conversation(conv.id)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "terminated"
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"

      assert {:error, :not_running} =
               ConversationServer.release_conversation(Ecto.UUID.generate())
    end

    test "terminating the retired conversation later leaves its successor's sandbox alone",
         %{conv: conv, sandbox: sandbox, user: user, agent: agent} do
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      assert :ok = ConversationServer.release_conversation(conv.id)

      successor =
        insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      # A terminate (or a delete, which cascades through it) of the old thread.
      assert :ok = ConversationServer.terminate_conversation(conv.id)
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"

      # Once the successor is past resuming too, the sandbox goes with it.
      {:ok, _} = Conversations.update_conversation(successor, %{status: "terminated"})
      assert :ok = ConversationServer.terminate_conversation(conv.id)
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "terminated"
    end
  end

  describe "interrupt/1 and send_prompt/3 with no running server" do
    test "interrupt reports not_running", %{conv: conv} do
      assert {:error, :not_running} = ConversationServer.interrupt(conv.id)
    end

    # The two misses are different answers (#1179). A conversation that exists
    # but has nothing running is a conflict; only a missing row is a 404, and
    # conflating them is what left `interrupt` telling an owner their own
    # conversation belonged to someone else.
    test "interrupt for an unknown conversation reports not_found" do
      assert {:error, :not_found} = ConversationServer.interrupt(Ecto.UUID.generate())
    end

    test "interrupt of a terminated conversation reports not_running, not not_found", %{
      conv: conv
    } do
      {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})

      assert {:error, :not_running} = ConversationServer.interrupt(conv.id)
    end

    test "send_prompt for an unknown conversation reports not_running" do
      assert {:error, :not_running} =
               ConversationServer.send_prompt(Ecto.UUID.generate(), "hi", [])
    end

    test "send_prompt to a terminated conversation reports gone", %{conv: conv} do
      {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})

      assert {:error, :gone} = ConversationServer.send_prompt(conv.id, "hi", [])
    end
  end

  describe "interrupt/1 against a dead server holding a running turn (#1179)" do
    # An autonomous turn ("background task follow-up") — or any turn — can be
    # left `status: "running"` in the DB with no ConversationServer left to
    # answer for it: the process exited (deploy, rebalance, a plain
    # `{:stop, :normal, _}` return) without closing the turn first, and
    # nothing wakes the conversation again until the next prompt. Before this
    # fix, `interrupt/2` only ever checked `whereis/1` and gave up with
    # `{:error, :not_running}` — indistinguishable, from the API, to a caller
    # hitting a conversation that plain does not exist. The fix mirrors
    # `send_prompt/4`'s existing wake-on-miss fallback: reattach, which
    # either resumes the real session or (as here, with no active sprite
    # session) reconciles the orphaned turn.
    test "wakes the conversation; reattach finds no live session and reconciles the stuck turn" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      conv =
        insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "running")

      {:ok, turn} =
        Conversations._unsafe_create_turn(%{
          conversation_id: conv.id,
          turn_number: 1,
          prompt: "(background task follow-up)",
          origin: "autonomous",
          status: "running",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      stub_happy_sprite()

      on_exit(fn ->
        case ConversationServer.whereis(conv.id) do
          nil -> :ok
          pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        end
      end)

      # No server is registered for this conversation at all — exactly the
      # state a dead process leaves behind. `list_sessions` (stubbed to `[]`
      # by stub_happy_sprite/1) means reattach finds nothing to resume.
      assert {:error, :idle} = ConversationServer.interrupt(conv.id)

      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      assert [%{id: turn_id, status: "interrupted"}] = Conversations._unsafe_list_turns(conv.id)
      assert turn_id == turn.id
    end
  end
end
