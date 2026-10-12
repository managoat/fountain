defmodule FountainWeb.SchemaGuardrailTest do
  @moduledoc """
  Does the OpenAPI document tell the truth about its own controllers (#1427)?

  Three defects of one class surfaced in a day, and nothing in the repository
  could catch any of them, because every existing check compares a schema with
  another schema:

    1. `AuthMeResponse.required` named `name`, `prefix` and `created_at`,
       properties the schema does not have, copied from `ApiKey` (#1417).
       `openapi-typescript` drops a required name with no property, so the
       published client had every field on that response optional.
    2. `AuthMeResponse` declares `expires_at`, which `show/2` never renders
       (#1418). The spec promises a field the endpoint does not return.
    3. Reported as a bare `{"type": "object"}` 402 on `POST /api/conversations`
       carrying an undeclared field. Building this guard showed that one was
       not a server defect at all: the operation declared its fields perfectly
       well, and `scripts/sdk-contract/build.py` was
       dropping the properties of an inline schema when it projected them.
       Fixed there. The check below still exists, because a response declared
       as a propertyless object is a real hazard even though nothing is in that
       state today.

  Each needs a different question asked, so this file asks three.

  **The rendered half** is not here at all — it is a telemetry handler attached
  in `test_helper.exs`, validating every response any controller test produces
  against the schema its operation declares. That is where defect 1 is caught,
  and it covers 146 operations for free because the tests already exist.
  `FountainWeb.SchemaGuardAllowlist` holds what is already wrong.

  **The static half** is `every declared response says something` below: a
  declared JSON response with no properties, no `$ref` and no type promises
  nothing, so no guard anywhere can disagree with it. It passes today and its
  job is to keep it that way.

  **The exhaustive half** is `renders every property it declares`, which catches
  defect 2. The rendered half cannot: an optional property that is never sent
  still validates. This one drives a real request and compares the keys that
  came back against the properties the schema declares, for the operations in
  `@pins` below where that is worth pinning.
  """

  use FountainWeb.ConnCase, async: true

  alias FountainWeb.{SchemaGuard, SchemaGuardAllowlist}
  alias OpenApiSpex.{Reference, Schema}

  # The allowlist may shrink freely. Growing it means editing this number in
  # the same diff, which is the whole ratchet: a reviewer sees the number move.
  @ceiling 1

  describe "the ratchet" do
    test "the allowlist has not grown" do
      count = map_size(SchemaGuardAllowlist.entries())

      assert count <= @ceiling, """
      The schema guard allowlist has #{count} entries, and the ceiling is #{@ceiling}.

      A new entry means a new place where the document disagrees with its
      controller. If that is deliberate, raise @ceiling here in the same diff so
      the growth is visible in review. If it is not, fix the schema instead.
      """
    end

    test "every entry names a family that has a reason" do
      families = SchemaGuardAllowlist.reasons()

      for {{operation, status}, family} <- SchemaGuardAllowlist.entries() do
        assert Map.has_key?(families, family),
               "#{operation} -> #{status} is allowlisted as #{inspect(family)}, " <>
                 "which has no reason. Every entry has to say why."
      end
    end

    test "every entry names an operation the API still serves" do
      served = SchemaGuard.operations() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      stale =
        for {{operation, status}, _} <- SchemaGuardAllowlist.entries(),
            not MapSet.member?(served, operation),
            do: "#{operation} -> #{status}"

      assert stale == [], """
      These allowlist entries name operations the API no longer serves:

      #{Enum.map_join(stale, "\n", &"  #{&1}")}

      Delete them. A stale allowlist entry is a fix nobody noticed landing.
      """
    end
  end

  describe "the schema itself" do
    test "no `required` names a property the schema does not have" do
      # Defect 1's shape, caught statically as well as at render time, because
      # `openapi-typescript` drops such a name silently and the published client
      # then has every field optional. scripts/sdk-contract/build.py refuses to
      # project one too; this fails first and in the language it was written in.
      offenders =
        for {title, schema} <- schemas(),
            required = schema.required || [],
            properties = schema.properties || %{},
            missing = Enum.reject(required, &Map.has_key?(properties, &1)),
            missing != [],
            do: "#{title}: requires #{inspect(missing)}, which it does not declare"

      assert offenders == [], """
      A schema requires properties it does not have:

      #{Enum.map_join(offenders, "\n", &"  #{&1}")}

      This is #1417 exactly. Either add the properties or fix the `required:` list.
      """
    end

    test "every declared JSON response says something" do
      # A response declared as a bare object with no properties, no ref and no
      # additionalProperties accepts literally anything, so no guard anywhere —
      # this file, the SDK projection, a generated client — can ever disagree
      # with it. It is a hole in the contract shaped like a schema. Nothing is
      # in that state today; this is here so nothing gets there.
      offenders =
        for {name, operation} <- documented_operations(),
            {status, response} <- operation.responses || %{},
            schema = json_schema(response),
            schema != nil,
            empty_object?(schema),
            do: "#{name} -> #{status}"

      assert offenders == [], """
      These responses are declared as an object with no properties:

      #{Enum.map_join(offenders, "\n", &"  #{&1}")}

      A schema that promises nothing cannot be wrong, and cannot be useful to a
      generated client either. Give it properties, or point it at a schema that
      has them.
      """
    end
  end

  describe "the controller renders what the schema declares" do
    # Defect 2. The rendered half cannot catch a declared property that is never
    # sent, because an absent optional property validates fine. So for the
    # operations where the schema should be exhaustive, drive a real request and
    # compare the keys.
    #
    # `@pins` is the roster: {operation, schema title, how to find the object
    # being checked inside the parsed body, a zero-arg function that drives the
    # request and returns `json_response(conn, <2xx>)`}. Adding an operation is
    # one more line here; `assert_renders_every_property/3` does the rest.
    #
    # `extract` says where the object being compared to the schema's properties
    # lives in the body a request function returns:
    #
    #   :root - the body itself. Only `AuthMeResponse` is shaped this way; every
    #            other response here is the `%{data: ...}` envelope
    #            `FountainWeb.SchemaWrappers` builds, and the schema named is the
    #            *item* schema (`Agent`), never the envelope (`AgentResponse`) —
    #            the envelope's own properties are just `data`, which always
    #            renders and would prove nothing.
    #   :item - `body["data"]`, a `show`-shaped response.
    #   :list - the first element of `body["data"]`, an `index`-shaped response,
    #            still checked against the item schema rather than the list
    #            envelope.
    #
    # `Map.has_key?/2` below is a deliberate choice, not an oversight: a
    # property the controller renders as `null` has the key present and counts
    # as rendered. Only an omitted key is the defect this file exists to catch —
    # an endpoint that legitimately sends null for an optional field (`model` on
    # an acp agent, `sandbox` before one is provisioned) is not required to send
    # every property's opposite-of-null value too.
    # {operation, property} => issue, for a declared property a pinned
    # operation deliberately does not render (a real API decision, not a
    # miss). Empty today: `pending_requests` was the only tenant, and #2305
    # closed it by having every renderer that shares the `Conversation`
    # schema send `[]` instead of omitting the key.
    @unrendered %{}

    @pins [
      {"GET /api/auth/me", "AuthMeResponse", :root, &__MODULE__.request_auth_me/0},
      {"GET /api/agents", "Agent", :list, &__MODULE__.request_agents_index/0},
      {"GET /api/agents/:id", "Agent", :item, &__MODULE__.request_agents_show/0},
      {"GET /api/environments", "Environment", :list, &__MODULE__.request_environments_index/0},
      {"GET /api/environments/:id", "Environment", :item,
       &__MODULE__.request_environments_show/0},
      {"GET /api/vaults", "Vault", :list, &__MODULE__.request_vaults_index/0},
      {"GET /api/vaults/:id", "Vault", :item, &__MODULE__.request_vaults_show/0},
      {"GET /api/conversations", "Conversation", :list,
       &__MODULE__.request_conversations_index/0},
      {"GET /api/conversations/:id", "Conversation", :item,
       &__MODULE__.request_conversations_show/0},
      {"GET /api/team", "Teammate", :list, &__MODULE__.request_team_index/0},
      {"GET /api/team/:agent_id", "Teammate", :item, &__MODULE__.request_team_show/0}
    ]

    for {operation, title, extract, request} <- @pins do
      test "#{operation} renders every property #{title} declares" do
        body = unquote(request).() |> extract_target(unquote(extract))
        assert_renders_every_property(unquote(operation), unquote(title), body)
      end
    end

    defp extract_target(body, :root), do: body
    defp extract_target(body, :item), do: Map.fetch!(body, "data")

    defp extract_target(body, :list) do
      case Map.fetch!(body, "data") do
        [first | _] -> first
        [] -> flunk("the request built for this pin returned an empty list")
      end
    end

    defp assert_renders_every_property(operation, title, body) do
      declared = schemas() |> Map.new() |> Map.fetch!(title) |> Map.get(:properties, %{})

      missing =
        declared
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.reject(fn property ->
          Map.has_key?(body, property) or Map.has_key?(@unrendered, {operation, property})
        end)
        |> Enum.sort()

      assert missing == [], """
      #{operation} declares #{inspect(missing)} on #{title} and did not render #{if length(missing) == 1, do: "it", else: "them"}.

      The spec promises a field the endpoint does not return, and every SDK
      generated from it carries the field. Either render it in the action or
      drop it from the schema. If the answer is a real API decision, add it to
      @unrendered with the issue number.
      """
    end

    # ── request builders, one per @pins entry ──────────────────────────────

    def request_auth_me do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)

      build_conn()
      |> authed_with_key(raw_key)
      |> get(~p"/api/auth/me")
      |> json_response(200)
    end

    def request_agents_index do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      insert_agent(user_id: user.id)

      build_conn()
      |> authed_with_key(raw_key)
      |> get("/api/agents")
      |> json_response(200)
    end

    def request_agents_show do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      agent = insert_agent(user_id: user.id)

      build_conn()
      |> authed_with_key(raw_key)
      |> get("/api/agents/#{agent.id}")
      |> json_response(200)
    end

    def request_environments_index do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      insert_env(user_id: user.id)

      build_conn()
      |> authed_with_key(raw_key)
      |> get("/api/environments")
      |> json_response(200)
    end

    def request_environments_show do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      env = insert_env(user_id: user.id)

      build_conn()
      |> authed_with_key(raw_key)
      |> get("/api/environments/#{env.id}")
      |> json_response(200)
    end

    def request_vaults_index do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      insert_vault(user_id: user.id)

      build_conn()
      |> authed_with_key(raw_key)
      |> get("/api/vaults")
      |> json_response(200)
    end

    def request_vaults_show do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      vault = insert_vault(user_id: user.id)

      build_conn()
      |> authed_with_key(raw_key)
      |> get("/api/vaults/#{vault.id}")
      |> json_response(200)
    end

    def request_conversations_index do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      insert_conversation(user_id: user.id)

      build_conn()
      |> authed_with_key(raw_key)
      |> get("/api/conversations")
      |> json_response(200)
    end

    def request_conversations_show do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      conv = insert_conversation(user_id: user.id)

      build_conn()
      |> authed_with_key(raw_key)
      |> get("/api/conversations/#{conv.id}")
      |> json_response(200)
    end

    def request_team_index do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      agent = insert_agent(user_id: user.id, name: "Ada")

      insert_conversation(
        user_id: user.id,
        agent: agent,
        status: "idle",
        channel_id: Fountain.Team.channel()
      )

      build_conn()
      |> authed_with_key(raw_key)
      |> get("/api/team")
      |> json_response(200)
    end

    def request_team_show do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      agent = insert_agent(user_id: user.id, name: "Ada")

      insert_conversation(
        user_id: user.id,
        agent: agent,
        status: "idle",
        channel_id: Fountain.Team.channel()
      )

      build_conn()
      |> authed_with_key(raw_key)
      |> get("/api/team/#{agent.id}")
      |> json_response(200)
    end
  end

  # ── reading the document ────────────────────────────────────────────────────

  defp spec, do: OpenApiSpex.resolve_schema_modules(FountainWeb.ApiSpec.spec())

  defp schemas do
    for {title, %Schema{} = schema} <- spec().components.schemas, do: {title, schema}
  end

  defp documented_operations do
    for {path, item} <- spec().paths,
        {method, %OpenApiSpex.Operation{} = operation} <- Map.from_struct(item),
        do: {"#{method |> to_string() |> String.upcase()} #{path}", operation}
  end

  defp json_schema(%Reference{}), do: nil

  defp json_schema(response) do
    # A response with no `content` at all is a 204 or a redirect, and there is
    # nothing there to be wrong about.
    case Map.get(response, :content) do
      nil -> nil
      content -> content |> Map.get("application/json", %{}) |> Map.get(:schema)
    end
  end

  defp empty_object?(%Schema{} = schema) do
    schema.type == :object and
      (schema.properties == nil or schema.properties == %{}) and
      schema.additionalProperties in [nil, false] and
      schema.oneOf == nil and schema.anyOf == nil and schema.allOf == nil
  end

  defp empty_object?(_), do: false
end
