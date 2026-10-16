defmodule RemoteBroker.Store do
  @moduledoc "No credential cache: every HTTP admission consults home, including inside CONNECT."
  @behaviour Managoat.Broker.Store
  alias Managoat.Broker.{Rule, Session}

  @schemes %{
    "bearer" => :bearer,
    "basic" => :basic,
    "api_key" => :api_key,
    "custom" => :custom,
    "substitute" => :substitute,
    "passthrough" => :passthrough
  }

  @impl true
  def lookup(token) do
    with {:ok, %{status: 200, body: body}} <-
           RemoteBroker.Control.request("lookup", %{token: token}),
         {:ok, expires, _} <- DateTime.from_iso8601(body["expires_at"]),
         policy when policy in ["deny", "passthrough"] <- body["policy"],
         id when is_binary(id) <- body["authorization"],
         receipt when is_binary(receipt) <- body["receipt"] do
      {:ok,
       %Session{
         authorization: id,
         expires_at: expires,
         unmatched_host_policy: if(policy == "deny", do: :deny, else: :passthrough),
         rules: Enum.map(body["patterns"], &%Rule{pattern: &1, scheme: :passthrough}),
         meta: %{"receipt" => receipt}
       }}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @impl true
  def authorize(id, request) do
    case RemoteBroker.Control.request("authorize", %{
           authorization: id,
           host: request.host,
           port: request.port
         }) do
      {:ok, %{status: 200, body: %{"rules" => rules}}} when is_list(rules) ->
        {:ok, Enum.map(rules, &decode/1)}

      {:ok, %{status: 403}} ->
        {:error, :denied}

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp decode(map) do
    %Rule{
      name: map["name"],
      pattern: map["pattern"],
      scheme: Map.fetch!(@schemes, map["scheme"]),
      credential: credential(map["credential"]),
      header: map["header"],
      prefix: map["prefix"] || "",
      template: map["template"] || %{},
      placeholder: map["placeholder"]
    }
  end

  defp credential(%{"basic" => [user, pass]}), do: {user, pass}
  defp credential(value), do: value
end
