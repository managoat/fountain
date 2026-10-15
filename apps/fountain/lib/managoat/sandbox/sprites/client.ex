defmodule Managoat.Sandbox.Sprites.Client do
  @moduledoc """
  SDK client construction and account listing for the Sprites adapter.

  Reads `SPRITES_TOKEN` / `SPRITES_BASE_URL` / `SPRITES_TIMEOUT_MS` from
  application env (set in `config/runtime.exs`). Nothing outside
  `Managoat.Sandbox.Sprites.*` should build a Sprites client.
  """

  require Logger

  # The list endpoint returns 50 per page. A reconciliation that stops at the
  # first page is worse than no reconciliation, because it looks complete.
  @max_pages 40

  @doc """
  Returns a Sprites client, or raises if SPRITES_TOKEN is not set.

  `:timeout` overrides the configured HTTP timeout for this client, for a call
  known to outlast it (`Managoat.Sandbox.Sprites.apply_network_policy/2`).
  """
  def get!(opts \\ []) do
    token =
      Managoat.Sandbox.Config.get(Managoat.Sandbox.Sprites, :token) ||
        raise "SPRITES_TOKEN is not set — cannot talk to sprites.dev"

    base_url =
      Managoat.Sandbox.Config.get(Managoat.Sandbox.Sprites, :base_url, "https://api.sprites.dev")

    # Explicit rather than the library default, so an operator can see and
    # tune it (SPRITES_TIMEOUT_MS). This bounds every HTTP call the client
    # makes; long-running execs pass their own :timeout.
    timeout =
      Keyword.get_lazy(opts, :timeout, fn ->
        Managoat.Sandbox.Config.get(Managoat.Sandbox.Sprites, :timeout_ms, 30_000)
      end)

    Sprites.new(token, base_url: base_url, timeout: timeout)
  end

  @doc """
  Every sprite name on the account, as a MapSet.

  `Sprites.list/2` cannot be used for this. It pattern-matches the `"sprites"`
  key out of the response and discards `has_more` and
  `next_continuation_token`, so it returns the first page and gives no
  indication there is more — against production that was 50 names out of 114.
  Anything comparing that list to the database would silently treat two thirds
  of the account as non-existent.

  Returns `{:error, :truncated}` rather than a short list if the account somehow
  exceeds `#{@max_pages}` pages, because a caller deciding what to delete must
  never be handed a partial view that looks whole.

  Errors are raw SDK shapes here; `Managoat.Sandbox.Sprites.list_all_names/0`
  normalizes them into the taxonomy.
  """
  @spec list_all_names() :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def list_all_names do
    collect(get!(), nil, MapSet.new(), 0)
  end

  defp collect(_client, _token, _acc, page) when page >= @max_pages do
    Logger.error("sprites: list exceeded #{@max_pages} pages — refusing to return a partial view")
    {:error, :truncated}
  end

  defp collect(client, token, acc, page) do
    params = if token, do: [continuation_token: token], else: []

    case Req.get(client.req, url: "/v1/sprites", params: params) do
      {:ok, %{status: status, body: %{"sprites" => sprites} = body}} when status in 200..299 ->
        acc = Enum.reduce(sprites, acc, fn s, set -> MapSet.put(set, s["name"]) end)
        next = body["next_continuation_token"]

        if body["has_more"] && is_binary(next) && next != "" do
          collect(client, next, acc, page + 1)
        else
          {:ok, acc}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
