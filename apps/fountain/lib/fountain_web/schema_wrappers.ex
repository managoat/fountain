defmodule FountainWeb.SchemaWrappers do
  @moduledoc """
  Declare the `%{data: ...}` envelope schemas every JSON collection uses.

  Twenty-two modules in `FountainWeb.Schemas` said nothing but "this response
  is one X" or "this response is a list of X", in nine lines each, and not
  even consistently — `ConversationListResponse` spelled across three lines
  what `TurnListResponse` said in one. They carry no knowledge: one
  description among the twenty-two.

      list_response(ConversationListResponse, of: Conversation)
      item_response(ConversationResponse, of: Conversation)

  `description:` is accepted for the rare envelope that has something to say.

  ## Scope

  Only the pure envelopes. The three paginated responses
  (`AdminUserListResponse`, `LogEventListResponse`, `AuditEventListResponse`)
  stay hand-written: they carry a `meta` block, and the API has two
  pagination idioms — cursor (`limit`/`has_more`/`next_cursor`) and offset
  (`page`/`per_page`/`total`). Folding those in would harden a choice between
  them that nobody has made yet, so it is deliberately left alone.

  ## Definition order still matters

  These expand to real `defmodule`s nested in `FountainWeb.Schemas`, so the
  item module must already be defined above the call — the implicit alias a
  nested `defmodule` creates only exists after it. That constraint predates
  this macro and is unchanged by it; `AdminAuditListResponse` still passes a
  fully qualified name because `AuditEvent` is defined further down the file.

  ## Update bodies

  `AgentUpdate`, `EnvironmentUpdate` and `VaultUpdate` were their request
  schemas again with `required:` deleted — about 200 lines that had already drifted
  once, when `AgentRequest` went without `allowed_environment_ids` that
  `AgentUpdate` declared.

      update_of(AgentUpdate, AgentRequest)

  Only for an update that is exactly its request made optional. A PATCH that
  accepts a field the create does not (`is_default`, `status`) or leaves out a
  create-time `default:` stays hand-written.
  """

  @doc "Define a `%{data: [item]}` response schema module."
  defmacro list_response(name, opts) do
    item = Keyword.fetch!(opts, :of)
    description = Keyword.get(opts, :description)

    quote do
      defmodule unquote(name) do
        @moduledoc false
        require OpenApiSpex

        OpenApiSpex.schema(
          FountainWeb.SchemaWrappers.envelope(
            __MODULE__,
            %OpenApiSpex.Schema{type: :array, items: unquote(item)},
            unquote(description)
          )
        )
      end
    end
  end

  @doc "Define a `%{data: item}` response schema module."
  defmacro item_response(name, opts) do
    item = Keyword.fetch!(opts, :of)
    description = Keyword.get(opts, :description)

    quote do
      defmodule unquote(name) do
        @moduledoc false
        require OpenApiSpex

        OpenApiSpex.schema(
          FountainWeb.SchemaWrappers.envelope(__MODULE__, unquote(item), unquote(description))
        )
      end
    end
  end

  @doc """
  Define `name` as `request` with no field required: the body of a partial
  update. The request must be defined above the call.
  """
  defmacro update_of(name, request) do
    quote do
      defmodule unquote(name) do
        @moduledoc false
        require OpenApiSpex

        OpenApiSpex.schema(FountainWeb.SchemaWrappers.partial(unquote(request).schema()))
      end
    end
  end

  @doc """
  The request schema as the map `OpenApiSpex.schema/1` expects, with nothing
  required and the title and `x-struct` left for the new module to fill.

  Raises on a top-level `default:`. OpenApiSpex writes defaults into the cast
  params, so an update carrying one would reset that field on every PATCH
  that omits it.
  """
  def partial(%OpenApiSpex.Schema{} = request) do
    defaulted =
      for {key, %OpenApiSpex.Schema{default: default}} <- request.properties,
          default != nil,
          do: key

    if defaulted != [] do
      raise ArgumentError,
            "#{request.title} cannot be an update body: #{inspect(defaulted)} " <>
              "have a default, which a PATCH omitting them would write back"
    end

    request
    |> Map.from_struct()
    |> Map.merge(%{title: nil, "x-struct": nil, required: nil})
  end

  @doc """
  The one description of `networking_config`, shared by `Environment` and
  `EnvironmentRequest` (and through it `EnvironmentUpdate`). It lives here
  rather than as a module attribute because each `Schemas.*` module is its own
  `defmodule` and attributes do not cross that boundary; three copies is how
  it went stale at ADR 0019 gate 2 (#1154).
  """
  def networking_config_description do
    "Refines networking_type: limited. allowed_hosts is the only key honored " <>
      "today; unknown keys are ignored. Where the policy is enforced depends on " <>
      "the account: on a brokered account (`brokered: true` on GET /api/auth/me) " <>
      "the sandbox can reach only the egress broker, and under limited the " <>
      "broker refuses any host not in allowed_hosts with a 403 that names it, " <>
      "while a host with a bound credential needs no entry. On an unbrokered " <>
      "account the sandbox itself allows only the allowlisted domains. Either " <>
      "way, limited with no allowed_hosts (or an empty list) is a deny-all, " <>
      "not an allow-all."
  end

  @doc """
  Build the envelope map `OpenApiSpex.schema/1` expects.

  The title is the module's own last segment, which is what all twenty-two
  hand-written envelopes used.
  """
  def envelope(module, data_schema, description) do
    envelope = %{
      title: module |> Module.split() |> List.last(),
      type: :object,
      properties: %{data: data_schema},
      required: [:data]
    }

    if description, do: Map.put(envelope, :description, description), else: envelope
  end
end
