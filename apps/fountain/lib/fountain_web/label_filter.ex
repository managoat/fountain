defmodule FountainWeb.LabelFilter do
  @moduledoc """
  The `?label=key:value` filter on a conversation list (#1637):
  `GET /api/conversations` takes a repeatable, AND-combined parameter.

  Read from `conn.query_string` and not from `conn.params`, because Plug
  collapses a repeated key to its last value and this filter is repeatable by
  design. `Fountain.Conversations.Labels` owns the vocabulary; this is the
  Plug half plus the error the fallback controller renders as a 400.
  """

  alias Fountain.Conversations.Labels

  @doc """
  The label filter on a request: `{:ok, %{"env" => "prod"}}`, or
  `{:error, "invalid_label_filter"}` for a value with no colon or an empty
  key, which `FountainWeb.FallbackController` renders as a 400.

  Reads the list `FountainWeb.Plugs.RepeatedQueryParam` left on the request.
  `List.wrap/1` rather than a match, so a route that has not been given that
  plug degrades to the single value Plug kept instead of raising.
  """
  @spec from(Plug.Conn.t()) :: {:ok, map()} | {:error, String.t()}
  def from(%Plug.Conn{} = conn) do
    conn.params
    |> Map.get("label")
    |> List.wrap()
    |> parse()
  end

  @doc """
  The same filter out of a LiveView's `uri`, for the console's conversation
  list.

  A LiveView gets no plug pipeline and its `params` are collapsed the same
  way Plug collapses them, so the repeated key has to be read back off the
  URI. One parser either way, so the console and the API cannot disagree
  about what `?label=env:prod` means.
  """
  @spec from_uri(String.t()) :: {:ok, map()} | {:error, String.t()}
  def from_uri(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:query)
    |> Labels.from_query_string()
    |> parse()
  end

  defp parse(values) do
    case Labels.parse_filter(values) do
      {:ok, labels} -> {:ok, labels}
      {:error, :invalid_label_filter} -> {:error, "invalid_label_filter"}
    end
  end
end
