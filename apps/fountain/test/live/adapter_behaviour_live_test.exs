defmodule Fountain.LiveAdapter do
  @moduledoc false
  # The pinned ACP adapters (managoat_runtimes' table) driven by the pinned
  # peer (managoat_acp) in a real sandbox, the way a Fountain turn drives
  # them. A pin bump of either library, or of an adapter in the runtimes
  # table, can change what an adapter does with a permission answer, its modes
  # and its session config options without failing any stubbed test (#2670).
  # This suite is that gate; `contributing/component-libraries.md` says when
  # it must pass. From apps/fountain, with the test database migrated (the
  # application boots, though the suite writes no rows):
  #
  #     E2B_API_KEY=... E2B_BASE_URL=... ANTHROPIC_API_KEY=... OPENAI_API_KEY=... \
  #       mix test --only live_adapter test/live/adapter_behaviour_live_test.exs
  #
  # `--only runtime:claude` or `--only runtime:codex` runs one runtime. It
  # creates one billed E2B sandbox per runtime (production's `fountain`
  # template unless E2B_TEMPLATE says otherwise), destroyed when the module
  # finishes, and spends a few model turns on each key.
  #
  # Each runtime's expectations are its `expect/0` map, at the bottom, written
  # from what the pinned adapter was measured to do. A bump that changes one
  # fails here. Update the map in the same PR as the bump, along with what
  # cites the behaviour: ADR 0014's 2026-10-15 addenda, ADR 0062's, and
  # docs/concepts/permissions.md.
  #
  # The adapter is spawned the way `TurnLaunch` spawns it, policy included: a
  # policy that asks puts codex in its asking mode (`CodexApproval`, #2708).
  # So the permission checks run under a policy that asks, and the
  # "allowing policy" check under one that allows everything.

  import ExUnit.Assertions

  alias Fountain.Agents.SessionConfig
  alias Fountain.Conversations.{CodexApproval, Connection, Provisioning, TurnMachine}

  @turn_timeout 240_000

  def env!(name) do
    case System.get_env(name) do
      blank when blank in [nil, ""] -> raise "#{name} is not set; the live adapter suite needs it"
      value -> value
    end
  end

  def env(name, default) do
    case System.get_env(name) do
      blank when blank in [nil, ""] -> default
      value -> value
    end
  end

  def configure_e2b! do
    Application.put_env(:fountain, Managoat.Sandbox.E2B,
      api_key: env!("E2B_API_KEY"),
      base_url: env("E2B_BASE_URL", "https://api.e2b.app"),
      template: env("E2B_TEMPLATE", "fountain"),
      user: env("E2B_USER", "sprite"),
      timeout_ms: 60_000
    )
  end

  @prefix "fountain-live-adapter-"

  @doc """
  A sandbox for `runtime`, as provisioning leaves it: the runtime's config,
  its credentials and the pinned adapter. `credentials` maps an inference
  credential to the env var holding it; the values are read here and never
  pass through a call that could print them in a failure.
  """
  def provision!(runtime, credentials) do
    {:ok, mod} = Managoat.Runtimes.for_runtime(runtime)
    name = "#{@prefix}#{runtime}-#{System.os_time(:second)}"
    {:ok, handle} = Managoat.Sandbox.create(:e2b, name)
    ExUnit.Callbacks.on_exit(fn -> Managoat.Sandbox.destroy(handle) end)

    sprite_env =
      Managoat.Runtimes.default_env(mod, nil, Map.new(credentials, fn {k, v} -> {k, env!(v)} end))

    :ok = Provisioning.write_runtime_config(handle, mod, nil)
    :ok = Provisioning.prepare_runtime_sprite(handle, runtime, mod, nil, sprite_env, nil, nil)

    %{handle: handle, runtime: runtime, module: mod, sprite_env: sprite_env, broker: nil}
  end

  @doc """
  Spawn the adapter and start a peer on it, as `TurnLaunch` does, with the
  approval mode the policy chooses. `opts`: `:mode` (`:run` | `:continue`),
  `:session_id`, `:config`, `:policy`. Returns the connection; the first turn
  is already sent.
  """
  def open(sandbox, prompt, opts) do
    %{handle: handle, runtime: runtime} = sandbox
    {cmd, args} = Fountain.RuntimeDispatch.command(runtime, nil)
    cwd = Managoat.Sandbox.host_path(handle, Fountain.RuntimeDispatch.cwd(runtime))
    model = model(runtime)
    policy = Managoat.ACP.Permissions.effective(Keyword.get(opts, :policy), nil)
    env = CodexApproval.put_env(sandbox.sprite_env, CodexApproval.env(runtime, policy))

    {:ok, command} =
      Connection.spawn_command(sandbox, runtime, cmd, args,
        env: env ++ Managoat.Runtimes.model_env(sandbox.module, model),
        owner: self(),
        stdin: true,
        tty: false,
        dir: cwd,
        detachable: true
      )

    {peer, _mon} =
      TurnMachine.start_acp_peer(
        command,
        prompt,
        Keyword.get(opts, :mode, :run),
        Keyword.get(opts, :session_id) || Ecto.UUID.generate(),
        cwd: cwd,
        model: model,
        config: Keyword.get(opts, :config, %{}),
        permission_policy: policy
      )

    %{command: command, peer: peer, ref: command.ref, model: model}
  end

  def close(%{command: command, peer: peer}) do
    Managoat.Sandbox.close_stdin(command)
    Managoat.ACP.Peer.close(peer)
    Managoat.Sandbox.stop_command(command)
  end

  @doc "The next turn on an open connection, as `Connection.resume/7` sends it."
  def prompt(conn, prompt, config) do
    :ok = Managoat.ACP.Peer.prompt(conn.peer, prompt, [], model: conn.model, config: config)
  end

  @doc """
  Collect one turn's reports until `{:done, …}` or `{:failed, …}`. Each
  permission request is handed to `on_ask.(request_id, tool, options)`, which
  answers it. Returns `%{stop:, reports:, asks:, text:}`.
  """
  def await_turn(conn, on_ask \\ fn _id, _tool, _options -> :deny end) do
    await_turn(conn, on_ask, %{stop: nil, reports: [], asks: [], text: "", stderr: ""})
  end

  defp await_turn(%{ref: ref} = conn, on_ask, acc) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        Managoat.ACP.Peer.stdout(conn.peer, data)
        await_turn(conn, on_ask, acc)

      {:stderr, %{ref: ^ref}, data} ->
        await_turn(conn, on_ask, %{acc | stderr: acc.stderr <> data})

      {:exit, %{ref: ^ref}, code} ->
        flunk(
          "adapter exited #{code} mid-turn; stderr:\n#{String.slice(acc.stderr, -4000, 4000)}"
        )

      {:acp, ^ref, {:done, stop, _usage}} ->
        %{acc | stop: stop, reports: Enum.reverse(acc.reports)}

      {:acp, ^ref, {:failed, reason}} ->
        flunk(
          "turn failed: #{inspect(reason)}; stderr:\n#{String.slice(acc.stderr, -4000, 4000)}"
        )

      {:acp, ^ref, {:permission_ask, id, tool, options} = ask} ->
        answer(conn, id, options, on_ask.(id, tool, options))
        await_turn(conn, on_ask, %{acc | asks: [ask | acc.asks], reports: [ask | acc.reports]})

      {:acp, ^ref, {:lines, "acp", data} = report} ->
        acc = %{acc | text: acc.text <> agent_text(data), reports: [report | acc.reports]}
        await_turn(conn, on_ask, acc)

      {:acp, ^ref, report} ->
        await_turn(conn, on_ask, %{acc | reports: [report | acc.reports]})
    after
      @turn_timeout -> flunk("no end of turn in #{@turn_timeout} ms: #{inspect(acc)}")
    end
  end

  defp answer(conn, id, _options, :deny), do: Managoat.ACP.Peer.deny_permission(conn.peer, id)

  defp answer(conn, id, options, :allow_once) do
    option = Enum.find(options, &(&1["kind"] == "allow_once")) || flunk("no allow_once offered")
    :ok = Managoat.ACP.Peer.answer_permission(conn.peer, id, option["optionId"])
  end

  # The assistant's text out of a run of session/update lines.
  defp agent_text(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.map_join(fn line ->
      case Jason.decode(line) do
        {:ok,
         %{
           "params" => %{
             "update" => %{
               "sessionUpdate" => "agent_message_chunk",
               "content" => %{"text" => text}
             }
           }
         }} ->
          text

        _ ->
          ""
      end
    end)
  end

  @doc """
  What a turn did, for a failure message: how it ended, its tool calls, the
  assistant's text and the tail of the adapter's stderr. A turn that ends
  without a tool call is as often the model or its API refusing (a quota, a
  rate limit, an unknown model) as an adapter change; the text and stderr
  say which.
  """
  def describe(turn) do
    "stop: #{inspect(turn.stop)}\ntools:\n#{tools(turn)}\ntext: " <>
      inspect(String.slice(turn.text, 0, 2000)) <>
      "\nstderr:\n#{String.slice(turn.stderr, -4000, 4000)}"
  end

  @doc "The turn's tool calls and their updates, one line each, for a failure message."
  def tools(turn) do
    for {:lines, "acp", data} <- turn.reports,
        line <- String.split(data, "\n", trim: true),
        {:ok, %{"params" => %{"update" => %{"sessionUpdate" => kind} = update}}} <-
          [Jason.decode(line)],
        kind in ["tool_call", "tool_call_update"] do
      Map.take(update, ["title", "kind", "status", "rawInput", "rawOutput", "content"])
      |> inspect(printable_limit: 600, limit: 30)
    end
    |> Enum.join("\n")
  end

  def model(runtime) do
    model =
      case runtime do
        "claude" -> env("LIVE_ADAPTER_CLAUDE_MODEL", "anthropic/claude-sonnet-5")
        "codex" -> env("LIVE_ADAPTER_CODEX_MODEL", "openai/gpt-5.5")
      end

    Fountain.RuntimeDispatch.acp_model(runtime, model)
  end

  def session_id(turn) do
    Enum.find_value(turn.reports, fn
      {:session, id} -> id
      _ -> nil
    end)
  end

  @doc "The last option list the peer reported before the turn's prompt."
  def options(turn) do
    turn.reports
    |> Enum.filter(&match?({:config_options, _}, &1))
    |> List.last()
    |> case do
      {:config_options, options} -> options
      nil -> flunk("the peer reported no config options: #{inspect(turn.reports)}")
    end
  end

  def option(options, id),
    do: Enum.find(options, &(&1["id"] == id)) || flunk("no #{id} option in #{inspect(options)}")

  def values(%{"options" => options}), do: Enum.flat_map(options, &values/1)
  def values(%{"value" => value}), do: [value]
  def values(_), do: []

  def file?(sandbox, path) do
    {:ok, out, 0} =
      Managoat.Sandbox.exec(sandbox.handle, "bash", [
        "-c",
        "test -e #{path} && echo yes || echo no"
      ])

    String.trim(out) == "yes"
  end

  # ── the checks: one per test, `e` is the runtime's expect/0 map ──────────

  @doc """
  ADR 0062, addendum of 2026-10-15 (agent only): every turn of a
  conversation sends the same request, its agent's options from launch. The
  option is set on the first turn and holds on the next, where the peer finds
  it already in force. Nothing is put back between turns.
  """
  def check_held(sandbox, e) do
    id = e.effort_option
    conn = open(sandbox, "Reply with the single word ready.", config: %{})
    ExUnit.Callbacks.on_exit(fn -> close(conn) end)

    first = await_turn(conn)
    assert first.stop == "end_turn"
    baseline = option(options(first), id)["currentValue"]
    assert baseline in values(option(options(first), id))
    raised = Enum.find(values(option(options(first), id)), &(&1 != baseline))

    prompt(conn, "Reply with the single word set.", %{id => raised})
    set = await_turn(conn)
    assert set.stop == "end_turn"
    assert {:config_selected, ^id, ^raised, ^raised} = find(set, :config_selected)
    assert option(options(set), id)["currentValue"] == raised

    prompt(conn, "Reply with the single word again.", %{id => raised})
    again = await_turn(conn)
    assert again.stop == "end_turn"
    assert {:config_selected, ^id, ^raised, _} = find(again, :config_selected)
    assert option(options(again), id)["currentValue"] == raised

    IO.puts("#{e.runtime} #{id}: baseline #{inspect(baseline)}, held #{inspect(raised)}")
  end

  @doc """
  A session resumed on a new connection comes back at the adapter's default.
  Every park, wake and idle close resumes on a new one, which is why each turn
  sends its whole request rather than relying on what the session last held.
  """
  def check_resume(sandbox, e) do
    id = e.effort_option
    conn = open(sandbox, "Reply with the single word ready.", config: %{})
    first = await_turn(conn)
    baseline = option(options(first), id)["currentValue"]
    raised = Enum.find(values(option(options(first), id)), &(&1 != baseline))

    prompt(conn, "Reply with the single word set.", %{id => raised})
    set = await_turn(conn)
    assert option(options(set), id)["currentValue"] == raised
    close(conn)

    resumed =
      open(sandbox, "Reply with the single word resumed.",
        mode: :continue,
        session_id: session_id(first),
        config: %{}
      )

    ExUnit.Callbacks.on_exit(fn -> close(resumed) end)
    turn = await_turn(resumed)
    assert turn.stop == "end_turn"
    assert option(options(turn), id)["currentValue"] == baseline
  end

  @doc """
  #2675 and #2691: the harness's permission mode is not a session option.
  Fountain refuses and hides the ids in `harness_mode_ids/0`; an adapter that
  renamed its mode option would put it back in front of users. Under a
  policy that allows everything Fountain sets no mode, so the adapter's
  default is the one the turn runs in.
  """
  def check_modes(sandbox, e) do
    conn = open(sandbox, "Reply with the single word ready.", config: %{})
    ExUnit.Callbacks.on_exit(fn -> close(conn) end)
    options = options(await_turn(conn))
    harness = SessionConfig.harness_mode_ids()

    for o <- options do
      IO.puts("#{e.runtime} option #{o["id"]} (#{o["category"]}): #{inspect(o["currentValue"])}")
    end

    # Every option the adapter files under "mode" is one Fountain refuses.
    for o <- options, o["category"] == "mode", do: assert(o["id"] in harness)

    present = for o <- options, o["id"] in harness, do: o["id"]
    assert Enum.sort(present) == Enum.sort(e.mode_options)
    refute Enum.any?(SessionConfig.offered(options), &(&1["id"] in harness))
    assert option(options, "mode")["currentValue"] == e.default_mode
  end

  @doc """
  #2708: under a policy that asks, the adapter runs in `e.asking_mode`. On
  codex that is the mode whose reviewer is the client. An adapter that
  renamed it would fall back to its default without an error, so the mode it
  reports is the check.
  """
  def check_asking_mode(sandbox, e) do
    conn = open(sandbox, "Reply with the single word ready.", policy: %{"default" => "ask"})
    ExUnit.Callbacks.on_exit(fn -> close(conn) end)
    turn = await_turn(conn)
    assert turn.stop == "end_turn"
    assert option(options(turn), "mode")["currentValue"] == e.asking_mode
  end

  @doc """
  What a client's answer does, on a request that reaches the client, under a
  policy that asks. `e.asks[tool]` is where a write sends one: claude asks
  for a file edit or a shell write in the workspace, codex for either one
  outside it (in the workspace codex asks nothing). `e.reject_stop[tool]` is
  how a rejected turn ends. The same connection then takes another turn, so
  a rejection that ends a turn does not end the conversation.
  """
  def check_answer(sandbox, e, tool, answer) do
    dir = Map.fetch!(e.asks, tool)
    path = "#{dir}/live-#{tool}-#{answer}-#{System.unique_integer([:positive])}"
    prompt = %{edit: &edit_prompt/1, shell: &write_prompt/1}[tool].(path)
    conn = open(sandbox, prompt, policy: %{"default" => "ask"})
    ExUnit.Callbacks.on_exit(fn -> close(conn) end)

    turn = await_turn(conn, fn _id, _tool, _options -> answer end)
    assert turn.asks != [], "no permission request; #{describe(turn)}"

    for {:permission_ask, _id, _tool, options} <- turn.asks do
      IO.puts(
        "#{e.runtime} #{tool} #{answer}: offered " <>
          Enum.map_join(options, ", ", &"#{&1["optionId"]} (#{&1["kind"]})") <>
          "; turn #{turn.stop}"
      )
    end

    case answer do
      :deny ->
        refute file?(sandbox, path), describe(turn)
        assert turn.stop == Map.fetch!(e.reject_stop, tool), describe(turn)

      :allow_once ->
        assert file?(sandbox, path), describe(turn)
        assert turn.stop == "end_turn", describe(turn)
    end

    prompt(conn, "Reply with the single word next.", %{})
    assert await_turn(conn).stop == "end_turn"
  end

  @doc """
  ADR 0014's 2026-10-15 addenda (#2670, #2708): not every tool call asks.
  Whether a shell write in `dir` does under `policy` is the adapter's
  measured answer, `asks`, and an unasked write happens. Under a policy that
  asks, codex's sandbox refuses a write outside the workspace and codex puts
  the escalation to the client. Under one that allows everything codex keeps
  its `agent` mode, whose automatic reviewer decides without the client.
  """
  def check_write(sandbox, dir, asks, policy \\ %{"default" => "ask"}) do
    path = "#{dir}/live-write-#{System.unique_integer([:positive])}"
    conn = open(sandbox, write_prompt(path), policy: policy)
    ExUnit.Callbacks.on_exit(fn -> close(conn) end)

    turn = await_turn(conn, fn _id, _tool, _options -> :deny end)
    asked = turn.asks != []
    assert asked == asks, describe(turn)
    assert file?(sandbox, path) != asked, describe(turn)
  end

  @doc "Whether a read-only command inside the workspace asks; unasked, it runs."
  def check_read_only(sandbox, e) do
    marker = "live-marker-#{System.unique_integer([:positive])}"
    {:ok, _, 0} = Managoat.Sandbox.exec(sandbox.handle, "touch", ["/home/sprite/#{marker}"])

    conn =
      open(
        sandbox,
        "Use your shell tool to run exactly this command and nothing else: " <>
          "ls -a. Then reply with its output.",
        policy: %{"default" => "ask"}
      )

    ExUnit.Callbacks.on_exit(fn -> close(conn) end)
    turn = await_turn(conn, fn _id, _tool, _options -> :deny end)
    assert turn.stop == "end_turn", describe(turn)
    asked = turn.asks != []
    assert asked == e.read_only_asks, describe(turn)
    # Unasked, it ran: its output is in the answer.
    assert asked or turn.text =~ marker, describe(turn)
  end

  defp edit_prompt(path) do
    "Create the file #{path} containing the single word hello. Use your file editing " <>
      "tool, not the shell, and no other tool. If the edit is refused, reply with the " <>
      "word refused."
  end

  defp write_prompt(path) do
    "Use your shell tool to run exactly this command and nothing else: touch #{path}. " <>
      "Do not use any other tool. If a sandbox blocks it, request approval to run it " <>
      "outside the sandbox. If that is refused, reply with the word refused."
  end

  defp find(turn, tag), do: Enum.find(turn.reports, &(is_tuple(&1) and elem(&1, 0) == tag))
end

defmodule Fountain.LiveAdapter.Case do
  @moduledoc false
  use ExUnit.CaseTemplate

  # The using module names its runtime (`--only runtime:codex` runs one) and
  # defines `expect/0`: the credential env vars it needs and what its pinned
  # adapter was measured to do. Each test is one check in Fountain.LiveAdapter.
  using opts do
    quote do
      import Fountain.LiveAdapter

      @moduletag :live_adapter
      @moduletag runtime: unquote(Keyword.fetch!(opts, :runtime))
      @moduletag timeout: 900_000

      setup_all do
        configure_e2b!()
        %{sandbox: provision!(expect().runtime, expect().credentials)}
      end

      test(
        "the agent's session option is set once and holds on the next turn",
        %{sandbox: s},
        do: check_held(s, expect())
      )

      test("a resumed session does not carry the last turn's option", %{sandbox: s},
        do: check_resume(s, expect())
      )

      test("permission modes are named by harness_mode_ids and not offered", %{sandbox: s},
        do: check_modes(s, expect())
      )

      test("a policy that asks runs the adapter in its asking mode", %{sandbox: s},
        do: check_asking_mode(s, expect())
      )

      test("a rejected shell request does not run the command", %{sandbox: s},
        do: check_answer(s, expect(), :shell, :deny)
      )

      test("an approved shell request runs the command", %{sandbox: s},
        do: check_answer(s, expect(), :shell, :allow_once)
      )

      test("a rejected file edit request does not write the file", %{sandbox: s},
        do: check_answer(s, expect(), :edit, :deny)
      )

      test("a write inside the workspace", %{sandbox: s},
        do: check_write(s, "/home/sprite", expect().workspace_write_asks)
      )

      test("a write outside the workspace", %{sandbox: s},
        do: check_write(s, "/var/tmp", expect().outside_write_asks)
      )

      test("an allowing policy: a write outside the workspace", %{sandbox: s},
        do: check_write(s, "/var/tmp", expect().allowing_outside_write_asks, %{})
      )

      test("a read-only command inside the workspace", %{sandbox: s},
        do: check_read_only(s, expect())
      )
    end
  end
end

defmodule Fountain.LiveAdapter.ClaudeTest do
  # claude-agent-acp, the version managoat_runtimes pins.
  use Fountain.LiveAdapter.Case, async: true, runtime: "claude"

  def expect,
    do: %{
      runtime: "claude",
      credentials: [anthropic_api_key: "ANTHROPIC_API_KEY"],
      effort_option: "effort",
      mode_options: ["mode"],
      default_mode: "default",
      asking_mode: "default",
      asks: %{shell: "/home/sprite", edit: "/home/sprite"},
      reject_stop: %{shell: "end_turn", edit: "end_turn"},
      workspace_write_asks: true,
      outside_write_asks: true,
      allowing_outside_write_asks: false,
      read_only_asks: false
    }
end

defmodule Fountain.LiveAdapter.CodexTest do
  # codex-acp, the version managoat_runtimes pins.
  use Fountain.LiveAdapter.Case, async: true, runtime: "codex"

  def expect,
    do: %{
      runtime: "codex",
      credentials: [openai_api_key: "OPENAI_API_KEY"],
      effort_option: "reasoning_effort",
      mode_options: ["mode", "collaboration_mode"],
      default_mode: "agent",
      asking_mode: "read-only",
      asks: %{shell: "/var/tmp", edit: "/var/tmp"},
      reject_stop: %{shell: "cancelled", edit: "cancelled"},
      workspace_write_asks: false,
      outside_write_asks: true,
      allowing_outside_write_asks: false,
      read_only_asks: false
    }
end
