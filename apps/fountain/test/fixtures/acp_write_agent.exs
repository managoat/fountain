# A deterministic ACP agent that tries to write a file (#2533).
#
# It stands in for Claude Code at the adapter boundary, as a real program run
# from the argv Fountain spawned, so a read-only turn is tested through the
# wrapper, env and policy file a real adapter would start under. It does what
# Claude Code does with the parts of a managed policy a read-only turn uses:
#
#   * `CLAUDE_CODE_MANAGED_SETTINGS_PATH` names a directory whose
#     `managed-settings.json` is read at startup; a tool in `permissions.deny`
#     is refused inside the agent, and the refusal is the tool's result.
#   * any other write asks the client with `session/request_permission`
#     (kind `edit`) and writes only on an allow.
#
# A prompt `write <path>` attempts the write. `ignore-policy` makes it skip
# the managed policy, so the client's own answer is all that stands in the way.
# `FIXTURE_CRASH_ONCE_MARKER` in its env makes the first process exit 139
# (SIGSEGV) before writing a byte.
#
# Session memory lives under `$HOME`, keyed by session id, so a turn resumed
# in a new process knows the prompts before it: the answer says how many.

defmodule FixtureWriteAgent do
  def run do
    crash_once()
    policy = managed_policy()

    loop(%{policy: policy, session: nil, prompt_id: nil, pending: nil})
  end

  defp loop(state) do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        state = line |> String.trim() |> dispatch(state)
        loop(state)

      _eof_or_error ->
        :ok
    end
  end

  # Dies of SIGSEGV before writing a byte, once per marker file.
  defp crash_once do
    case System.get_env("FIXTURE_CRASH_ONCE_MARKER") do
      marker when is_binary(marker) and marker != "" ->
        unless File.exists?(marker) do
          File.write!(marker, "crashed")
          System.halt(139)
        end

      _ ->
        :ok
    end
  end

  defp managed_policy do
    with dir when is_binary(dir) <- System.get_env("CLAUDE_CODE_MANAGED_SETTINGS_PATH"),
         {:ok, json} <- File.read(Path.join(dir, "managed-settings.json")) do
      :json.decode(json)
    else
      _ -> %{}
    end
  end

  defp dispatch("", state), do: state

  defp dispatch(line, state) do
    case :json.decode(line) do
      %{"method" => method, "id" => id, "params" => params} -> request(method, id, params, state)
      %{"id" => id, "result" => result} -> answer(id, result, state)
      _other -> state
    end
  end

  defp request("initialize", id, _params, state) do
    reply(id, %{
      "protocolVersion" => 1,
      "agentCapabilities" => %{
        "loadSession" => false,
        "sessionCapabilities" => %{"resume" => %{}}
      }
    })

    state
  end

  # Sessions advertise `models`, so the client pins its model with
  # `session/set_model`, as it does on a real adapter.
  @models %{"currentModelId" => "default", "availableModels" => []}

  defp request("session/new", id, _params, state) do
    reply(id, %{"sessionId" => "fixture-write-session", "models" => @models})
    %{state | session: "fixture-write-session"}
  end

  defp request("session/resume", id, %{"sessionId" => session}, state) do
    reply(id, %{"models" => @models})
    %{state | session: session}
  end

  defp request("session/set_model", id, _params, state) do
    reply(id, %{})
    state
  end

  defp request("session/prompt", id, params, state) do
    text = prompt_text(params)
    earlier = remember(state.session, text)
    state = %{state | prompt_id: id}

    words = String.split(text)
    path = words |> Enum.drop_while(&(&1 != "write")) |> Enum.at(1)
    attempt_write(state, path, "ignore-policy" in words, earlier)
  end

  defp request(_method, _id, _params, state), do: state

  defp attempt_write(state, nil, _ignore?, earlier),
    do: finish(state, "nothing to write; context: #{earlier} earlier prompts")

  defp attempt_write(state, path, ignore?, earlier) do
    update(state, %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "write",
      "title" => "Write #{path}",
      "kind" => "edit",
      "status" => "pending"
    })

    denied = get_in(state.policy, ["permissions", "deny"]) || []

    if "Write" in denied and not ignore? do
      failed(state, "Permission to use Write has been denied.")
      finish(state, "could not write: denied by policy; context: #{earlier} earlier prompts")
    else
      write(%{
        "jsonrpc" => "2.0",
        "id" => 900,
        "method" => "session/request_permission",
        "params" => %{
          "sessionId" => state.session,
          "toolCall" => %{"toolCallId" => "write", "title" => "Write #{path}", "kind" => "edit"},
          "options" => [
            %{"optionId" => "always", "name" => "Always", "kind" => "allow_always"},
            %{"optionId" => "once", "name" => "Once", "kind" => "allow_once"},
            %{"optionId" => "no", "name" => "No", "kind" => "reject_once"}
          ]
        }
      })

      %{state | pending: {path, earlier}}
    end
  end

  defp answer(900, %{"outcome" => %{"optionId" => option}}, %{pending: {path, earlier}} = state)
       when option in ["always", "once"] do
    File.write!(path, "written")

    update(state, %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "write",
      "status" => "completed"
    })

    finish(%{state | pending: nil}, "wrote #{path}; context: #{earlier} earlier prompts")
  end

  defp answer(900, _refused, %{pending: {_path, earlier}} = state) do
    failed(state, "The user refused this tool call.")

    finish(
      %{state | pending: nil},
      "could not write: refused; context: #{earlier} earlier prompts"
    )
  end

  defp answer(_id, _result, state), do: state

  defp failed(state, why) do
    update(state, %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "write",
      "status" => "failed",
      "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => why}}]
    })
  end

  defp finish(state, message) do
    update(state, %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => message}
    })

    reply(state.prompt_id, %{"stopReason" => "end_turn"})
    state
  end

  defp prompt_text(%{"prompt" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join(" ", & &1["text"])
  end

  defp prompt_text(_params), do: ""

  # How many prompts this session had before this one, then this one recorded.
  defp remember(session, text) do
    dir = Path.join(System.fetch_env!("HOME"), ".fixture-sessions")
    File.mkdir_p!(dir)
    file = Path.join(dir, session || "none")

    earlier =
      if File.exists?(file), do: file |> File.read!() |> String.split("\n", trim: true), else: []

    File.write!(file, text <> "\n", [:append])
    length(earlier)
  end

  defp update(state, payload) do
    write(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => state.session, "update" => payload}
    })
  end

  defp reply(nil, _result), do: :ok
  defp reply(id, result), do: write(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp write(message), do: IO.puts(:json.encode(message))
end

FixtureWriteAgent.run()
