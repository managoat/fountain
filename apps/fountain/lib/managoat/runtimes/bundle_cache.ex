defmodule Managoat.Runtimes.BundleCache do
  @moduledoc """
  The host's copy of a pinned adapter bundle, fetched once per URL and kept
  for the node's life, for `Managoat.Runtimes.ACP` to stream into a
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

  @spec fetch(String.t(), String.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def fetch(url, integrity, max_bytes) do
    key = {__MODULE__, url}

    case :persistent_term.get(key, nil) do
      nil -> :global.trans({key, self()}, fn -> fetch_once(key, url, integrity, max_bytes) end)
      bytes -> {:ok, bytes}
    end
  end

  defp fetch_once(key, url, integrity, max_bytes) do
    case :persistent_term.get(key, nil) do
      nil -> download(key, url, integrity, max_bytes)
      bytes -> {:ok, bytes}
    end
  end

  # `max_bytes` is the bundle record's size: a body that runs past it is
  # abandoned as it arrives, before it is held whole or hashed. Only a 200's
  # body is collected, so the release URL's redirect page is not.
  defp download(key, url, integrity, max_bytes) do
    collect = fn {:data, data}, {req, resp} ->
      size = Req.Response.get_private(resp, :size, 0) + byte_size(data)
      resp = Req.Response.put_private(resp, :size, size)

      cond do
        resp.status != 200 -> {:cont, {req, resp}}
        size > max_bytes -> {:halt, {req, Req.Response.put_private(resp, :oversize, true)}}
        true -> {:cont, {req, %{resp | body: [resp.body, data]}}}
      end
    end

    opts =
      [url: url, raw: true, retry: false, receive_timeout: 15_000, into: collect]
      |> Keyword.merge(Application.get_env(:fountain, :acp_bundle_req_options, []))

    case Req.get(opts) do
      {:ok, %Req.Response{status: 200, private: %{oversize: true}}} ->
        {:error, :bundle_size}

      {:ok, %Req.Response{status: 200, body: body}} ->
        body = IO.iodata_to_binary(body)

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
