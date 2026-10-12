defmodule FountainWeb.ApiSpec.PipelineResponses do
  @moduledoc """
  Adds the errors shared by a route's pipelines to its OpenAPI operation.

  The router supplies membership; this module describes each pipeline's wire
  responses. Controller declarations take precedence, including specialized
  error envelopes. Controller-local plugs and context refusals remain declared
  on the operation that can return them.
  """

  alias FountainWeb.Schemas
  alias OpenApiSpex.{OpenApi, Operation}

  defmodule NegotiationError do
    @moduledoc false
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "NegotiationError",
      type: :object,
      properties: %{
        errors: %Schema{
          type: :object,
          properties: %{detail: %Schema{type: :string}},
          required: [:detail]
        }
      },
      required: [:errors]
    })
  end

  @doc "Add pipeline responses to all installed operations, then resolve their schemas."
  def apply(%OpenApi{} = spec, router) do
    paths =
      Map.new(spec.paths, fn {path, item} ->
        item =
          Enum.reduce(Map.from_struct(item), item, fn
            {verb, %Operation{} = operation}, item ->
              info =
                Phoenix.Router.route_info(
                  router,
                  String.upcase(to_string(verb)),
                  path,
                  "localhost"
                )

              responses =
                info.pipe_through
                |> Enum.flat_map(&statuses/1)
                |> Enum.uniq()
                |> Map.new(fn status -> {status, response(status)} end)
                |> Map.merge(operation.responses || %{})

              Map.put(item, verb, %{operation | responses: responses})

            _, item ->
              item
          end)

        {path, item}
      end)

    OpenApiSpex.resolve_schema_modules(%{spec | paths: paths})
  end

  defp statuses(:api), do: [401, 403, 429]
  defp statuses(pipeline) when pipeline in [:api_public, :accepts_json], do: [406]

  defp statuses(pipeline)
       when pipeline in [:require_full_scope, :require_key_management, :require_admin_api],
       do: [403]

  defp statuses(_), do: []

  defp response(406),
    do: Operation.response("No acceptable representation", "application/json", NegotiationError)

  defp response(status),
    do:
      Operation.response(
        Plug.Conn.Status.reason_phrase(status),
        "application/json",
        Schemas.Error
      )
end
