defmodule Managoat.Sandbox.E2B.Api do
  @moduledoc """
  E2B control-plane client (`api.e2b.app`): sandbox lifecycle, listing,
  pause/resume, TTL and network policy.

  E2B assigns sandbox ids — there are no user-chosen names — so Fountain's
  name-keyed identity is emulated through the `metadata` map: every sandbox
  is created with `fountain_name` set, and lookups filter on it server-side.
  A create/create race can therefore yield a duplicate, which the reaper's
  reconciliation converges (the same way it converges any leak).

  Errors come back in the raw `{:api_error, status, body}` shape;
  `Managoat.Sandbox.E2B` normalizes them into the taxonomy.

  Times are seconds. A running E2B sandbox always has a TTL — there is no
  unbounded state — so the adapter keeps live sandboxes alive with explicit
  `set_timeout/2` heartbeats and creates with `autoPause: true`, making a
  missed heartbeat degrade to a pause (state preserved) rather than a kill.
  """

  @initial_ttl_s 1800

  @doc "TTL granted at create and on every heartbeat."
  def initial_ttl_s, do: @initial_ttl_s

  def req do
    Req.new(
      [
        base_url: base_url(),
        headers: [{"x-api-key", api_key!()}],
        receive_timeout: Managoat.Sandbox.Config.get(Managoat.Sandbox.E2B, :timeout_ms, 30_000)
      ] ++ Managoat.Sandbox.Config.get(Managoat.Sandbox.E2B, :req_options, [])
    )
  end

  def base_url,
    do: Managoat.Sandbox.Config.get(Managoat.Sandbox.E2B, :base_url, "https://api.e2b.app")

  def api_key! do
    Managoat.Sandbox.Config.get(Managoat.Sandbox.E2B, :api_key) ||
      raise "E2B_API_KEY is not set — cannot talk to e2b.dev"
  end

  @doc "The template new sandboxes are created from (must carry the agent CLIs)."
  def template do
    Managoat.Sandbox.Config.get(Managoat.Sandbox.E2B, :template, "base")
  end

  @doc "Create a sandbox stamped with the fountain name. Returns the raw body."
  def create_sandbox(name) do
    body = %{
      templateID: template(),
      timeout: @initial_ttl_s,
      autoPause: true,
      # envd then takes requests only with the sandbox's access token, which
      # `get_sandbox/1` hands back; without it anyone who learns the id can
      # drive the sandbox. Some servers (loam) only make secure sandboxes.
      secure: true,
      metadata: %{fountain_name: name, fountain: "1"}
    }

    case Req.post(req(), url: "/sandboxes", json: body) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Find the sandbox carrying `fountain_name`, across running AND paused —
  omitting the paused state would make every suspended sandbox look gone.
  Returns `{:ok, info | nil}`.
  """
  def find_by_name(name) do
    params = [state: "running,paused", metadata: URI.encode_query(%{fountain_name: name})]

    case Req.get(req(), url: "/v2/sandboxes", params: params) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_list(body) ->
        {:ok, List.first(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete_sandbox(id) do
    case Req.delete(req(), url: "/sandboxes/#{id}") do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def pause(id) do
    case Req.post(req(), url: "/sandboxes/#{id}/pause", json: %{}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      # Already paused reads as success; pausing is idempotent intent.
      {:ok, %{status: 409}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The sandbox's detail, `GET /sandboxes/{id}`: for a running secure sandbox
  it carries `envdAccessToken`. Returns the raw body.
  """
  def get_sandbox(id) do
    case Req.get(req(), url: "/sandboxes/#{id}") do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Resume a paused sandbox (and extend its TTL) in one call."
  def connect(id) do
    case Req.post(req(), url: "/sandboxes/#{id}/connect", json: %{timeout: @initial_ttl_s}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reset the sandbox's TTL to `seconds` from now (the turn heartbeat)."
  def set_timeout(id, seconds \\ @initial_ttl_s) do
    case Req.post(req(), url: "/sandboxes/#{id}/timeout", json: %{timeout: seconds}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every fountain-stamped sandbox name on the account, running and paused,
  paginated via the `X-Next-Token` response header. Refuses a partial view.
  """
  def list_all_names(max_pages \\ 40) do
    collect_names(nil, MapSet.new(), 0, max_pages)
  end

  defp collect_names(_token, _acc, page, max_pages) when page >= max_pages do
    {:error, :truncated}
  end

  defp collect_names(token, acc, page, max_pages) do
    params =
      [state: "running,paused", metadata: URI.encode_query(%{fountain: "1"}), limit: 100] ++
        if token, do: [nextToken: token], else: []

    case Req.get(req(), url: "/v2/sandboxes", params: params) do
      {:ok, %{status: status, body: body} = resp} when status in 200..299 and is_list(body) ->
        acc =
          Enum.reduce(body, acc, fn sandbox, set ->
            case get_in(sandbox, ["metadata", "fountain_name"]) do
              name when is_binary(name) -> MapSet.put(set, name)
              _ -> set
            end
          end)

        case Req.Response.get_header(resp, "x-next-token") do
          [next | _] when next != "" -> collect_names(next, acc, page + 1, max_pages)
          _ -> {:ok, acc}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Replace the sandbox's egress policy. `allow: []` compiles to deny-all —
  E2B's `denyOut 0.0.0.0/0` plus an allowlist is genuinely default-deny, so
  no fail-open translation is needed; the deny rule is always present.
  """
  def set_network(id, allow_domains) do
    body = %{denyOut: ["0.0.0.0/0"], allowOut: allow_domains}

    case Req.put(req(), url: "/sandboxes/#{id}/network", json: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
