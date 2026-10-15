defmodule Managoat.Sandbox.E2B.Errors do
  @moduledoc """
  Normalizes E2B error shapes into the `Managoat.Sandbox` taxonomy — the
  same mapping discipline as the Sprites adapter's, with `:e2b` as the
  escape-hatch tag.
  """

  alias Managoat.Sandbox

  @spec normalize(term()) :: Sandbox.error()
  def normalize(:not_found), do: :not_found
  def normalize(:truncated), do: :truncated
  def normalize(:command_exited), do: :command_exited
  def normalize({:api_error, 404, _body}), do: :not_found

  def normalize({:api_error, status, body}) when status in [401, 403],
    do: {:denied, {:http, status, body}}

  def normalize({:api_error, 429, body}), do: {:rate_limited, retry_after(body)}

  def normalize({:api_error, status, body}) when status >= 500,
    do: {:unavailable, {:http, status, body}}

  def normalize({:api_error, status, body}), do: {:invalid, {:http, status, body}}

  # A stream that ended with the command's fate unknown; transient for the
  # same reason as the Sprites adapter's — see that module.
  def normalize(:closed_before_exit), do: {:unavailable, :closed_before_exit}

  def normalize(:timeout), do: {:unavailable, :timeout}
  def normalize(%Req.TransportError{} = e), do: {:unavailable, e}
  def normalize(%Mint.TransportError{} = e), do: {:unavailable, e}

  def normalize(reason), do: {:provider, :e2b, reason}

  defp retry_after(%{"retryAfterSeconds" => s}) when is_integer(s) and s >= 0, do: s
  defp retry_after(_body), do: nil
end
