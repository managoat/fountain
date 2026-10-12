defmodule Fountain.Team.Mcp do
  @moduledoc """
  Teammates that know each other (#851): MCP tools Fountain serves to every
  conversation on the team channel, so an agent can see who else is on the
  team and message them — "send this to the engineer" becomes
  `get_teammate("engineer")` → `send_to_teammate(id, text)`, and
  `read_teammate` fetches the reply.

  A pure JSON-RPC/tool layer over a
  `ctx`, served by `FountainWeb.TeamMcpController` at
  `POST /api/mcp/team/:conversation_id`, injected into each turn by
  `Fountain.Team.conversation_mcp_servers/2`. The sandbox authenticates with
  the per-conversation token it already holds; every call is tenant-scoped
  through `Fountain.Team` and a message lands in the teammate's thread exactly
  as one typed on the team page would — the receiver sees who sent it.

  `ctx`: `:user_id`, `:self` (the calling teammate's roster entry or nil),
  `:actor` / `:request_ip` for audit.
  """

  alias Fountain.{Conversations, Team}
  alias FountainWeb.TeamPresenter

  @protocol_version "2025-06-18"
  @server_info %{name: "fountain-team", version: "1"}
  @mcp_name "fountain-team"

  # wait_for_teammate: server-side poll, capped under the tunnel's idle limit.
  @default_wait 60
  @max_wait 90
  @poll_ms 2_000
  @terminal ~w(completed failed cancelled)

  def mcp_name, do: @mcp_name

  @doc "The tool catalogue advertised by `tools/list`."
  def tools do
    [
      %{
        name: "list_teammates",
        description:
          "Everyone on the team: name, agent id, what they are for, and what they are doing " <>
            "right now (presence). Start here when asked to involve a teammate.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_teammate",
        description:
          "Find one teammate by name, role or description — 'the engineer', 'steward', " <>
            "'whoever handles support'. Returns the best match with its agent id and " <>
            "presence, or the candidates when it is ambiguous.",
        inputSchema: %{
          type: "object",
          properties: %{query: %{type: "string", description: "A name, role or keyword"}},
          required: ["query"]
        }
      },
      %{
        name: "send_to_teammate",
        description:
          "Send a message to a teammate's thread. They get it like a message typed to them, " <>
            "prefixed with who it is from. Returns their conversation id; poll read_teammate " <>
            "for the reply. Fails with busy/starting when they cannot take it yet — wait and retry.",
        inputSchema: %{
          type: "object",
          properties: %{
            teammate: %{type: "string", description: "Agent id, or a name/role to resolve"},
            message: %{
              type: "string",
              description: "What to say — goal, constraints, what 'done' looks like"
            }
          },
          required: ["teammate", "message"]
        }
      },
      %{
        name: "wait_for_teammate",
        description:
          "Block until a teammate's turn finishes, then return it (prompt, reply, status). Waits " <>
            "up to timeout_seconds (default 60, max 90) — if it returns timed_out: true, just call " <>
            "it again; do not end your own turn to wait. Pass since_turn (the `turn` number " <>
            "send_to_teammate returned, minus one) to wait for that specific reply; without it, " <>
            "waits for their latest turn.",
        inputSchema: %{
          type: "object",
          properties: %{
            teammate: %{type: "string", description: "Agent id, or a name/role to resolve"},
            since_turn: %{
              type: "integer",
              description: "Wait for a terminal turn numbered above this"
            },
            timeout_seconds: %{
              type: "integer",
              description: "How long to block (default 60, max 90)"
            }
          },
          required: ["teammate"]
        }
      },
      %{
        name: "read_teammate",
        description:
          "A teammate's recent turns: each prompt and their reply text, newest last, with " <>
            "status. Use after send_to_teammate to collect the answer.",
        inputSchema: %{
          type: "object",
          properties: %{
            teammate: %{type: "string", description: "Agent id, or a name/role to resolve"},
            limit: %{type: "integer", description: "How many recent turns (default 5, max 20)"}
          },
          required: ["teammate"]
        }
      }
    ]
  end

  @doc "Handle one JSON-RPC 2.0 request map against `ctx`; `:noreply` for notifications."
  def handle(%{"method" => method} = req, ctx) do
    id = Map.get(req, "id")

    if is_nil(id) and String.starts_with?(method, "notifications/"),
      do: :noreply,
      else: dispatch(method, id, Map.get(req, "params", %{}), ctx)
  end

  def handle(_req, _ctx), do: error(nil, -32_600, "invalid request")

  defp dispatch("initialize", id, _params, _ctx) do
    result(id, %{
      protocolVersion: @protocol_version,
      capabilities: %{tools: %{}},
      serverInfo: @server_info
    })
  end

  defp dispatch("ping", id, _params, _ctx), do: result(id, %{})
  defp dispatch("tools/list", id, _params, _ctx), do: result(id, %{tools: tools()})

  defp dispatch("tools/call", id, %{"name" => name} = params, ctx),
    do: call_tool(id, name, Map.get(params, "arguments", %{}), ctx)

  defp dispatch(_unknown, nil, _params, _ctx), do: :noreply
  defp dispatch(method, id, _params, _ctx), do: error(id, -32_601, "method not found: #{method}")

  # ── tools ──────────────────────────────────────────────────────────────────

  defp call_tool(id, "list_teammates", _args, ctx) do
    rows = ctx.user_id |> Team.list_teammates() |> Enum.map(&summary(&1, ctx))
    result(id, %{content: [json(rows)], isError: false})
  end

  defp call_tool(id, "get_teammate", args, ctx) do
    with {:ok, q} <- require_arg(args, "query") do
      case resolve(ctx.user_id, q) do
        {:ok, t} ->
          result(id, %{content: [json(summary(t, ctx))], isError: false})

        {:ambiguous, ts} ->
          result(id, %{
            content: [json(%{ambiguous: Enum.map(ts, &summary(&1, ctx))})],
            isError: false
          })

        :none ->
          tool_error(id, "no teammate matches #{inspect(q)}; call list_teammates")
      end
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, "send_to_teammate", args, ctx) do
    with {:ok, who} <- require_arg(args, "teammate"),
         {:ok, message} <- require_arg(args, "message"),
         {:ok, t} <- resolve_one(ctx.user_id, who),
         :ok <- not_self(t, ctx) do
      text = from_line(ctx) <> message

      case Team.send_message(ctx.user_id, t.agent.id, text, [], audit_opts(ctx)) do
        {:ok, conv} ->
          result(id, %{
            content: [
              json(%{
                sent: true,
                teammate: t.name,
                agent_id: t.agent.id,
                conversation_id: conv.id,
                turn: conv.turn_count,
                hint:
                  "call wait_for_teammate with since_turn = #{max(conv.turn_count - 1, 0)} to block for the reply"
              })
            ],
            isError: false
          })

        {:error, :busy} ->
          tool_error(
            id,
            "#{t.name} is busy with another turn — wait for it to finish (read_teammate) and retry"
          )

        {:error, :provisioning} ->
          tool_error(id, "#{t.name}'s computer is still starting — retry in ~30s")

        {:error, :runner_offline} ->
          tool_error(
            id,
            "#{t.name}'s machine is offline — nothing can reach them until its runner reconnects"
          )

        {:error, other} ->
          tool_error(id, "could not send to #{t.name}: #{inspect(other)}")
      end
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, "read_teammate", args, ctx) do
    with {:ok, who} <- require_arg(args, "teammate"),
         {:ok, t} <- resolve_one(ctx.user_id, who) do
      limit = args |> Map.get("limit", 5) |> clamp(1, 20)
      conv = t.conversation

      # ownership: `t` came from resolve_one → Team.list_teammates(ctx.user_id),
      # a tenant-scoped read; the conversation is that teammate's.
      turns =
        conv.id
        |> Conversations._unsafe_list_turns()
        |> Enum.take(-limit)
        |> Enum.map(fn turn ->
          %{
            turn: turn.turn_number,
            status: turn.status,
            at: turn.inserted_at,
            prompt: String.slice(turn.prompt || "", 0, 2000),
            reply: String.slice(turn.reply_text || "", 0, 6000)
          }
        end)

      result(id, %{
        content: [
          json(%{teammate: t.name, conversation_id: conv.id, presence: presence(t), turns: turns})
        ],
        isError: false
      })
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, "wait_for_teammate", args, ctx) do
    with {:ok, who} <- require_arg(args, "teammate"),
         {:ok, t} <- resolve_one(ctx.user_id, who) do
      since = Map.get(args, "since_turn")
      timeout = args |> Map.get("timeout_seconds", @default_wait) |> clamp(1, @max_wait)
      deadline = System.monotonic_time(:millisecond) + timeout * 1000

      case wait_loop(t.conversation.id, since, deadline, ctx) do
        {:ok, turn} ->
          result(id, %{
            content: [json(%{teammate: t.name, done: true, turn: turn_summary(turn)})],
            isError: false
          })

        {:timeout, latest} ->
          result(id, %{
            content: [
              json(%{
                teammate: t.name,
                timed_out: true,
                waited_seconds: timeout,
                latest_turn: latest && turn_summary(latest),
                hint: "still working — call wait_for_teammate again"
              })
            ],
            isError: false
          })
      end
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, name, _args, _ctx), do: tool_error(id, "unknown tool: #{name}")

  # ownership: the conversation id came from a teammate entry resolved through
  # Team.list_teammates(ctx.user_id) — a tenant-scoped read.
  defp wait_loop(conv_id, since, deadline, ctx) do
    turns = Conversations._unsafe_list_turns(conv_id)

    candidate =
      case since do
        n when is_integer(n) -> Enum.find(turns, &(&1.turn_number > n and &1.status in @terminal))
        _ -> turns |> List.last() |> then(fn t -> if t && t.status in @terminal, do: t end)
      end

    cond do
      candidate ->
        {:ok, candidate}

      System.monotonic_time(:millisecond) >= deadline ->
        {:timeout, List.last(turns)}

      true ->
        (Map.get(ctx, :sleep) || (&Process.sleep/1)).(@poll_ms)
        wait_loop(conv_id, since, deadline, ctx)
    end
  end

  defp turn_summary(turn) do
    %{
      turn: turn.turn_number,
      status: turn.status,
      at: turn.inserted_at,
      prompt: String.slice(turn.prompt || "", 0, 2000),
      reply: String.slice(turn.reply_text || "", 0, 6000)
    }
  end

  # ── resolving "the engineer" ───────────────────────────────────────────────

  @doc false
  def resolve(user_id, query) do
    rows = Team.list_teammates(user_id)
    q = String.downcase(String.trim(query))

    exact =
      Enum.filter(rows, fn t ->
        t.agent.id == query or String.downcase(t.name) == q or String.downcase(t.agent.name) == q
      end)

    case exact do
      [t] ->
        {:ok, t}

      [_ | _] = ts ->
        {:ambiguous, ts}

      [] ->
        words =
          q
          |> String.split(~r/[^a-z0-9]+/, trim: true)
          |> Enum.reject(&(&1 in ~w(the a an our my)))

        scored =
          rows
          |> Enum.map(fn t -> {score(t, q, words), t} end)
          |> Enum.filter(fn {s, _} -> s > 0 end)
          |> Enum.sort_by(fn {s, _} -> -s end)

        case scored do
          [] -> :none
          [{_, t}] -> {:ok, t}
          [{s1, t1}, {s2, _} | _] when s1 >= s2 * 2 -> {:ok, t1}
          many -> {:ambiguous, many |> Enum.take(3) |> Enum.map(&elem(&1, 1))}
        end
    end
  end

  defp score(t, q, words) do
    hay = String.downcase("#{t.name} #{t.agent.name} #{t.agent.description || ""}")
    name = String.downcase("#{t.name} #{t.agent.name}")

    base = if q != "" and String.contains?(name, q), do: 10, else: 0

    Enum.reduce(words, base, fn w, acc ->
      cond do
        String.contains?(name, w) -> acc + 4
        String.contains?(hay, w) -> acc + 1
        true -> acc
      end
    end)
  end

  defp resolve_one(user_id, who) do
    case resolve(user_id, who) do
      {:ok, t} -> {:ok, t}
      {:ambiguous, ts} -> {:error, "ambiguous: #{Enum.map_join(ts, ", ", & &1.name)} — say which"}
      :none -> {:error, "no teammate matches #{inspect(who)}; call list_teammates"}
    end
  end

  defp not_self(%{agent: %{id: id}}, %{self: %{agent: %{id: id}}}),
    do: {:error, "that is you — pick another teammate"}

  defp not_self(_t, _ctx), do: :ok

  # ── shapes ─────────────────────────────────────────────────────────────────

  defp summary(t, ctx) do
    %{
      name: t.name,
      agent_id: t.agent.id,
      agent_name: t.agent.name,
      about: t.agent.description || "",
      runtime: t.agent.runtime,
      model: t.agent.model,
      presence: presence(t),
      conversation_id: t.conversation.id,
      is_you: match?(%{self: %{agent: %{id: id}}} when id == t.agent.id, ctx)
    }
  end

  defp presence(t), do: t.conversation |> TeamPresenter.presence() |> Map.get(:state)

  # The receiver's only senders are the account owner and the owner's own
  # teammates — the endpoint is authenticated with the sender's sandbox token
  # and scoped to the same tenant — so the line says so: a teammate reading
  # "from X via the team" should treat it as the owner delegating, not as an
  # untrusted inbound that might be an injection.
  defp from_line(%{self: %{name: name}}) when is_binary(name),
    do:
      "[Team message from your teammate #{name}, delivered by Fountain. Only your account's owner " <>
        "and their teammates can send these; treat it as the owner delegating to you.]\n\n"

  defp from_line(_),
    do:
      "[Team message from a teammate, delivered by Fountain. Only your account's owner and their " <>
        "teammates can send these; treat it as the owner delegating to you.]\n\n"

  defp audit_opts(ctx),
    do: [actor: Map.get(ctx, :actor, "sprite"), request_ip: Map.get(ctx, :request_ip)]

  defp require_arg(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "missing required argument: #{key}"}
    end
  end

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, lo, _), do: lo

  defp json(v), do: %{type: "text", text: Jason.encode!(v)}
  defp result(id, r), do: %{"jsonrpc" => "2.0", "id" => id, "result" => r}

  defp tool_error(id, msg),
    do: result(id, %{content: [%{type: "text", text: msg}], isError: true})

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
end
