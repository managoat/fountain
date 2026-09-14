defmodule FountainWeb.OpenAIController do
  @moduledoc """
  A Fountain agent answering as an OpenAI-compatible model.

  `POST /v1/chat/completions` takes the chat-completions request every gateway
  (LiteLLM, Portkey, Kong, Cloudflare AI Gateway) and every base-URL chat
  client (Open WebUI, LibreChat, the `openai` SDK in any language, `curl`)
  already speaks, and answers with the completion or its `chat.completion.chunk`
  stream. `GET /v1/models` lists the tenant's agents so a model picker fills
  itself. The `model` is an agent, named by its name or its id. See
  `docs/integrations/openai-compatible.md` and ADR 0035.

  **Alpha, behind the `openai_compat` flag** (`Fountain.FeatureFlags`), off
  by default on the hosted platform: every route here is 404 for an account
  without it, in the same envelope as an unknown model, so a client cannot
  tell a closed door from a missing agent. The dialect's edges — the thread
  key rule, `reasoning_content`, the error codes — may move between releases
  while it is alpha.

  The AG-UI endpoint (`FountainWeb.AguiController`) is the template: same
  channel binding, same "only the newest user message is the prompt", same
  translation of the turn's block events. What differs is the dialect on the
  wire and, because a chat-completions request carries no thread id, where
  the binding comes from.

  ## The thread key

  Chat completions are stateless by design: the client replays the whole
  history on every call. A Fountain conversation is the opposite: the sandbox
  holds the context, and replaying the transcript into it would be wrong and
  expensive. So each request must name a thread, and the request has no field
  for one. The rule, decided in ADR 0035:

    1. `X-Fountain-Thread` header, when present. Explicit, and forwarded by
       any gateway that forwards headers.
    2. Else the request's `user` field. Every SDK exposes it and Open WebUI
       and LibreChat set it per person, so a chat client with no header
       support gets one sandbox per person per agent — the team page's model.
    3. Else `safety_identifier`, one of OpenAI's successors to the deprecated
       `user` field. LiteLLM recognizes this current body field.
    4. None → 400 naming the header. The stateless fallback (one sandbox per
       message) is the failure mode this endpoint exists to avoid, so it is
       refused rather than offered.

  The key binds as channel `openai:<key>`, namespaced like `agui:` and
  `fountain:team`. The first request on a key opens a conversation; every
  later one prompts the conversation already bound. `system` / `developer`
  messages ride along with the first prompt only.

  ## What comes back

  `text` blocks are the assistant's `content`. Everything else the turn does
  — thinking, tool use, and the lifecycle stages while a fresh sandbox
  provisions — streams as `reasoning_content` deltas, the field the clients
  that render reasoning read (DeepSeek's convention, and Open WebUI's,
  LibreChat's and LiteLLM's). A client that does not know the field ignores
  it, and the bytes keep its stall watchdog fed either way. `usage` is zeros —
  a turn is billed in seconds, not tokens, and inventing a count would be a
  lie a gateway would then aggregate.

  ## The tool bridge (#1202)

  The sandbox's own tools never come back as tool calls: they ran, and the
  result is in the text. A tool the *request* defined in `tools` is the
  opposite case — it exists only on the client — so it is served to the agent
  as one more MCP server (`Fountain.CallerTools`) and, when the agent uses
  one, the completion ends with `finish_reason: "tool_calls"` while the turn
  stays open. The next request on the thread whose newest messages are
  `role: "tool"` answers the parked calls and streams the rest of the turn; a
  `user` message while calls are pending is 409 `tool_calls_pending`. This is
  what lets a Fountain agent be the model inside a framework's tool loop.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.{Agents, CallerTools, Conversations}
  alias Fountain.Conversations.{Blocks, ConversationServer, LogEvent}
  alias FountainWeb.{Audited, FallbackController}

  tags(["Integrations"])

  plug :require_flag

  # 404, not 403: the feature is absent for this account
  # (docs/reference/feature-status.md).
  defp require_flag(conn, _opts) do
    if Fountain.FeatureFlags.enabled?(:openai_compat, conn.assigns.current_user) do
      conn
    else
      conn
      |> openai_error(
        404,
        "the OpenAI-compatible API is not enabled for this account (flag `openai_compat`)",
        "invalid_request_error",
        "openai_compat_not_enabled"
      )
      |> halt()
    end
  end

  @thread_header "x-fountain-thread"
  @owned_by "fountain"

  ## ─── OpenAPI ──────────────────────────────────────────────────────────────

  @chat_request %OpenApiSpex.Schema{
    type: :object,
    title: "ChatCompletionRequest",
    description:
      "The OpenAI chat-completions request. `model`, `messages`, `stream`, `user`, " <>
        "`safety_identifier`, `tools` and `tool_choice` are read; sampling parameters, `n`, " <>
        "`response_format` and the rest are accepted and ignored, because the thing behind " <>
        "the URL is an agent, not a model.",
    properties: %{
      model: %OpenApiSpex.Schema{
        type: :string,
        description: "A Fountain agent: its name or its id. Unknown → 404."
      },
      messages: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{type: :object},
        description:
          "The chat so far. The newest `user` message becomes the prompt (its `image_url` " <>
            "parts must be `data:` URLs); `system`/`developer` messages become the standing " <>
            "role of a new conversation and are ignored afterwards. When the newest messages " <>
            "are `role: \"tool\"`, they answer the `tool_calls` the previous completion ended " <>
            "with and the turn resumes."
      },
      tools: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{type: :object},
        description:
          "Caller-defined function tools, in OpenAI's shape. The agent sees them beside its " <>
            "own; when it calls one the completion ends with `finish_reason: \"tool_calls\"` " <>
            "and the turn waits for the `role: \"tool\"` answer on the next request."
      },
      tool_choice: %OpenApiSpex.Schema{
        type: :string,
        description:
          "`auto` (default) or `none` (register nothing for this request). `required` and a " <>
            "named tool are refused with 400: Fountain cannot force an agent's next action."
      },
      stream: %OpenApiSpex.Schema{
        type: :boolean,
        default: false,
        description:
          "`true` streams `chat.completion.chunk` events as SSE, ending with `data: [DONE]`."
      },
      user: %OpenApiSpex.Schema{
        type: :string,
        description: "The thread key when `X-Fountain-Thread` is not set."
      },
      safety_identifier: %OpenApiSpex.Schema{
        type: :string,
        description:
          "The thread key when neither `X-Fountain-Thread` nor `user` is set. " <>
            "An OpenAI safety identifier field supported by LiteLLM."
      }
    },
    required: [:model, :messages]
  }

  @chat_response %OpenApiSpex.Schema{
    type: :object,
    title: "ChatCompletion",
    properties: %{
      id: %OpenApiSpex.Schema{type: :string},
      object: %OpenApiSpex.Schema{type: :string, enum: ["chat.completion"]},
      created: %OpenApiSpex.Schema{type: :integer},
      model: %OpenApiSpex.Schema{type: :string, description: "The agent's name."},
      choices: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            index: %OpenApiSpex.Schema{type: :integer},
            message: %OpenApiSpex.Schema{
              type: :object,
              properties: %{
                role: %OpenApiSpex.Schema{type: :string, enum: ["assistant"]},
                content: %OpenApiSpex.Schema{type: :string},
                reasoning_content: %OpenApiSpex.Schema{
                  type: :string,
                  description: "Thinking, tool use and lifecycle stages, if any."
                },
                tool_calls: %OpenApiSpex.Schema{
                  type: :array,
                  items: %OpenApiSpex.Schema{type: :object},
                  description:
                    "The caller-defined tools the agent is waiting on, when " <>
                      "`finish_reason` is `tool_calls`."
                }
              }
            },
            finish_reason: %OpenApiSpex.Schema{type: :string, enum: ["stop", "tool_calls"]}
          }
        }
      },
      usage: %OpenApiSpex.Schema{
        type: :object,
        description: "Always zeros: a turn is billed in seconds, not tokens.",
        properties: %{
          prompt_tokens: %OpenApiSpex.Schema{type: :integer},
          completion_tokens: %OpenApiSpex.Schema{type: :integer},
          total_tokens: %OpenApiSpex.Schema{type: :integer}
        }
      },
      fountain: %OpenApiSpex.Schema{
        type: :object,
        description: "Where the turn ran, for a caller that wants the real API next.",
        properties: %{
          conversation_id: %OpenApiSpex.Schema{type: :string},
          turn_id: %OpenApiSpex.Schema{type: :string, nullable: true},
          thread: %OpenApiSpex.Schema{type: :string}
        }
      }
    }
  }

  @openai_error %OpenApiSpex.Schema{
    type: :object,
    title: "OpenAIError",
    properties: %{
      error: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          message: %OpenApiSpex.Schema{type: :string},
          type: %OpenApiSpex.Schema{type: :string},
          param: %OpenApiSpex.Schema{type: :string, nullable: true},
          code: %OpenApiSpex.Schema{type: :string, nullable: true}
        }
      }
    }
  }

  @model %OpenApiSpex.Schema{
    type: :object,
    title: "Model",
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, description: "The agent's name."},
      object: %OpenApiSpex.Schema{type: :string, enum: ["model"]},
      created: %OpenApiSpex.Schema{type: :integer},
      owned_by: %OpenApiSpex.Schema{type: :string},
      fountain: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          agent_id: %OpenApiSpex.Schema{type: :string},
          runtime: %OpenApiSpex.Schema{type: :string},
          model: %OpenApiSpex.Schema{type: :string, nullable: true}
        }
      }
    }
  }

  operation(:create_chat_completion,
    summary: "Chat completions, where the model is an agent (alpha)",
    description:
      "**Alpha, behind the `openai_compat` flag** — 404 with code " <>
        "`openai_compat_not_enabled` when it is off for the account.\n\n" <>
        "OpenAI's `POST /v1/chat/completions`, answered by a Fountain agent. Point any " <>
        "gateway or base-URL chat client at `/v1` with an API key as the bearer token.\n\n" <>
        "The thread is the conversation: `X-Fountain-Thread` (else `user`, else " <>
        "`safety_identifier`) binds " <>
        "to channel `openai:<key>`. The first request on a key opens a conversation, later " <>
        "ones prompt it, and only the newest user message is sent — the agent's memory " <>
        "lives in its sandbox, not in the replayed transcript. A request with none is " <>
        "refused with 400.\n\n" <>
        "`stream: true` answers with SSE `chat.completion.chunk` events (`content` for the " <>
        "reply, `reasoning_content` for thinking, tool use and provisioning stages) and " <>
        "`data: [DONE]`; a turn that fails mid-stream sends an `error` event first. " <>
        "`stream: false` blocks until the turn ends.\n\n" <>
        "**Tools.** A request's `tools` are offered to the agent beside its own. When the " <>
        "agent calls one, the completion ends with `finish_reason: \"tool_calls\"` and the " <>
        "turn stays open; send the next request on the same thread with `role: \"tool\"` " <>
        "messages that carry the results, and the rest of the turn streams. The sandbox's " <>
        "own tools never come back as tool calls.\n\n" <>
        "Errors use OpenAI's `{\"error\": {...}}` envelope: 404 for an unknown model, 402 " <>
        "with no credit, 409 with `Retry-After` while the thread is already running a turn " <>
        "(`thread_busy`) or waiting on tool results (`tool_calls_pending`).",
    parameters: [
      "x-fountain-thread": [
        in: :header,
        type: :string,
        required: false,
        description: "The thread key. Overrides `user` and `safety_identifier`."
      ]
    ],
    request_body: {"Chat-completions request", "application/json", @chat_request},
    responses: [
      unprocessable_entity: {"Saved execution policy refused", "application/json", @openai_error},
      internal_server_error: {"Internal error", "application/json", @openai_error},
      ok:
        {"The completion (or, with `stream: true`, its SSE stream)", "application/json",
         @chat_response},
      bad_request: {"No thread key, or no user message", "application/json", @openai_error},
      not_found: {"No such model (agent)", "application/json", @openai_error},
      conflict: {"The thread is running a turn; retry", "application/json", @openai_error}
    ]
  )

  operation(:list_models,
    summary: "The tenant's agents, as models (alpha)",
    description:
      "OpenAI's `GET /v1/models`, so a base-URL client's model picker fills itself. Each " <>
        "agent is a model whose `id` is the agent's name.",
    responses: [
      not_found: {"Not found", "application/json", @openai_error},
      ok:
        {"Model list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             object: %OpenApiSpex.Schema{type: :string, enum: ["list"]},
             data: %OpenApiSpex.Schema{type: :array, items: @model}
           }
         }}
    ]
  )

  operation(:show_model,
    summary: "One agent, as a model (alpha)",
    parameters: [
      model: [in: :path, type: :string, required: true, description: "Agent name or id."]
    ],
    responses: [
      ok: {"The model", "application/json", @model},
      not_found: {"No such model (agent)", "application/json", @openai_error}
    ]
  )

  ## ─── Models ───────────────────────────────────────────────────────────────

  def list_models(conn, _params) do
    user = conn.assigns.current_user
    agents = Agents.list_agents(user.id, [])
    json(conn, %{object: "list", data: Enum.map(agents, &model_json/1)})
  end

  def show_model(conn, %{"model" => model}) do
    user = conn.assigns.current_user

    case resolve_agent(model, user.id) do
      {:ok, agent} -> json(conn, model_json(agent))
      {:error, _} = err -> respond_error(conn, err)
    end
  end

  defp model_json(agent) do
    %{
      id: agent.name,
      object: "model",
      created: DateTime.to_unix(agent.inserted_at),
      owned_by: @owned_by,
      fountain: %{agent_id: agent.id, runtime: agent.runtime, model: agent.model}
    }
  end

  # The name first, because that is what `/v1/models` advertised; the id as
  # well, because a caller that already speaks the real API has one. Both are
  # tenant-scoped, and an unknown either way is the same 404.
  defp resolve_agent(model, user_id) when is_binary(model) and model != "" do
    agent =
      Agents.get_agent_by_name(model, user_id) ||
        case Ecto.UUID.cast(model) do
          {:ok, id} -> Agents.get_agent(id, user_id)
          :error -> nil
        end

    case agent do
      nil -> {:error, {:model_not_found, model}}
      agent -> {:ok, agent}
    end
  end

  defp resolve_agent(_model, _user_id), do: {:error, {:invalid_request, "model is required"}}

  ## ─── Chat completions ─────────────────────────────────────────────────────

  def create_chat_completion(conn, params) do
    user = conn.assigns.current_user
    messages = List.wrap(params["messages"])
    answers = CallerTools.tool_answers(messages)

    with {:ok, agent} <- resolve_agent(params["model"], user.id),
         {:ok, thread} <- thread_key(conn, params),
         {:ok, tools} <- caller_tools(params),
         {:ok, conv, since, turn_id, remaining} <-
           open_or_resume(conn, agent, user, thread, tools, messages, answers) do
      state = %{
        conv_id: conv.id,
        model: agent.name,
        thread: thread,
        id: "chatcmpl-" <> Ecto.UUID.generate(),
        created: System.os_time(:second),
        last_id: since,
        turn_id: turn_id,
        deadline: now_ms() + quiet_timeout_ms(),
        monitor_ref: monitor(conv.id)
      }

      case {params["stream"] == true, remaining} do
        {stream?, []} ->
          if stream?, do: stream(conn, state), else: collect(conn, state)

        # Calls still parked after this answer (the agent made several at
        # once): they were emitted before our cursor, so hand them over now.
        {true, calls} ->
          stream(conn, state, {:tool_calls, calls})

        {false, calls} ->
          json(
            conn,
            completion(state, %{content: [], reasoning: [], failure: nil, tool_calls: calls})
          )
      end
    else
      {:error, _} = err -> respond_error(conn, err)
    end
  end

  defp caller_tools(params) do
    case CallerTools.from_openai(params["tools"], params["tool_choice"]) do
      {:ok, tools} -> {:ok, tools}
      {:error, message} -> {:error, {:invalid_request, message}}
    end
  end

  # A request whose newest messages are tool answers resumes the parked turn;
  # anything else is a prompt.
  defp open_or_resume(conn, agent, user, thread, _tools, _messages, answers)
       when map_size(answers) > 0 do
    resume(conn, agent, user, thread, answers)
  end

  defp open_or_resume(conn, agent, user, thread, tools, messages, _answers) do
    with {:ok, prompt, images} <- last_user_message(messages),
         {:ok, conv, since} <- open(conn, agent, user, thread, tools, prompt, images, messages) do
      {:ok, conv, since, nil, []}
    end
  end

  ## ─── The thread key ───────────────────────────────────────────────────────

  @doc """
  The channel a thread key binds to. Namespaced because a channel id is a
  shared vocabulary and a key minted by someone else's client must not be able
  to collide with `fountain:team` or an `agui:` thread.
  """
  @spec channel_id(String.t()) :: String.t()
  def channel_id(thread), do: "openai:" <> thread

  defp thread_key(conn, params) do
    header = conn |> get_req_header(@thread_header) |> List.first()

    [header, params["user"], params["safety_identifier"]]
    |> Enum.find_value(:error, fn value ->
      case present(value) do
        {:ok, thread} -> {:ok, thread}
        :error -> nil
      end
    end)
    |> case do
      {:ok, thread} ->
        {:ok, thread}

      :error ->
        {:error,
         {:invalid_request,
          "a thread is required: set the X-Fountain-Thread header (or the `user` or " <>
            "`safety_identifier` field) to a stable key for this chat, so its turns land " <>
            "in one sandbox"}}
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp present(_value), do: :error

  ## ─── Opening the conversation ─────────────────────────────────────────────

  # Bind, prompt, and hand back the log-event id after which everything belongs
  # to this request. Subscription happens before the prompt is sent, and the
  # loop replays from `since` anyway, so no event can fall between the two.
  defp open(conn, agent, user, thread, tools, prompt, images, messages) do
    attrs = %{
      "agent_id" => agent.id,
      "user_id" => user.id,
      "channel_id" => channel_id(thread),
      "source" => "api",
      "prompt" => first_prompt(standing_role(messages), prompt),
      "images" => images,
      "caller_tools" => tools
    }

    case Conversations.start_or_resume_conversation(attrs, Audited.attribution(conn)) do
      {:ok, conv, :created} ->
        subscribe(conv.id)
        {:ok, conv, 0}

      {:ok, conv, :resumed} ->
        subscribe(conv.id)

        # Ownership: established by start_or_resume_conversation directly
        # above, which resolves the conversation scoped by user_id.
        since = Conversations._unsafe_latest_log_event_id(conv.id)

        # A prompt while the turn waits on tool results is not a new turn: the
        # client owes an answer first (#1202).
        with [] <- ConversationServer.pending_caller_calls(conv.id),
             {:ok, conv} <- Conversations.set_caller_tools(conv, tools, Audited.attribution(conn)),
             :ok <-
               ConversationServer.send_prompt(conv.id, prompt, images, Audited.attribution(conn)) do
          {:ok, conv, since}
        else
          [_ | _] = pending -> {:error, {:tool_calls_pending, Enum.map(pending, & &1.id)}}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # The tool bridge's second request (#1202): the newest messages answer the
  # calls the previous completion ended with. No conversation is opened here —
  # a thread with nothing parked has nothing to answer, and a sandbox would be
  # the wrong side effect of a stray tool message.
  defp resume(_conn, agent, user, thread, answers) do
    attrs = %{"agent_id" => agent.id, "user_id" => user.id, "channel_id" => channel_id(thread)}

    case Conversations.channel_conversation(attrs) do
      nil ->
        {:error, :no_pending_tool_calls}

      conv ->
        subscribe(conv.id)
        # Ownership: channel_conversation above resolves scoped by user_id.
        since = Conversations._unsafe_latest_log_event_id(conv.id)

        case ConversationServer.answer_caller_tools(conv.id, answers) do
          {:ok, %{turn_id: turn_id, remaining: remaining}} ->
            {:ok, conv, since, turn_id, remaining}

          {:error, _} ->
            {:error, :no_pending_tool_calls}
        end
    end
  end

  defp subscribe(conv_id), do: Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv_id}")

  # Best-effort, exactly as on the AG-UI path: no server means a conversation
  # that is idle or already finished, which the replay still covers.
  defp monitor(conv_id) do
    case ConversationServer.whereis(conv_id) do
      pid when is_pid(pid) -> Process.monitor(pid)
      _ -> nil
    end
  end

  @doc """
  The prompt a brand-new conversation opens with: the standing role, then the
  message. The client re-sends its system prompt on every call; it is of use
  on the first only, where it is what the sandbox boots knowing.
  """
  @spec first_prompt(String.t(), String.t()) :: String.t()
  def first_prompt("", prompt), do: prompt
  def first_prompt(role, prompt), do: role <> "\n\n" <> prompt

  defp standing_role(messages) do
    messages
    |> Enum.filter(&(is_map(&1) and &1["role"] in ["system", "developer"]))
    |> Enum.map(&content_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp last_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(is_map(&1) and &1["role"] == "user"))
    |> case do
      nil ->
        {:error, {:invalid_request, "messages must include a user message"}}

      message ->
        with {:ok, images} <- content_images(message),
             {:ok, text} <- non_empty(content_text(message), images) do
          {:ok, text, images}
        end
    end
  end

  # An image with no words is still a prompt; a message with neither is not.
  defp non_empty("", []),
    do: {:error, {:invalid_request, "the newest user message has no text"}}

  defp non_empty("", _images), do: {:ok, "(see the attached image)"}
  defp non_empty(text, _images), do: {:ok, text}

  defp content_text(%{"content" => content}) when is_binary(content), do: content

  defp content_text(%{"content" => parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp content_text(_), do: ""

  # `image_url` parts, as `data:` URLs only. The server does not fetch a
  # remote image on the client's behalf: that is an SSRF door, and every
  # client that attaches a file inlines it as a data URL anyway.
  defp content_images(%{"content" => parts}) when is_list(parts) do
    parts
    |> Enum.filter(&(is_map(&1) and &1["type"] == "image_url"))
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case data_url_image(get_in(part, ["image_url", "url"])) do
        {:ok, image} -> {:cont, {:ok, acc ++ [image]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, raw} -> decode_images(raw)
      {:error, _} = err -> err
    end
  end

  defp content_images(_message), do: {:ok, []}

  defp data_url_image("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [media_type, data] -> {:ok, %{"media_type" => media_type, "data" => data}}
      _ -> {:error, {:invalid_request, "image_url must be a base64 data: URL"}}
    end
  end

  defp data_url_image(_url),
    do:
      {:error,
       {:invalid_request, "image_url must be a data: URL; Fountain does not fetch remote images"}}

  defp decode_images(raw) do
    case FountainWeb.PromptImages.decode(raw) do
      {:ok, images} -> {:ok, images}
      {:error, message} -> {:error, {:invalid_request, message}}
    end
  end

  ## ─── Errors ───────────────────────────────────────────────────────────────

  # OpenAI's envelope for what this dialect owns; the rest of the context's
  # refusal vocabulary keeps FallbackController's status codes, which are
  # what a client acts on, wrapped in the same envelope so an SDK parses them.
  defp respond_error(conn, {:error, {:execution_limits_invalid, field}}),
    do:
      openai_error(
        conn,
        422,
        "Invalid execution limits: #{field}.",
        "invalid_request_error",
        "execution_limits_invalid"
      )

  defp respond_error(conn, {:error, {:execution_limits_unsupported, controls}}),
    do:
      openai_error(
        conn,
        422,
        "Execution-limit enforcement is unavailable: #{Enum.join(controls, ", ")}.",
        "invalid_request_error",
        "execution_limits_unsupported"
      )

  defp respond_error(conn, {:error, {:invalid_request, message}}),
    do: openai_error(conn, 400, message, "invalid_request_error", nil)

  defp respond_error(conn, {:error, {:model_not_found, model}}),
    do:
      openai_error(
        conn,
        404,
        "The model `#{model}` does not exist: no agent has that name or id",
        "invalid_request_error",
        "model_not_found"
      )

  defp respond_error(conn, {:error, :not_found}),
    do: openai_error(conn, 404, "no such agent", "invalid_request_error", "model_not_found")

  # The thread is mid-turn. Not a queue: a chat client retries, and the hint
  # says when.
  defp respond_error(conn, {:error, :busy}) do
    conn
    |> put_resp_header("retry-after", "5")
    |> openai_error(
      409,
      "this thread is already running a turn; wait for it to finish and send again",
      "conflict_error",
      "thread_busy"
    )
  end

  defp respond_error(conn, {:error, :no_runner_online}) do
    openai_error(
      conn,
      409,
      "this agent runs on a self-hosted runner and none of yours is connected — " <>
        "start `fountain runner` on the machine and try again",
      "conflict_error",
      "no_runner_online"
    )
  end

  defp respond_error(conn, {:error, :sandbox_at_capacity}) do
    conn
    |> put_resp_header("retry-after", "5")
    |> openai_error(
      409,
      "another conversation is running a turn on this sandbox; " <>
        "wait for it to finish or interrupt it, then send again",
      "conflict_error",
      "sandbox_at_capacity"
    )
  end

  # The thread owes tool results (#1202). Same shape as busy: the client
  # knows what to send, and it is not a prompt.
  defp respond_error(conn, {:error, {:tool_calls_pending, ids}}) do
    conn
    |> put_resp_header("retry-after", "5")
    |> openai_error(
      409,
      "this thread is waiting on tool results for #{Enum.join(ids, ", ")}; answer them " <>
        "with role: \"tool\" messages before sending a new user message",
      "conflict_error",
      "tool_calls_pending"
    )
  end

  defp respond_error(conn, {:error, :no_pending_tool_calls}),
    do:
      openai_error(
        conn,
        400,
        "the newest messages are tool results, but this thread is not waiting on any tool " <>
          "call (it may have timed out, or the turn ended); send a user message instead",
        "invalid_request_error",
        "no_pending_tool_calls"
      )

  defp respond_error(conn, {:error, :insufficient_credits}),
    do:
      openai_error(
        conn,
        402,
        "insufficient credits; add credit at /account/billing",
        "insufficient_quota",
        "insufficient_credits"
      )

  defp respond_error(conn, {:error, reason}) when is_binary(reason),
    do: openai_error(conn, 400, reason, "invalid_request_error", nil)

  defp respond_error(conn, {:error, {:sandbox_quota_exceeded, %{count: count, limit: limit}}}) do
    openai_error(
      conn,
      429,
      "You have #{count} of #{limit} concurrent sandboxes in use. " <>
        "Terminate a conversation before starting another.",
      "rate_limit_error",
      "sandbox_quota_exceeded"
    )
  end

  # Everything else — fleet, provisioning, provider refusals — keeps
  # FallbackController's own shape and status. The status is what a client
  # acts on, every OpenAI SDK surfaces an unknown body verbatim, and the long
  # tail of refusal atoms is not worth a second vocabulary to keep in step.
  defp respond_error(conn, {:error, _} = err), do: FallbackController.call(conn, err)

  defp openai_error(conn, status, message, type, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{message: message, type: type, param: nil, code: code}})
  end

  ## ─── Following the turn ───────────────────────────────────────────────────

  @default_heartbeat_ms 15_000
  @default_quiet_timeout_ms 600_000

  defp heartbeat_ms, do: Application.get_env(:fountain, :sse_heartbeat_ms, @default_heartbeat_ms)

  # How long the conversation may produce nothing before the request is
  # abandoned. Not a ceiling on the turn: any log event resets it. It is the
  # backstop for a conversation that stops existing without saying so.
  defp quiet_timeout_ms,
    do: Application.get_env(:fountain, :openai_quiet_timeout_ms, @default_quiet_timeout_ms)

  # Both modes follow the turn the same way — replay what is already written,
  # then wait on PubSub — and differ only in the sink each piece lands in.
  # Pieces are `{:content, text}`, `{:reasoning, text}`, `{:done, meta}` and
  # `{:failed, reason}`.
  defp follow(state, sink, acc) do
    case replay(state, sink, acc) do
      {:cont, state, acc} -> loop(state, sink, acc)
      halted -> halted
    end
  end

  defp replay(state, sink, acc) do
    # Ownership: the conversation was resolved scoped by user_id in open/7,
    # which is the only caller path in here.
    state.conv_id
    |> Conversations._unsafe_list_log_events(state.last_id)
    |> Enum.reduce_while({:cont, state, acc}, fn ev, {:cont, state, acc} ->
      case handle_event(%{state | last_id: ev.id}, ev, sink, acc) do
        {:cont, _, _} = next -> {:cont, next}
        halted -> {:halt, halted}
      end
    end)
  end

  defp loop(state, sink, acc) do
    case receive_next(state) do
      {:event, %LogEvent{id: id} = ev} ->
        state = %{state | last_id: id, deadline: now_ms() + quiet_timeout_ms()}

        case handle_event(state, ev, sink, acc) do
          {:cont, state, acc} -> loop(state, sink, acc)
          halted -> halted
        end

      :stale ->
        loop(state, sink, acc)

      :heartbeat ->
        case sink.(acc, :heartbeat) do
          {:ok, acc} ->
            Process.send_after(self(), :heartbeat, heartbeat_ms())
            loop(state, sink, acc)

          {:closed, acc} ->
            {:closed, state, acc}
        end

      {:server_down, reason} ->
        deliver(
          state,
          sink,
          acc,
          {:failed, "the conversation stopped running (#{inspect(reason)})"}
        )

      :quiet ->
        deliver(state, sink, acc, {:failed, "the conversation went quiet; nothing arrived"})
    end
  end

  defp receive_next(state) do
    ref = state.monitor_ref

    receive do
      {:log_event, %LogEvent{id: id} = ev} when id > state.last_id -> {:event, ev}
      {:log_event, _stale} -> :stale
      :heartbeat -> :heartbeat
      {:DOWN, ^ref, :process, _pid, reason} when is_reference(ref) -> {:server_down, reason}
    after
      max(state.deadline - now_ms(), 0) -> :quiet
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # The turn this request is waiting for: the first `started` after the cursor.
  defp handle_event(
         %{turn_id: nil} = state,
         %LogEvent{stage: "turn", state: "started"} = ev,
         _,
         acc
       ) do
    case meta(ev)["turn_id"] do
      turn_id when is_binary(turn_id) -> {:cont, %{state | turn_id: turn_id}, acc}
      _ -> {:cont, state, acc}
    end
  end

  defp handle_event(
         %{turn_id: turn_id} = state,
         %LogEvent{stage: "turn", state: state_name} = ev,
         sink,
         acc
       )
       when is_binary(turn_id) and state_name in ~w(done failed interrupted) do
    meta = meta(ev)

    cond do
      meta["turn_id"] != turn_id ->
        {:cont, state, acc}

      state_name == "failed" ->
        deliver(state, sink, acc, {:failed, meta["reason"] || "the turn failed"})

      true ->
        deliver(state, sink, acc, {:done, state_name})
    end
  end

  defp handle_event(
         %{turn_id: turn_id} = state,
         %LogEvent{kind: "output", turn_id: turn_id} = ev,
         sink,
         acc
       )
       when is_binary(turn_id) do
    ev
    |> Blocks.for_event()
    |> Enum.reduce_while({:cont, state, acc}, fn block, {:cont, state, acc} ->
      case piece(block) do
        nil -> {:cont, {:cont, state, acc}}
        piece -> deliver(state, sink, acc, piece) |> halt_unless_cont()
      end
    end)
  end

  # The agent called a caller-defined tool (#1202): the completion ends here
  # with the call, and the turn waits for the next request to answer it.
  defp handle_event(
         %{turn_id: turn_id} = state,
         %LogEvent{kind: "stage", stage: "caller_tool", state: "started"} = ev,
         sink,
         acc
       )
       when is_binary(turn_id) do
    meta = meta(ev)

    if meta["turn_id"] == turn_id do
      call = %{id: meta["call_id"], name: meta["name"], arguments: meta["arguments"]}

      with {:cont, state, acc} <-
             deliver(state, sink, acc, {:reasoning, "→ #{call.name} (waiting for the caller)\n"}) do
        deliver(state, sink, acc, {:tool_calls, [call]})
      end
    else
      {:cont, state, acc}
    end
  end

  # How a parked call ended, for a client reading the reasoning stream.
  defp handle_event(
         %{turn_id: turn_id} = state,
         %LogEvent{kind: "stage", stage: "caller_tool", state: "done"} = ev,
         sink,
         acc
       )
       when is_binary(turn_id) do
    meta = meta(ev)

    if meta["turn_id"] == turn_id and meta["outcome"] != "answered",
      do: deliver(state, sink, acc, {:reasoning, "← #{meta["name"]}: #{meta["outcome"]}\n"}),
      else: {:cont, state, acc}
  end

  # A stage that failed before any turn started — provisioning died. Nothing
  # else will arrive, so end now rather than wait out the quiet timeout.
  defp handle_event(
         %{turn_id: nil} = state,
         %LogEvent{kind: "stage", state: "failed"} = ev,
         sink,
         acc
       ) do
    reason = meta(ev)["reason"] || meta(ev)["message"] || "no reason given"
    deliver(state, sink, acc, {:failed, "#{ev.stage} failed: #{reason}"})
  end

  # Provision/setup progress is worth relaying while a first request waits for
  # its sandbox, and worth nothing after that.
  defp handle_event(%{turn_id: nil} = state, %LogEvent{kind: "stage"} = ev, sink, acc),
    do: deliver(state, sink, acc, {:reasoning, "#{ev.stage}: #{ev.state}\n"})

  defp handle_event(state, _ev, _sink, acc), do: {:cont, state, acc}

  defp halt_unless_cont({:cont, _, _} = next), do: {:cont, next}
  defp halt_unless_cont(halted), do: {:halt, halted}

  defp piece(%{kind: :text, body: body}) when is_binary(body) and body != "", do: {:content, body}

  defp piece(%{kind: :thinking, body: body}) when is_binary(body) and body != "",
    do: {:reasoning, body}

  defp piece(%{kind: :tool_use} = block),
    do: {:reasoning, "→ #{block[:name] || "tool"}#{summary(block)}\n"}

  defp piece(%{kind: :tool_result, error?: true}), do: {:reasoning, "← failed\n"}
  defp piece(%{kind: :tool_result}), do: {:reasoning, "← ok\n"}

  defp piece(%{kind: :error, body: body}) when is_binary(body) and body != "",
    do: {:reasoning, "error: #{body}\n"}

  defp piece(_block), do: nil

  defp summary(%{summary: summary}) when is_binary(summary) and summary != "", do: " #{summary}"
  defp summary(_block), do: ""

  defp meta(%LogEvent{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{}
    end
  end

  defp meta(_ev), do: %{}

  # Terminal pieces end the follow; the rest continue.
  defp deliver(state, sink, acc, {terminal, _} = piece)
       when terminal in [:done, :failed, :tool_calls] do
    case sink.(acc, piece) do
      {:ok, acc} -> {terminal, state, acc}
      {:closed, acc} -> {:closed, state, acc}
    end
  end

  defp deliver(state, sink, acc, piece) do
    case sink.(acc, piece) do
      {:ok, acc} -> {:cont, state, acc}
      {:closed, acc} -> {:closed, state, acc}
    end
  end

  ## ─── stream: false ────────────────────────────────────────────────────────

  defp collect(conn, state) do
    sink = fn
      acc, {:content, text} -> {:ok, Map.update!(acc, :content, &[&1 | text])}
      acc, {:reasoning, text} -> {:ok, Map.update!(acc, :reasoning, &[&1 | text])}
      acc, {:failed, reason} -> {:ok, Map.put(acc, :failure, reason)}
      acc, {:tool_calls, calls} -> {:ok, Map.put(acc, :tool_calls, calls)}
      acc, _other -> {:ok, acc}
    end

    case follow(state, sink, %{content: [], reasoning: [], failure: nil, tool_calls: []}) do
      {outcome, state, acc} when outcome in [:done, :tool_calls] ->
        json(conn, completion(state, acc))

      {:failed, _state, acc} ->
        openai_error(conn, 500, acc.failure, "server_error", "turn_failed")
    end
  end

  defp completion(state, acc) do
    message = %{role: "assistant", content: IO.iodata_to_binary(acc.content)}

    message =
      case IO.iodata_to_binary(acc.reasoning) do
        "" -> message
        reasoning -> Map.put(message, :reasoning_content, reasoning)
      end

    {message, finish_reason} =
      case acc.tool_calls do
        [] ->
          {message, "stop"}

        calls ->
          {Map.put(message, :tool_calls, Enum.map(calls, &CallerTools.to_openai_call/1)),
           "tool_calls"}
      end

    %{
      id: state.id,
      object: "chat.completion",
      created: state.created,
      model: state.model,
      choices: [%{index: 0, message: message, finish_reason: finish_reason}],
      usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0},
      fountain: %{conversation_id: state.conv_id, turn_id: state.turn_id, thread: state.thread}
    }
  end

  ## ─── stream: true ─────────────────────────────────────────────────────────

  # `immediate` is a terminal piece to send instead of following the turn:
  # the calls still parked after a tool answer (see create_chat_completion/2).
  defp stream(conn, state, immediate \\ nil) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    Process.send_after(self(), :heartbeat, heartbeat_ms())

    # The role chunk first, as OpenAI sends it, so a client opens the
    # assistant message before any content arrives.
    sink = fn
      conn, :heartbeat -> chunk_raw(conn, ": heartbeat\n\n")
      conn, {:content, text} -> chunk_json(conn, delta(state, %{content: text}, nil))
      conn, {:reasoning, text} -> chunk_json(conn, delta(state, %{reasoning_content: text}, nil))
      conn, {:done, _} -> finish_stream(conn, state, nil)
      conn, {:failed, reason} -> finish_stream(conn, state, reason)
      conn, {:tool_calls, calls} -> finish_with_tool_calls(conn, state, calls)
    end

    case chunk_json(conn, delta(state, %{role: "assistant", content: ""}, nil)) do
      {:ok, conn} when is_nil(immediate) ->
        {_outcome, _state, conn} = follow(state, sink, conn)
        conn

      {:ok, conn} ->
        {_, conn} = sink.(conn, immediate)
        conn

      {:closed, conn} ->
        conn
    end
  end

  defp finish_stream(conn, state, nil) do
    with {:ok, conn} <- chunk_json(conn, delta(state, %{}, "stop")),
         do: chunk_raw(conn, "data: [DONE]\n\n")
  end

  # Once the stream is open the status is spent, so a failed turn arrives the
  # way OpenAI-compatible servers send one: an `error` event, then `[DONE]`.
  defp finish_stream(conn, _state, reason) do
    with {:ok, conn} <-
           chunk_json(conn, %{
             error: %{message: reason, type: "server_error", param: nil, code: "turn_failed"}
           }),
         do: chunk_raw(conn, "data: [DONE]\n\n")
  end

  # The calls as one delta, each with its `index`, the way OpenAI streams a
  # complete call; then `finish_reason: "tool_calls"` and `[DONE]`.
  defp finish_with_tool_calls(conn, state, calls) do
    tool_calls =
      calls
      |> Enum.with_index()
      |> Enum.map(fn {call, i} -> call |> CallerTools.to_openai_call() |> Map.put(:index, i) end)

    with {:ok, conn} <- chunk_json(conn, delta(state, %{tool_calls: tool_calls}, nil)),
         {:ok, conn} <- chunk_json(conn, delta(state, %{}, "tool_calls")),
         do: chunk_raw(conn, "data: [DONE]\n\n")
  end

  defp delta(state, delta, finish_reason) do
    %{
      id: state.id,
      object: "chat.completion.chunk",
      created: state.created,
      model: state.model,
      choices: [%{index: 0, delta: delta, finish_reason: finish_reason}]
    }
  end

  defp chunk_json(conn, payload), do: chunk_raw(conn, "data: #{Jason.encode!(payload)}\n\n")

  # The client hung up. Routine, and nothing is left to say to a gone socket.
  defp chunk_raw(conn, data) do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:closed, conn}
    end
  end
end
