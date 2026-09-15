defmodule FountainWeb.Plugs.CastRenderError do
  @moduledoc """
  How a request rejected by `OpenApiSpex.Plug.CastAndValidate` is rendered.

  Without this, the validator renders its own quasi-JSON:API shape:

      {"errors": [{"title": "Invalid value", "source": {"pointer": "/limit"},
                   "detail": "Invalid integer. Got: string"}]}

  An **array**, keyed by pointer. Fountain's own validation failures are an
  object keyed by field:

      {"errors": {"limit": ["Invalid integer. Got: string"]}}

  So one status meant two shapes depending on whether the request died at the
  validator or in a changeset, and 27 operations declared one while sometimes
  sending the other (#1431). The visible cost was in the clients: the
  TypeScript SDK's `ValidationError.fieldErrors` reads `body.errors` as an
  object of field to messages, so against a validator 422 it returned `{}` —
  the caller was told the request was invalid and not which field, on exactly
  the failures where the field is the only useful information.

  ## Why the body carries both keys

  A 422 is not always a validation failure: `FountainWeb.FallbackController`
  renders sixteen coded `%{error: ..., message: ...}` refusals with the same
  status that have nothing to do with schema validation. So this renders both:

      {"error": "validation_failed",
       "errors": {"limit": ["Invalid integer. Got: string"]}}

  A client reading `body.error` for a code gets one, a client reading
  `body.errors` for fields gets those, and nothing has to branch on which kind
  of 422 it received. That is the property worth having: the alternative
  shapes clients apart, and four SDKs would each need to learn the difference.
  Since #2324 every JSON error status declares the one `Error` schema, which
  requires `error` and describes `errors` beside it; before that the 27
  operations declared three different 422 schemas and this body was the one
  that satisfied all of them.

  `FountainWeb.SchemaGuardrailTest` and the guard in `test_helper.exs` (#1427)
  are what keep this true — every one of those 27 operations validates its real
  rendered 422 against its declared schema on every run.
  """

  @behaviour Plug

  alias OpenApiSpex.OpenApi
  alias Plug.Conn

  @code "validation_failed"

  @impl Plug
  def init(errors), do: errors

  @impl Plug
  def call(conn, errors) when is_list(errors) do
    body = %{error: @code, errors: field_errors(errors)}

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(422, OpenApi.json_encoder().encode!(body))
  end

  def call(conn, error), do: call(conn, [error])

  # `{field => [message]}`, in the order the validator reported them.
  #
  # A `Cast.Error` carries the path it failed at, so `[:limit]` is `"limit"` and
  # a nested `[:repos, 0, :url]` is `"repos/0/url"` — flattened because
  # `Error` declares `errors` values as arrays of strings, not as a tree.
  # An error with no path at all is about the body as a whole; `"body"` is the
  # only key left to give it, and it is the one Ecto would not produce, so it
  # cannot collide with a real field.
  defp field_errors(errors) do
    errors
    |> Enum.map(&{key(&1), to_string(&1)})
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp key(%{path: path}) when is_list(path) and path != [],
    do: Enum.map_join(path, "/", &to_string/1)

  defp key(_error), do: "body"
end
