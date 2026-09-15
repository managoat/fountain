defmodule FountainWeb.ApiSpec.FixtureRuntime do
  @moduledoc """
  Puts `fountain-fixture` back into this deployment's runtime enums when the
  deployment names an account for it (#1716).

  `FountainWeb.Schemas` names `Fountain.Agents.Agent.packaged_runtimes/0`, so
  the exported contract — and every SDK type projected out of it — lists the
  five shipped runtimes and not the test fixture. But the fixture is admitted
  through the same public routes: `POST /api/agents` carries the runtime, and
  `CastAndValidate` casts it against the served spec, so on a deployment where
  the fixture is on the enum has to name it or the request never reaches the
  changeset that decides.

  So the enum is widened here rather than declared wide: the spec a deployment
  serves describes the deployment, and the spec exported with no fixture
  account — which is how `mix openapi.export` and CI run — is unchanged.

  This is a single-value widening rather than a general mechanism because the
  fixture is the only runtime gated this way; `Agent.runtimes/0` is the same
  decision on the changeset side.
  """

  alias Fountain.{Agents.Agent, DeployedACPFixture}
  alias OpenApiSpex.{OpenApi, Schema}

  @doc """
  Widen every resolved `runtime` enum by the gated runtimes, or return the spec
  untouched when this deployment has none.

  Runs on resolved components: `PipelineResponses.apply/2` leaves
  `components.schemas` as `%Schema{}` structs keyed by title, which is also
  what `CastAndValidate` reads and what `RenderSpec` encodes.
  """
  def widen(%OpenApi{} = spec) do
    case gated_runtimes() do
      [] -> spec
      runtimes -> update_in(spec.components.schemas, &widen_schemas(&1, runtimes))
    end
  end

  # `configured?/0`, not `enabled?/0`: turning the flag off stops admission but
  # keeps the agents the fixture created, and this deployment still has to
  # serve their runtime inside its own declared enum.
  defp gated_runtimes do
    if DeployedACPFixture.configured?(),
      do: Agent.known_runtimes() -- Agent.packaged_runtimes(),
      else: []
  end

  defp widen_schemas(schemas, runtimes) when is_map(schemas),
    do: Map.new(schemas, fn {name, schema} -> {name, widen_schema(schema, runtimes)} end)

  defp widen_schemas(schemas, _runtimes), do: schemas

  defp widen_schema(%Schema{properties: properties} = schema, runtimes)
       when is_map(properties) do
    %{schema | properties: Map.new(properties, &widen_property(&1, runtimes))}
  end

  defp widen_schema(schema, _runtimes), do: schema

  defp widen_property({:runtime, %Schema{enum: enum} = property}, runtimes) when is_list(enum),
    do: {:runtime, %{property | enum: enum ++ (runtimes -- enum)}}

  defp widen_property(property, _runtimes), do: property
end
