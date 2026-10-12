defmodule FountainWeb.CSP do
  @moduledoc """
  Widens the `content-security-policy` header the `:browser` pipeline sets
  with origins that are only known at runtime.

  `FountainWeb.Router`'s `@csp` is a compile-time attribute, so anything read
  from the environment in `config/runtime.exs` cannot appear in it: a release
  would carry whatever the *build* saw, which is nothing.
  `FountainWeb.Plugs.BrandAssets` widens it per response instead, for the
  origin a brand bundle is served from, through here so the header has one
  rewriter.
  """

  import Plug.Conn

  @doc """
  Appends `origins` to each of the named `directives` of the response's
  policy. A response with no policy is returned untouched: adding one here
  would be inventing a second source of truth for a header the `:browser`
  pipeline owns.
  """
  @spec widen(Plug.Conn.t(), [String.t()], [String.t()]) :: Plug.Conn.t()
  def widen(conn, _directives, []), do: conn

  def widen(conn, directives, origins) do
    case get_resp_header(conn, "content-security-policy") do
      [csp | _] ->
        put_resp_header(conn, "content-security-policy", widen_policy(csp, directives, origins))

      [] ->
        conn
    end
  end

  defp widen_policy(csp, directives, origins) do
    csp
    |> String.split(";")
    |> Enum.map_join("; ", &widen_directive(String.trim(&1), directives, origins))
  end

  defp widen_directive(directive, directives, origins) do
    [name | sources] = String.split(directive, " ")

    if name in directives do
      # `--` rather than a blind append: the header is rewritten on every
      # response, and a proxy or a future plug that has already added one of
      # these origins must not make the directive grow each time.
      Enum.join([directive | origins -- sources], " ")
    else
      directive
    end
  end
end
