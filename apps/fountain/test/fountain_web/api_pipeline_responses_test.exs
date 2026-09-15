defmodule FountainWeb.ApiPipelineResponsesTest do
  use FountainWeb.ConnCase, async: true

  alias FountainWeb.{ApiSpec, SchemaGuard}

  test "authenticated operations include the errors of their router pipelines" do
    spec = ApiSpec.spec()

    for route <- FountainWeb.Router.__routes__(),
        info =
          Phoenix.Router.route_info(
            FountainWeb.Router,
            String.upcase(to_string(route.verb)),
            route.path,
            "localhost"
          ),
        :api in info.pipe_through,
        path = Regex.replace(~r/:([^\/]+)/, route.path, "{\\1}"),
        item = Map.get(spec.paths, path),
        item != nil,
        operation = Map.get(item, route.verb),
        operation != nil do
      for status <- [401, 403, 429] do
        assert Map.has_key?(operation.responses, status), "#{route.verb} #{path} lacks #{status}"
      end
    end
  end

  test "public endpoints do not inherit tenant auth, and SSE does not inherit JSON negotiation" do
    spec = ApiSpec.spec()
    refute Map.has_key?(spec.paths["/health"].get.responses, 401)
    refute Map.has_key?(spec.paths["/api/auth/register"].post.responses, 401)

    refute Map.has_key?(
             spec.paths["/api/conversations/{conversation_id}/stream"].get.responses,
             406
           )

    assert Map.has_key?(spec.paths["/api/conversations"].get.responses, 406)
  end

  test "installed extension operations inherit the dispatch pipeline's errors" do
    spec = ApiSpec.spec()

    for {path, item} <- Fountain.Extensions.openapi_paths(),
        {verb, %OpenApiSpex.Operation{}} <- Map.from_struct(item) do
      responses = Map.fetch!(spec.paths[path], verb).responses

      for status <- [401, 403, 406, 429] do
        assert Map.has_key?(responses, status), "#{verb} #{path} lacks #{status}"
      end
    end
  end

  test "composition preserves operation-specific responses" do
    # Every JSON error status declares the one `Error` schema (#2324), so what
    # a controller adds over the pipeline is the status itself and its
    # description; the pipeline's 403 must not overwrite the egress
    # operation's own wording.
    spec = ApiSpec.spec()
    responses = spec.paths["/api/conversations/{conversation_id}/egress"].get.responses
    assert responses[403].description == "The key lacks full scope"

    assert responses[403].content["application/json"].schema ==
             %OpenApiSpex.Reference{"$ref": "#/components/schemas/Error"}

    responses = spec.paths["/api/conversations"].post.responses
    assert responses[402].description == "Insufficient credits"
    assert spec.components.schemas["Error"].properties[:upgrade_url]
  end

  test "real pipeline refusals validate without an allowlist" do
    conn = build_conn() |> get("/api/agents")
    assert json_response(conn, 401)["reason"] == "api_key_invalid"
    assert {:ok, _} = SchemaGuard.check(conn)

    user = insert_verified_user()
    {_record, key} = insert_api_key(user)

    assert {406, _, body} =
             assert_error_sent(406, fn ->
               build_conn()
               |> authed_with_key(key)
               |> put_req_header("accept", "text/event-stream")
               |> get("/api/conversations")
             end)

    assert Jason.decode!(body) == %{"errors" => %{"detail" => "Not Acceptable"}}
  end
end
