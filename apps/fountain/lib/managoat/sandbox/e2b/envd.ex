defmodule Managoat.Sandbox.E2B.Envd do
  @moduledoc """
  E2B data-plane client: "envd", the daemon inside every sandbox, reachable
  at `https://49983-{sandboxId}.{domain}`.

  envd speaks the [Connect protocol](https://connectrpc.com/docs/protocol)
  with the JSON codec — no gRPC and no HTTP/2 required:

    * unary calls are plain `application/json` POSTs to
      `/process.Process/<Method>`;
    * server-streaming calls use `application/connect+json`, where both
      directions carry 5-byte envelopes — one flag byte, a 4-byte big-endian
      length, then a JSON message. Flag `0x02` marks the EndStreamResponse
      (trailers / error).

  Protobuf `bytes` fields ride base64 in the JSON codec — stdin payloads out,
  stdout/stderr data in. Files use envd's plain HTTP API (`POST /files`
  multipart, parents auto-created; `GET /files` to read).
  """

  @port 49_983

  defmodule Target do
    @moduledoc """
    A sandbox as envd is reached: its id and, when the sandbox was created
    `secure`, envd's access token. Inspect shows only the id, so a token in a
    process's state never reaches a crash report.
    """
    @derive {Inspect, only: [:id]}
    @enforce_keys [:id]
    defstruct [:id, :token]

    @type t :: %__MODULE__{id: String.t(), token: String.t() | nil}
  end

  @typedoc "A sandbox id, or a `Target` carrying envd's access token."
  @type target :: String.t() | Target.t()

  @doc "The sandbox id of a target."
  @spec id_of(target()) :: String.t()
  def id_of(%Target{id: id}), do: id
  def id_of(id) when is_binary(id), do: id

  # The in-guest user envd runs commands as (and reads/writes files as) —
  # selected per request via Basic auth. The fountain template creates
  # `sprite` (the layout the provisioning pipeline assumes); the stock E2B
  # base template uses `user`.
  defp user, do: Managoat.Sandbox.Config.get(Managoat.Sandbox.E2B, :user, "sprite")

  def host(target) do
    sandbox_id = id_of(target)
    base = Managoat.Sandbox.E2B.Api.base_url()
    %URI{host: api_host, scheme: scheme} = URI.parse(base)
    domain = String.replace_prefix(api_host, "api.", "")
    "#{scheme}://#{@port}-#{sandbox_id}.#{domain}"
  end

  def req(target) do
    Req.new(
      [
        base_url: host(target),
        headers:
          [
            {"authorization", "Basic " <> Base.encode64("#{user()}:")},
            {"keepalive-ping-interval", "50"}
          ] ++ access_token(target),
        receive_timeout: Managoat.Sandbox.Config.get(Managoat.Sandbox.E2B, :timeout_ms, 30_000)
      ] ++ Managoat.Sandbox.Config.get(Managoat.Sandbox.E2B, :req_options, [])
    )
  end

  @doc """
  Content type for streaming Connect calls. `application/connect+json` on
  the wire; overridable because test plugs run `Plug.Parsers`, which
  chokes on the binary envelope behind any `+json` type.
  """
  def stream_content_type do
    Managoat.Sandbox.Config.get(
      Managoat.Sandbox.E2B,
      :stream_content_type,
      "application/connect+json"
    )
  end

  # A secure sandbox's envd refuses a request without its token (hosted E2B
  # answers 401, as does loam, where every sandbox is secure).
  defp access_token(%Target{token: token}) when is_binary(token) and token != "",
    do: [{"x-access-token", token}]

  defp access_token(_target), do: []

  # ── unary process calls ────────────────────────────────────────────────────

  @doc "Write stdin bytes to the process selected by `process` (a tag, or `{:pid, pid}`)."
  #
  # `process` is a tag, or `{:pid, pid}`. A paused-and-resumed sandbox's envd
  # still lists its processes by tag but answers 404 to a tag selector, while
  # a pid selector reaches them (observed 2026-10-04), so a caller that knows
  # the pid addresses the process by it.
  def send_input(sandbox_id, process, data) do
    payload = %{
      process: selector(process),
      input: %{stdin: Base.encode64(IO.iodata_to_binary(data))}
    }

    unary(sandbox_id, "process.Process/SendInput", payload)
  end

  @doc "Send stdin EOF to the process selected by `process` (a tag, or `{:pid, pid}`)."
  def close_stdin(sandbox_id, process) do
    unary(sandbox_id, "process.Process/CloseStdin", %{process: selector(process)})
  end

  @doc "The pid envd lists for the process tagged `tag`, if it lists one."
  def pid_for_tag(sandbox_id, tag) do
    with {:ok, processes} <- list_processes(sandbox_id) do
      case Enum.find(processes, &(&1["tag"] == tag)) do
        %{"pid" => pid} when is_integer(pid) -> {:ok, pid}
        _ -> {:error, :not_found}
      end
    end
  end

  defp selector({:pid, pid}), do: %{pid: pid}
  defp selector(tag) when is_binary(tag), do: %{tag: tag}

  @doc "List the processes envd is running."
  def list_processes(sandbox_id) do
    with {:ok, body} <- unary(sandbox_id, "process.Process/List", %{}) do
      {:ok, Map.get(body, "processes", [])}
    end
  end

  defp unary(sandbox_id, path, payload) do
    case Req.post(req(sandbox_id), url: "/" <> path, json: payload) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── files ──────────────────────────────────────────────────────────────────

  def write_file(sandbox_id, path, data) do
    form = [file: {IO.iodata_to_binary(data), filename: Path.basename(path)}]

    case Req.post(req(sandbox_id),
           url: "/files",
           params: [path: path, username: user()],
           form_multipart: form
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_file(sandbox_id, path) do
    case Req.get(req(sandbox_id), url: "/files", params: [path: path, username: user()]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 404, body: _}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Connect streaming codec ────────────────────────────────────────────────

  @doc "Encode one message as a Connect envelope (flag 0)."
  def encode_frame(message) do
    json = Jason.encode!(message)
    <<0, byte_size(json)::32-big, json::binary>>
  end

  @doc """
  Pull every complete envelope out of `buffer`, returning
  `{frames, rest}` where each frame is `{:message, map}` (flag 0) or
  `{:end_stream, map}` (flag 2 — trailers/error).
  """
  def decode_frames(buffer, acc \\ [])

  def decode_frames(<<flag, len::32-big, rest::binary>> = buffer, acc) do
    case rest do
      <<json::binary-size(len), tail::binary>> ->
        frame =
          case flag do
            2 -> {:end_stream, Jason.decode!(json)}
            _ -> {:message, Jason.decode!(json)}
          end

        decode_frames(tail, [frame | acc])

      _incomplete ->
        {Enum.reverse(acc), buffer}
    end
  end

  def decode_frames(buffer, acc), do: {Enum.reverse(acc), buffer}

  @doc """
  The `Process/Start` request for a shell command, tagged so a later
  `Connect`/`SendInput` can address the process by name.
  """
  def start_request(tag, cmd, args, opts) do
    envs =
      opts
      |> Keyword.get(:env, [])
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)

    config =
      %{cmd: cmd, args: args, envs: envs}
      |> maybe_put(:cwd, Keyword.get(opts, :dir))

    %{process: config, tag: tag}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
