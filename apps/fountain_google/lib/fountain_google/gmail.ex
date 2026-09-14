defmodule FountainGoogle.Gmail do
  @moduledoc """
  The slice of the Gmail API the extension's MCP server uses (#1178), over
  `Req`, with the access token supplied per call. Returns the JSON the API
  returns; the MCP layer shapes it for the model.

  Configuration is this app's own (`config :fountain_google`, ADR 0043):
  `:timeout_ms` bounds a request, and tests inject a `Req.Test` plug through
  `:req_options`.
  """

  @base_url "https://gmail.googleapis.com/gmail/v1/users/me"

  @metadata_headers ~w(From To Cc Subject Date Message-ID)

  @doc "Threads matching a Gmail search query (`q`), newest first."
  def list_threads(token, opts \\ []) do
    params =
      [
        q: Keyword.get(opts, :query),
        maxResults: Keyword.get(opts, :max_results, 10),
        pageToken: Keyword.get(opts, :page_token)
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Kernel.++(repeated(:labelIds, Keyword.get(opts, :label_ids)))

    get(token, "/threads", params: params)
  end

  @doc "One thread with every message, in `format`: `metadata` (headers + snippet) or `full`."
  def get_thread(token, thread_id, format \\ "metadata") do
    get(token, "/threads/#{enc(thread_id)}",
      params: [format: format] ++ repeated(:metadataHeaders, @metadata_headers)
    )
  end

  # Gmail takes a multi-valued parameter as a repeated key
  # (`metadataHeaders=From&metadataHeaders=To`); `URI.encode_query/1`
  # refuses a list value, so each value gets its own pair.
  defp repeated(_key, nil), do: []
  defp repeated(key, values) when is_list(values), do: Enum.map(values, &{key, &1})

  @doc "One message, in `full` format (headers, snippet and body parts)."
  def get_message(token, message_id, format \\ "full") do
    get(token, "/messages/#{enc(message_id)}", params: [format: format])
  end

  @doc "Send an RFC 2822 message (already assembled); `thread_id` places it in a thread."
  def send_raw(token, raw, thread_id \\ nil) do
    body =
      %{"raw" => Base.url_encode64(raw, padding: false)}
      |> then(&if thread_id, do: Map.put(&1, "threadId", thread_id), else: &1)

    post(token, "/messages/send", json: body)
  end

  @doc "Add and remove labels on a message."
  def modify_message(token, message_id, add, remove) do
    post(token, "/messages/#{enc(message_id)}/modify",
      json: %{"addLabelIds" => add || [], "removeLabelIds" => remove || []}
    )
  end

  @doc "The account's labels."
  def list_labels(token), do: get(token, "/labels")

  @doc "The address and message counts of the connected account."
  def profile(token), do: get(token, "/profile")

  @doc """
  Assemble an RFC 2822 message. `headers` is a keyword list of header lines
  (`[to: "...", subject: "..."]`); `body` is plain text.
  """
  def build_raw(headers, body) when is_list(headers) and is_binary(body) do
    lines =
      headers
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
      |> Enum.map(fn {k, v} -> header_name(k) <> ": " <> v end)

    Enum.join(
      lines ++
        ["MIME-Version: 1.0", "Content-Type: text/plain; charset=\"UTF-8\"", "", body],
      "\r\n"
    )
  end

  defp header_name(k) do
    k
    |> to_string()
    |> String.split("_")
    |> Enum.map_join("-", &String.capitalize/1)
  end

  defp get(token, path, opts), do: request(token, :get, path, opts)
  defp get(token, path), do: request(token, :get, path, [])
  defp post(token, path, opts), do: request(token, :post, path, opts)

  # The query is encoded here rather than through Req's `params`, which
  # folds a keyword list into a map and so keeps one value per key.
  defp request(token, method, path, opts) do
    {params, opts} = Keyword.pop(opts, :params, [])
    url = if params == [], do: path, else: path <> "?" <> URI.encode_query(params)
    req = Req.merge(req(), [url: url, auth: {:bearer, token}, method: method] ++ opts)

    case Req.request(req) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, error_message(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp error_message(%{"error" => %{"message" => m}}), do: m
  defp error_message(body) when is_binary(body), do: body
  defp error_message(body), do: inspect(body)

  defp enc(v), do: URI.encode(to_string(v), &URI.char_unreserved?/1)

  @doc false
  def req do
    Req.new(
      [
        base_url: @base_url,
        receive_timeout: Application.get_env(:fountain_google, :timeout_ms, 20_000),
        retry: false
      ] ++ Application.get_env(:fountain_google, :req_options, [])
    )
  end
end
