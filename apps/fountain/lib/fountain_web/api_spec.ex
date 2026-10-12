defmodule FountainWeb.ApiSpec do
  @moduledoc """
  Builds the OpenAPI 3.1 spec from controller `operation` decls + the
  router. Served at `/api/openapi.json`; Swagger UI at `/api/docs`.
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias FountainWeb.{Endpoint, Router}
  alias FountainWeb.ApiSpec.{FixtureRuntime, PipelineResponses}

  @behaviour OpenApi

  @app_version Mix.Project.config()[:version]

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(Endpoint)],
      info: %Info{
        title: "Fountain",
        version: @app_version,
        description: """
        HTTP API for Fountain. The same surface backs the LiveView UI and the
        `fountain` CLI (`brew install managoat/tap/fountain`); if it's not
        here, it doesn't exist yet.

        All `/api/*` endpoints require a per-user API key (`ftn_...`) passed as
        a bearer token. Mint one at `POST /api/auth/api-keys` (or exchange
        email + password at `POST /api/auth/token`); keys carry scopes and an
        expiry.
        """
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearer" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description:
              "Per-user API key (`ftn_...`), minted at `POST /api/auth/api-keys` " <>
                "or exchanged at `POST /api/auth/token`. Keys carry scopes and an expiry."
          }
        }
      },
      security: [%{"bearer" => []}]
    }
    |> PipelineResponses.apply(Router)
    # Last, on resolved components: a deployment that names an account for the
    # opt-in test fixture names its runtime in its own spec, nowhere else (#1716).
    |> FixtureRuntime.widen()
  end
end
