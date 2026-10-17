defmodule Managoat.Runtimes.BundleCache do
  @moduledoc """
  The host's copy of a pinned adapter bundle, fetched once per URL and kept
  for the node's life, for `Managoat.Runtimes.ACP.preload/2` to push into a
  sandbox.

  A bundle is immutable (its release tag refuses replacement) and its SHA-512
  is compiled in from the bundle record, so a copy that verified once stays
  right: the bytes are checked here before they are kept, and the sandbox
  checks them again before it extracts them. A fetch that fails or does not
  verify keeps nothing, and the next provision tries again.

  Concurrent first fetches of one URL are serialised, so a burst of cold
  provisions after a boot downloads each bundle once. `:acp_bundle_req_options`
  is merged into the request so a test can stand in for the network.
  """

  @spec fetch(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(url, integrity) do
    key = {__MODULE__, url}

    case :persistent_term.get(key, nil) do
      nil -> :global.trans({key, self()}, fn -> fetch_once(key, url, integrity) end)
      bytes -> {:ok, bytes}
    end
  end

  defp fetch_once(key, url, integrity) do
    case :persistent_term.get(key, nil) do
      nil -> download(key, url, integrity)
      bytes -> {:ok, bytes}
    end
  end

  defp download(key, url, integrity) do
    opts =
      [url: url, raw: true, retry: false, receive_timeout: 15_000]
      |> Keyword.merge(Application.get_env(:fountain, :acp_bundle_req_options, []))

    case Req.get(opts) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if "sha512-" <> Base.encode64(:crypto.hash(:sha512, body)) == integrity do
          :persistent_term.put(key, body)
          {:ok, body}
        else
          {:error, :bundle_integrity}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:bundle_http, status}}

      {:error, exception} ->
        {:error, {:bundle_fetch, Exception.message(exception)}}
    end
  end
end
