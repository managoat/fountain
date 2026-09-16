defmodule FountainWeb.SchemaWrappersTest do
  @moduledoc """
  The `%{data: ...}` envelope schemas, and the shape they must keep.

  Twenty-two modules said nothing but "one X" or "a list of X" in nine lines
  each. `list_response/2` and `item_response/2` replace them. These check the
  generated modules are indistinguishable from what they replaced — same
  title, same properties, same generated struct — and that a hand-written
  envelope does not creep back in beside them.
  """

  use ExUnit.Case, async: true

  alias FountainWeb.Schemas
  alias OpenApiSpex.Schema

  @schemas_source "lib/fountain_web/schemas.ex"

  describe "list_response/2" do
    test "wraps the item in an array under data" do
      schema = Schemas.ConversationListResponse.schema()

      assert %Schema{
               type: :object,
               properties: %{data: %Schema{type: :array, items: Schemas.Conversation}},
               required: [:data]
             } = schema
    end

    test "titles the schema after the module" do
      assert Schemas.TurnListResponse.schema().title == "TurnListResponse"
    end

    test "carries a description when one is given" do
      assert Schemas.AdminAuditListResponse.schema().description =~ "Cross-tenant audit events"
    end

    test "omits description when none is given" do
      refute Schemas.TurnListResponse.schema().description
    end

    test "accepts a fully qualified item, for forward references" do
      assert %Schema{properties: %{data: %Schema{items: Schemas.AuditEvent}}} =
               Schemas.AdminAuditListResponse.schema()
    end
  end

  describe "item_response/2" do
    test "puts the item directly under data" do
      assert %Schema{
               type: :object,
               properties: %{data: Schemas.Conversation},
               required: [:data]
             } = Schemas.ConversationResponse.schema()
    end

    test "titles the schema after the module" do
      assert Schemas.AgentResponse.schema().title == "AgentResponse"
    end
  end

  describe "update_of/2" do
    @updates [
      {Schemas.AgentUpdate, Schemas.AgentRequest},
      {Schemas.EnvironmentUpdate, Schemas.EnvironmentRequest},
      {Schemas.VaultUpdate, Schemas.VaultRequest}
    ]

    test "is the request with nothing required" do
      for {update, request} <- @updates do
        assert request.schema().required != nil
        assert update.schema().required == nil
        assert update.schema().properties == request.schema().properties
        assert update.schema().type == request.schema().type
      end
    end

    # Without the reset, build_schema keeps the request's own title and
    # x-struct, and the spec would publish two components both claiming to be
    # the request.
    test "names the schema and its struct after the update module" do
      for {update, _request} <- @updates do
        assert update.schema().title == update |> Module.split() |> List.last()
        assert update.schema()."x-struct" == update
        assert %{__struct__: ^update} = struct(update)
      end
    end

    # OpenApiSpex writes a property's default into the cast params. The
    # schedule create request defaults `enabled: true`; derived as an update,
    # every PATCH that left `enabled` out would switch a paused schedule on.
    test "refuses a request whose properties carry a default" do
      assert_raise ArgumentError, ~r/TeamScheduleCreateRequest.*:enabled/, fn ->
        FountainWeb.SchemaWrappers.partial(Schemas.TeamScheduleCreateRequest.schema())
      end
    end

    test "casts a body that omits what the request requires" do
      spec = FountainWeb.ApiSpec.spec()

      for {update, request} <- @updates do
        assert {:ok, _} = OpenApiSpex.cast_value(%{}, update.schema(), spec)
        assert {:error, _} = OpenApiSpex.cast_value(%{}, request.schema(), spec)
      end
    end
  end

  # OpenApiSpex gives every schema module a struct and a Jason encoder. The
  # hand-written envelopes had them; losing them silently would change what
  # `x-struct` reports in the published spec.
  test "generated modules still get a struct, like the ones they replaced" do
    assert %Schemas.ConversationListResponse{data: nil} =
             struct(Schemas.ConversationListResponse)

    assert Schemas.ConversationListResponse.schema()."x-struct" ==
             Schemas.ConversationListResponse
  end

  # Every module the macros are expected to define, listed rather than counted
  # so a conversion that silently stops generating one fails here by name.
  @generated [
    Schemas.AdminAuditListResponse,
    Schemas.AdminSandboxListResponse,
    Schemas.AdminUserResponse,
    Schemas.AgentListResponse,
    Schemas.AgentResponse,
    Schemas.ApiKeyListResponse,
    Schemas.ConversationListResponse,
    Schemas.ConversationResponse,
    Schemas.ConversationTreeResponse,
    Schemas.EnvironmentListResponse,
    Schemas.EnvironmentResponse,
    Schemas.ExportListResponse,
    Schemas.ExportResponse,
    Schemas.InferenceCredentialListResponse,
    Schemas.InferenceCredentialResponse,
    Schemas.SecretListResponse,
    Schemas.SecretResponse,
    Schemas.TurnListResponse,
    Schemas.VaultListResponse,
    Schemas.VaultResponse,
    Schemas.VaultSecretListResponse,
    Schemas.VaultSecretResponse
  ]

  test "all 22 generated envelopes exist and keep the envelope invariants" do
    assert length(@generated) == 22

    for mod <- @generated do
      assert Code.ensure_loaded?(mod), "#{inspect(mod)} was not defined"
      schema = mod.schema()
      assert schema.title == mod |> Module.split() |> List.last()
      assert schema.type == :object
      assert schema.required == [:data]
      assert Map.keys(schema.properties) == [:data]
    end
  end

  # The point of the macros is that this shape stops being written out by
  # hand. A new `%{data: ...}` envelope written the long way should be
  # converted, not added alongside — otherwise the 22 grow back one at a time.
  test "no pure envelope is hand-written in schemas.ex" do
    source = File.read!(Path.join(__DIR__, "../../" <> @schemas_source))

    # Module by module — a body pattern that can span `end` would match a
    # `properties:` from one module against a `required:` from another.
    hand_written =
      ~r/  defmodule (\w+) do\n((?:(?!\n  end\n).)*)\n  end\n/s
      |> Regex.scan(source)
      |> Enum.filter(fn [_, _name, body] -> pure_envelope?(body) end)
      |> Enum.map(fn [_, name, _body] -> name end)

    assert hand_written == [],
           """
           These are pure `%{data: ...}` envelopes written by hand:

             #{Enum.join(hand_written, "\n  ")}

           Use `list_response(Name, of: Item)` or `item_response(Name, of: Item)`
           from FountainWeb.SchemaWrappers instead. If the envelope carries a
           `meta:` block it is not pure — those stay hand-written, see the
           SchemaWrappers moduledoc on pagination.
           """
  end

  # Exactly the two shapes the macros produce: `data` holding a schema module,
  # or an array of one. An envelope whose `data` is an inline object
  # (ApplyResponse, StripeUrlResponse, the admin outcome responses) is not
  # pure — it carries a shape of its own — and neither is one with a `meta`
  # block, which is what excludes the three paginated responses.
  @item_envelope ~r/properties: %\{\s*data: [A-Z][\w.]*\s*\},?\n\s*required: \[:data\]/
  @list_envelope ~r/properties: %\{\s*data: %Schema\{type: :array, items: [A-Z][\w.]*\}\s*\},?\n\s*required: \[:data\]/

  defp pure_envelope?(body) do
    Regex.match?(@item_envelope, body) or Regex.match?(@list_envelope, body)
  end
end
