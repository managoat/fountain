defmodule Managoat.ACP.Protocol do
  @moduledoc """
  Framing and JSON-RPC 2.0 encoding for the Agent Client Protocol.

  Pure functions only — no process, no I/O. The peer owns the socket; this
  module owns the bytes, which is the part worth testing exhaustively and the
  part that has nothing to do with sprites.

  ACP is newline-delimited JSON over stdio. A transport hands the peer bytes
  in arbitrary chunks that respect no message boundary at all: one chunk can carry
  three messages and half of a fourth, and the other half arrives later. So
  framing has to carry a buffer across calls — `feed/2` returns the messages it
  could complete plus whatever tail it could not, and the caller hands that tail
  back on the next chunk.

  ## Why the decode failure is a value and not a raise

  A line that is not JSON is not an exception, it is an *event*: adapters print
  warnings, npm prints deprecation notices, and a Node process writes its stack
  trace to stdout when it dies. `feed/2` returns `{:invalid, line}` for those so
  the peer can log them as ordinary output rather than crashing a turn on
  somebody else's diagnostic.
  """

  @jsonrpc "2.0"
  @protocol_version 1

  @typedoc "A framed message, already classified."
  @type message ::
          {:response, id :: term(), result :: map()}
          | {:error_response, id :: term(), error :: map()}
          | {:request, id :: term(), method :: String.t(), params :: map()}
          | {:notification, method :: String.t(), params :: map()}
          | {:invalid, line :: String.t()}

  @doc """
  Frame `data` against a carried `buffer`, returning complete messages and the
  new buffer.

  The tail after the last newline is *always* incomplete by definition — a
  message is only whole once its newline has arrived — so it goes back into the
  buffer even when it happens to be valid JSON.
  """
  @spec feed(binary(), binary()) :: {[message()], binary()}
  def feed(buffer, data) when is_binary(buffer) and is_binary(data) do
    parts = String.split(buffer <> data, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)

    messages =
      complete
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(&classify_line/1)

    {messages, rest}
  end

  @doc """
  Classify one already-framed line.

  Exposed for a render path that reads stored lines back and has no buffer
  to carry.
  """
  @spec classify_line(String.t()) :: message()
  def classify_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} when is_map(decoded) -> classify(decoded)
      _ -> {:invalid, line}
    end
  end

  # `sessionUpdate` kinds that describe the *session* rather than anything the
  # agent did: the generated title, the slash-command list, the current mode.
  @metadata_updates ~w(session_info_update available_commands_update current_mode_update)

  @doc """
  Whether this line is a `session/update` carrying session metadata rather
  than agent activity.

  The claude adapter generates the session title asynchronously and writes the
  `session_info_update` about a second *after* the prompt response — out of
  turn. Metadata is nothing the agent said or ran, so it must not be read as
  "the agent is talking out of turn": it opens no autonomous turn and holds
  none open (#1300). Exposed for an owner that classifies the peer's reported
  lines.
  """
  @spec session_metadata?(String.t()) :: boolean()
  def session_metadata?(line) when is_binary(line) do
    case classify_line(line) do
      {:notification, "session/update", params} ->
        update = Map.get(params, "update") || %{}
        Map.get(update, "sessionUpdate") in @metadata_updates

      _ ->
        false
    end
  end

  @doc "Classify a decoded JSON-RPC object."
  @spec classify(map()) :: message()
  def classify(%{"id" => id, "result" => result}), do: {:response, id, result}
  def classify(%{"id" => id, "error" => error}), do: {:error_response, id, error}

  def classify(%{"id" => id, "method" => method} = msg),
    do: {:request, id, method, Map.get(msg, "params") || %{}}

  def classify(%{"method" => method} = msg),
    do: {:notification, method, Map.get(msg, "params") || %{}}

  def classify(other), do: {:invalid, Jason.encode!(other)}

  @doc "Encode an outbound request. Returns the line, newline included."
  @spec request(term(), String.t(), map()) :: iodata()
  def request(id, method, params) do
    line(%{jsonrpc: @jsonrpc, id: id, method: method, params: params})
  end

  @doc "Encode an outbound notification (no id, no reply expected)."
  @spec notification(String.t(), map()) :: iodata()
  def notification(method, params) do
    line(%{jsonrpc: @jsonrpc, method: method, params: params})
  end

  @doc "Encode a successful reply to an agent→client request."
  @spec response(term(), map()) :: iodata()
  def response(id, result) do
    line(%{jsonrpc: @jsonrpc, id: id, result: result})
  end

  @doc """
  Encode an error reply.

  `-32601` (method not found) is the one gate 2 sends: we declare no client
  filesystem or terminal capabilities, so an adapter calling `fs/*` or
  `terminal/*` is asking for something we told it we do not have. Answering is
  still mandatory — an unanswered request blocks the agent, and a blocked agent
  is a sprite billing until the lifetime ceiling.
  """
  @spec error(term(), integer(), String.t()) :: iodata()
  def error(id, code, message) do
    line(%{jsonrpc: @jsonrpc, id: id, error: %{code: code, message: message}})
  end

  @doc "JSON-RPC's method-not-found code."
  @spec method_not_found() :: integer()
  def method_not_found, do: -32_601

  @doc """
  The client capabilities the peer declares unless told otherwise: no
  services, and boolean session config options.

  `fs/*` and `terminal/*` are client-implemented, and a client that declares
  them has to service them against wherever the agent is running. Declaring
  nothing means a well-behaved adapter never asks; the peer still answers
  anything that arrives with `method_not_found/0`, because an unanswered
  request blocks the agent.

  `session.configOptions.boolean` asks for nothing to be serviced. It lets an
  agent advertise an on/off option as `type: "boolean"` instead of an
  `on`/`off` select, which the peer's `:config` sends with the `type` the
  protocol requires beside the value. In the pinned adapters
  (claude-agent-acp 0.81.2, codex-acp 1.10.0) it changes the shape of the fast
  mode option and nothing else.
  """
  @spec default_client_capabilities() :: map()
  def default_client_capabilities do
    %{
      fs: %{readTextFile: false, writeTextFile: false},
      terminal: false,
      session: %{configOptions: %{boolean: %{}}}
    }
  end

  @doc """
  The `initialize` params for `client_capabilities`.

  `protocolVersion` is `#{@protocol_version}`, the current version at
  [agentclientprotocol.com](https://agentclientprotocol.com/protocol/initialization);
  the spec bumps it only for breaking changes, and new capabilities are not
  breaking. The peer sends this on `handle_continue(:initialize)` with the
  capabilities its owner passed (`default_client_capabilities/0` by default).
  """
  @spec initialize_params(map()) :: map()
  def initialize_params(client_capabilities) when is_map(client_capabilities) do
    %{protocolVersion: @protocol_version, clientCapabilities: client_capabilities}
  end

  defp line(map), do: [Jason.encode_to_iodata!(map), "\n"]
end
