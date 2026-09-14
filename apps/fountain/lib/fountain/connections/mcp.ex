defmodule Fountain.Connections.Mcp do
  @moduledoc """
  The Gmail tools Fountain serves to a conversation whose agent names a
  Google connection (#1178). A pure JSON-RPC/tool layer over a `ctx`, the
  same shape as `Fountain.Team.Mcp`: `handle/2` takes one request map
  and returns one response map (or `:noreply` for a notification). The
  transport and the `ctx` live in `FountainWeb.GmailMcpController`.

  The access token is resolved server-side per call through
  `Fountain.Connections.access_token/1`, so a token that expired mid-session
  is refreshed on the next tool call and a revoked connection answers with
  `connection revoked` — the model sees a reason, not a 401.

  `ctx` fields:
    * `:connection` — the `%Fountain.Connections.Connection{}` the tools act for
    * `:gmail`      — the client module (default `Fountain.Connections.Gmail`)
    * `:audit`      — `fn tool, summary -> _ end`, called for every send
  """

  alias Fountain.Connections
  alias Fountain.Connections.Gmail

  @protocol_version "2025-06-18"
  @server_info %{name: "fountain-gmail", version: "1"}
  @mcp_name "gmail"

  @max_results 50

  def mcp_name, do: @mcp_name

  @doc "The tool catalogue advertised by `tools/list`."
  def tools do
    [
      %{
        name: "gmail_search",
        description:
          "Search the connected mailbox with Gmail's query syntax (`from:`, `subject:`, " <>
            "`is:unread`, `newer_than:7d`, ...). Returns threads, newest first, with " <>
            "subject, sender, date and snippet. Use gmail_get_thread for the full text.",
        inputSchema: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Gmail search query. Empty lists recent mail."},
            max_results: %{type: "integer", description: "1 to #{@max_results}, default 10"},
            page_token: %{
              type: "string",
              description: "From a previous result, for the next page"
            }
          }
        }
      },
      %{
        name: "gmail_get_thread",
        description:
          "Every message in a thread with headers and plain-text body. " <>
            "Reply with gmail_reply using the last message's id.",
        inputSchema: %{
          type: "object",
          properties: %{thread_id: %{type: "string"}},
          required: ["thread_id"]
        }
      },
      %{
        name: "gmail_get_message",
        description: "One message in full: headers, plain-text body and attachment names.",
        inputSchema: %{
          type: "object",
          properties: %{message_id: %{type: "string"}},
          required: ["message_id"]
        }
      },
      %{
        name: "gmail_send",
        description:
          "Send a new plain-text email from the connected account. " <>
            "`to`, `cc` and `bcc` are comma-separated addresses.",
        inputSchema: %{
          type: "object",
          properties: %{
            to: %{type: "string"},
            subject: %{type: "string"},
            body: %{type: "string", description: "Plain text"},
            cc: %{type: "string"},
            bcc: %{type: "string"}
          },
          required: ["to", "subject", "body"]
        }
      },
      %{
        name: "gmail_reply",
        description:
          "Reply to a message, in its thread, to its sender (reply_all: true adds the other " <>
            "recipients). Use this rather than gmail_send when answering mail.",
        inputSchema: %{
          type: "object",
          properties: %{
            message_id: %{type: "string", description: "The message to answer"},
            body: %{type: "string", description: "Plain text"},
            reply_all: %{type: "boolean"}
          },
          required: ["message_id", "body"]
        }
      },
      %{
        name: "gmail_modify_labels",
        description:
          "Add or remove labels on a message by label id (INBOX, UNREAD, STARRED, or one " <>
            "from gmail_list_labels). Archive = remove INBOX; mark read = remove UNREAD.",
        inputSchema: %{
          type: "object",
          properties: %{
            message_id: %{type: "string"},
            add: %{type: "array", items: %{type: "string"}},
            remove: %{type: "array", items: %{type: "string"}}
          },
          required: ["message_id"]
        }
      },
      %{
        name: "gmail_list_labels",
        description: "The mailbox's labels, with ids, for gmail_modify_labels.",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @doc "The instructions the server sends with `initialize`."
  def instructions(%{account_email: email}) do
    "These tools act on the Gmail mailbox of #{email}, connected by the account owner. " <>
      "Search first, read a thread before replying, and send only what the task asks for."
  end

  # ── JSON-RPC ──────────────────────────────────────────────────────────────

  def handle(%{"method" => method} = req, ctx) do
    id = Map.get(req, "id")

    if is_nil(id) and String.starts_with?(method, "notifications/") do
      :noreply
    else
      dispatch(method, id, Map.get(req, "params", %{}) || %{}, ctx)
    end
  end

  def handle(_req, _ctx), do: error(nil, -32_600, "invalid request")

  defp dispatch("initialize", id, _params, ctx) do
    result(id, %{
      protocolVersion: @protocol_version,
      capabilities: %{tools: %{}},
      serverInfo: @server_info,
      instructions: instructions(ctx.connection)
    })
  end

  defp dispatch("ping", id, _params, _ctx), do: result(id, %{})
  defp dispatch("tools/list", id, _params, _ctx), do: result(id, %{tools: tools()})

  defp dispatch("tools/call", id, %{"name" => name} = params, ctx) do
    with_token(id, ctx, fn token ->
      call_tool(id, name, Map.get(params, "arguments", %{}) || %{}, token, ctx)
    end)
  end

  defp dispatch(_unknown, nil, _params, _ctx), do: :noreply
  defp dispatch(method, id, _params, _ctx), do: error(id, -32_601, "method not found: #{method}")

  # Every tool call resolves the token afresh: a refresh happens here when
  # it is due, and a revoked connection is named before any API call.
  defp with_token(id, ctx, fun) do
    case Connections.access_token(ctx.connection) do
      {:ok, token} ->
        fun.(token)

      {:error, :revoked} ->
        tool_error(
          id,
          "connection revoked: the Google account #{ctx.connection.account_email} is no " <>
            "longer connected to Fountain. Ask the account owner to reconnect it in the console."
        )

      {:error, reason} ->
        tool_error(id, "could not get an access token for the connection: #{inspect(reason)}")
    end
  end

  # ── tools ─────────────────────────────────────────────────────────────────

  defp call_tool(id, "gmail_search", args, token, ctx) do
    opts = [
      query: blank_to_nil(args["query"]),
      max_results: clamp(args["max_results"], 1, @max_results, 10),
      page_token: blank_to_nil(args["page_token"])
    ]

    with {:ok, %{} = page} <- gmail(ctx).list_threads(token, opts) do
      threads =
        (page["threads"] || [])
        |> Enum.map(fn %{"id" => tid} ->
          case gmail(ctx).get_thread(token, tid, "metadata") do
            {:ok, thread} -> thread_summary(thread)
            _ -> %{id: tid}
          end
        end)

      ok(id, %{
        threads: threads,
        next_page_token: page["nextPageToken"],
        result_size_estimate: page["resultSizeEstimate"]
      })
    else
      {:error, reason} -> api_error(id, reason)
    end
  end

  defp call_tool(id, "gmail_get_thread", args, token, ctx) do
    with {:ok, tid} <- require_arg(args, "thread_id"),
         {:ok, thread} <- gmail(ctx).get_thread(token, tid, "full") do
      ok(id, %{
        id: thread["id"],
        messages: Enum.map(thread["messages"] || [], &message_detail/1)
      })
    else
      {:missing, key} -> tool_error(id, "missing argument: #{key}")
      {:error, reason} -> api_error(id, reason)
    end
  end

  defp call_tool(id, "gmail_get_message", args, token, ctx) do
    with {:ok, mid} <- require_arg(args, "message_id"),
         {:ok, message} <- gmail(ctx).get_message(token, mid, "full") do
      ok(id, message_detail(message))
    else
      {:missing, key} -> tool_error(id, "missing argument: #{key}")
      {:error, reason} -> api_error(id, reason)
    end
  end

  defp call_tool(id, "gmail_send", args, token, ctx) do
    with {:ok, to} <- require_arg(args, "to"),
         {:ok, subject} <- require_arg(args, "subject"),
         {:ok, body} <- require_arg(args, "body") do
      raw =
        Gmail.build_raw(
          [
            from: ctx.connection.account_email,
            to: to,
            cc: args["cc"],
            bcc: args["bcc"],
            subject: subject
          ],
          body
        )

      case gmail(ctx).send_raw(token, raw) do
        {:ok, sent} ->
          audit(ctx, "gmail_send", %{
            "recipients" => count_addresses([to, args["cc"], args["bcc"]])
          })

          ok(id, %{id: sent["id"], thread_id: sent["threadId"], sent: true})

        {:error, reason} ->
          api_error(id, reason)
      end
    else
      {:missing, key} -> tool_error(id, "missing argument: #{key}")
    end
  end

  defp call_tool(id, "gmail_reply", args, token, ctx) do
    with {:ok, mid} <- require_arg(args, "message_id"),
         {:ok, body} <- require_arg(args, "body"),
         {:ok, original} <- gmail(ctx).get_message(token, mid, "metadata") do
      headers = headers_of(original)
      me = ctx.connection.account_email
      reply_to = headers["reply-to"] || headers["from"]

      cc =
        if args["reply_all"] == true,
          do: [headers["to"], headers["cc"]] |> Enum.reject(&is_nil/1) |> Enum.join(", "),
          else: nil

      subject =
        case headers["subject"] do
          nil -> "Re:"
          "Re: " <> _ = s -> s
          s -> "Re: " <> s
        end

      raw =
        Gmail.build_raw(
          [
            from: me,
            to: reply_to,
            cc: cc,
            subject: subject,
            in_reply_to: headers["message-id"],
            references: headers["message-id"]
          ],
          body
        )

      case gmail(ctx).send_raw(token, raw, original["threadId"]) do
        {:ok, sent} ->
          audit(ctx, "gmail_reply", %{"recipients" => count_addresses([reply_to, cc])})
          ok(id, %{id: sent["id"], thread_id: sent["threadId"], sent: true})

        {:error, reason} ->
          api_error(id, reason)
      end
    else
      {:missing, key} -> tool_error(id, "missing argument: #{key}")
      {:error, reason} -> api_error(id, reason)
    end
  end

  defp call_tool(id, "gmail_modify_labels", args, token, ctx) do
    with {:ok, mid} <- require_arg(args, "message_id"),
         {:ok, message} <-
           gmail(ctx).modify_message(token, mid, list_arg(args["add"]), list_arg(args["remove"])) do
      ok(id, %{id: message["id"], label_ids: message["labelIds"] || []})
    else
      {:missing, key} -> tool_error(id, "missing argument: #{key}")
      {:error, reason} -> api_error(id, reason)
    end
  end

  defp call_tool(id, "gmail_list_labels", _args, token, ctx) do
    case gmail(ctx).list_labels(token) do
      {:ok, %{"labels" => labels}} ->
        ok(id, %{labels: Enum.map(labels, &Map.take(&1, ["id", "name", "type"]))})

      {:ok, _} ->
        ok(id, %{labels: []})

      {:error, reason} ->
        api_error(id, reason)
    end
  end

  defp call_tool(id, name, _args, _token, _ctx), do: tool_error(id, "unknown tool: #{name}")

  # ── shaping ───────────────────────────────────────────────────────────────

  defp thread_summary(thread) do
    messages = thread["messages"] || []
    last = List.last(messages) || %{}
    headers = headers_of(last)

    %{
      id: thread["id"],
      subject: headers["subject"],
      from: headers["from"],
      date: headers["date"],
      snippet: last["snippet"],
      message_count: length(messages),
      last_message_id: last["id"],
      label_ids: last["labelIds"] || []
    }
  end

  defp message_detail(message) do
    headers = headers_of(message)

    %{
      id: message["id"],
      thread_id: message["threadId"],
      from: headers["from"],
      to: headers["to"],
      cc: headers["cc"],
      subject: headers["subject"],
      date: headers["date"],
      message_id_header: headers["message-id"],
      label_ids: message["labelIds"] || [],
      snippet: message["snippet"],
      body: body_text(message["payload"]),
      attachments: attachment_names(message["payload"])
    }
  end

  defp headers_of(%{"payload" => %{"headers" => headers}}) when is_list(headers) do
    Map.new(headers, fn %{"name" => n, "value" => v} -> {String.downcase(n), v} end)
  end

  defp headers_of(_), do: %{}

  # The first text/plain part, walking multipart bodies; falls back to a
  # stripped text/html part. Attachments are named, never inlined.
  defp body_text(nil), do: nil

  defp body_text(payload) do
    parts = flatten_parts(payload)

    plain = Enum.find(parts, &(&1["mimeType"] == "text/plain" and has_data?(&1)))
    html = Enum.find(parts, &(&1["mimeType"] == "text/html" and has_data?(&1)))

    cond do
      plain -> decode_data(plain)
      html -> html |> decode_data() |> strip_html()
      true -> nil
    end
  end

  defp flatten_parts(%{"parts" => parts} = payload) when is_list(parts),
    do: [payload | Enum.flat_map(parts, &flatten_parts/1)]

  defp flatten_parts(part), do: [part]

  defp has_data?(%{"body" => %{"data" => d}}) when is_binary(d) and d != "", do: true
  defp has_data?(_), do: false

  defp decode_data(%{"body" => %{"data" => d}}) do
    case Base.url_decode64(d, padding: false) do
      {:ok, text} -> text
      :error -> ""
    end
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<(script|style)[^>]*>.*?<\/\1>/is, " ")
    |> String.replace(~r/<br\s*\/?>|<\/p>|<\/div>/i, "\n")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n\s*\n+/, "\n\n")
    |> String.trim()
  end

  defp attachment_names(nil), do: []

  defp attachment_names(payload) do
    payload
    |> flatten_parts()
    |> Enum.filter(&(is_binary(&1["filename"]) and &1["filename"] != ""))
    |> Enum.map(
      &%{filename: &1["filename"], mime_type: &1["mimeType"], size: get_in(&1, ["body", "size"])}
    )
  end

  defp count_addresses(fields) do
    fields
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> length()
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp gmail(ctx), do: Map.get(ctx, :gmail, Gmail)

  defp audit(%{audit: fun}, tool, summary) when is_function(fun, 2), do: fun.(tool, summary)
  defp audit(_ctx, _tool, _summary), do: :ok

  defp require_arg(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:missing, key}
    end
  end

  defp list_arg(v) when is_list(v), do: Enum.map(v, &to_string/1)
  defp list_arg(_), do: []

  defp blank_to_nil(v) when is_binary(v) and v != "", do: v
  defp blank_to_nil(_), do: nil

  defp clamp(n, lo, hi, _default) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, _lo, _hi, default), do: default

  defp api_error(id, :unauthorized),
    do:
      tool_error(
        id,
        "Gmail refused the access token; retry, and if it persists reconnect the account"
      )

  defp api_error(id, {:http, status, message}),
    do: tool_error(id, "Gmail API error #{status}: #{message}")

  defp api_error(id, reason), do: tool_error(id, "Gmail request failed: #{inspect(reason)}")

  defp ok(id, payload), do: result(id, %{content: [text(Jason.encode!(payload))], isError: false})
  defp text(t), do: %{type: "text", text: t}
  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  # A tool-level failure is a successful JSON-RPC response carrying isError,
  # per MCP: the model sees it and can recover.
  defp tool_error(id, message), do: result(id, %{content: [text(message)], isError: true})
end
