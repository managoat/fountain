defmodule FountainWeb.ApiSpec.Compose do
  @moduledoc """
  Merges installed extensions' OpenAPI paths and components into the core spec
  (ADR 0043, #1506).

  ## Why this is not just `Map.merge/2`

  A spec is two namespaces, and both merge badly by default:

    * **Paths.** Two operations at the same path: last writer wins, silently.
    * **Components.** `OpenApiSpex.resolve_schema_modules/1` keys
      `components.schemas` by each schema's `title`, so two *different* modules
      sharing a title collapse into one and every `$ref` to either resolves to
      whichever landed last. An extension defining a schema titled `Agent`
      would rewrite the core's `Agent` in the published spec, and the SDK is
      generated from that spec (#1411).

  Both raise here instead. The failure surfaces when the spec is built — which
  is at boot, in `mix openapi.spec.json`, and in the suite — rather than as a
  wrong client three releases later.

  ## The distribution is what the spec describes

  `spec/0` composes from `Fountain.Extensions.installed/0` at call time, so a
  core-only distribution's spec has no extension paths in it, and the bundled
  one's has exactly the operations it serves. There is no build flag and no
  second artifact: the published spec **is** the bundled spec, which is the
  contract the SDKs generate from and what ADR 0043 decision 6 promises not to
  change silently.
  """

  alias Fountain.Extensions
  alias OpenApiSpex.{Components, OpenApi}

  @doc """
  Return `core` with every installed extension's paths and schemas merged in.

  Raises `ArgumentError` on a path an extension and the core both describe, or
  on a schema title they both define with different schemas. A title both
  define *identically* is allowed through: that is one module reachable from
  both halves, not a collision.
  """
  @spec compose!(OpenApi.t()) :: OpenApi.t()
  def compose!(%OpenApi{} = core), do: compose!(core, Extensions.installed())

  @doc "See `compose!/1`. Takes the extension list, so a test can supply one."
  @spec compose!(OpenApi.t(), [Extensions.t()]) :: OpenApi.t()
  def compose!(%OpenApi{} = core, extensions) when is_list(extensions) do
    case Extensions.openapi_paths(extensions) do
      empty when empty == %{} ->
        core

      extension_paths ->
        merge!(core, extension_paths)
    end
  end

  defp merge!(core, extension_paths) do
    check_path_collisions!(core.paths, extension_paths)

    # Resolved on its own rather than by resolving the merged spec: the point is
    # to see the extensions' components as a separate set, so a title they share
    # with the core can be compared instead of quietly overwriting it.
    resolved =
      OpenApiSpex.resolve_schema_modules(%OpenApi{
        info: core.info,
        paths: extension_paths
      })

    core_schemas = schemas(core)
    extension_schemas = schemas(resolved)
    check_schema_collisions!(core_schemas, extension_schemas)

    %{
      core
      | paths: Map.merge(core.paths, resolved.paths),
        components: %{
          (core.components || %Components{})
          | schemas: Map.merge(core_schemas, extension_schemas)
        }
    }
  end

  defp schemas(%OpenApi{components: %Components{schemas: schemas}}) when is_map(schemas),
    do: schemas

  defp schemas(%OpenApi{}), do: %{}

  defp check_path_collisions!(core_paths, extension_paths) do
    shared = MapSet.intersection(keys(core_paths), keys(extension_paths))

    if MapSet.size(shared) == 0 do
      :ok
    else
      raise ArgumentError, """
      an installed extension describes OpenAPI paths the core already describes: \
      #{shared |> Enum.sort() |> Enum.join(", ")}

      A core route always wins at dispatch, so the extension does not serve these \
      and must not describe them. Fountain.Extensions.validate!/0 refuses an \
      api_prefix a core route claims, so reaching this means the extension \
      described a path outside its own mount.
      """
    end
  end

  defp keys(map), do: map |> Map.keys() |> MapSet.new()

  defp check_schema_collisions!(core_schemas, extension_schemas) do
    conflicts =
      for {title, extension_schema} <- extension_schemas,
          Map.has_key?(core_schemas, title),
          Map.fetch!(core_schemas, title) != extension_schema,
          do: title

    if conflicts == [] do
      :ok
    else
      raise ArgumentError, """
      an installed extension defines OpenAPI schema components that collide with the \
      core's: #{conflicts |> Enum.sort() |> Enum.join(", ")}

      Components are keyed by their `title`, so one of each pair would silently \
      replace the other in the published spec and every $ref to either would resolve \
      to the survivor. The SDKs are generated from that spec. Give the extension's \
      schema a title of its own, prefixed with the extension's name.
      """
    end
  end
end
