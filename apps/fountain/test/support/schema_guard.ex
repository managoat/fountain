defmodule FountainWeb.SchemaGuard do
  @moduledoc """
  Does the response a controller rendered match the schema it declares?

  Every other check in this repository compares a schema with another schema.
  `sdk/contract` projects the OpenAPI document and pins four SDKs to it,
  `sdk/conformance` pins what those clients do with it, and both pass happily
  when the document itself is a lie about its own controller. Three defects of
  exactly that shape surfaced in one day (#1427): a `required` list naming
  properties the schema did not have (#1417), a declared field the action never
  renders (#1418), and a declared response body with no properties at all while
  the real one carries `upgrade_url`.

  This module is the missing side of the comparison. It takes a `%Plug.Conn{}`
  that has already been sent, finds the operation the router routed it to, and
  validates the rendered body against that operation's declared response schema
  for that status.

  It reports rather than raises. `FountainWeb.SchemaGuardrailTest` decides what
  is a failure and what is on the ratchet; a helper that flunked on its own
  could not be used to measure the ground truth first.
  """

  alias OpenApiSpex.{Cast, Reference, Schema}

  @router FountainWeb.Router
  @spec_module FountainWeb.ApiSpec
  @table :schema_guard_violations

  # ── wiring ──────────────────────────────────────────────────────────────────

  @doc """
  Watch every response the suite renders.

  Attached from `test_helper.exs`. `Plug.Telemetry` is already in the
  endpoint, so this costs nothing per test and sees every response any
  controller test produces — 146 operations, from tests that already exist.

  **Every app with a helper attaches it, and calling it again is a no-op.**
  Each umbrella app's helper runs in the same VM under a root `mix test`, and
  each extension attaches for its own standalone run (#1536). Naively that
  spawned a second keeper, which died on `:ets.new` against a table the first
  one already owns — harmless, but a crash report in every run. So a second
  call finds the table and returns.

  **It records rather than raises, and that is not a style choice.**
  `:telemetry` wraps a handler in a try/catch: a handler that raises is logged
  and then *detached*, so the raise fails nothing and every later response goes
  unchecked. Wired that way this guard reported a reintroduced #1417 and the
  suite still finished `7 tests, 0 failures`. Instead the violation is filed
  under the process that made the request, and `FountainWeb.ConnCase` fails
  that test on the way out.
  """
  @spec attach() :: :ok
  def attach do
    if :ets.whereis(@table) == :undefined do
      keeper =
        spawn(fn ->
          :ets.new(@table, [:public, :named_table, :duplicate_bag])
          Process.sleep(:infinity)
        end)

      # The table dies with its owner, so wait for the keeper to create it
      # before any request can look for it.
      wait_for_table(keeper, 200)
    end

    # `:already_exists` is the second helper attaching the same handler, which
    # is the intended outcome rather than a failure.
    case :telemetry.attach(
           "schema-guard",
           [:phoenix, :endpoint, :stop],
           &__MODULE__.handle/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  defp wait_for_table(_keeper, 0), do: raise("schema guard: the violations table never appeared")

  defp wait_for_table(keeper, attempts) do
    if :ets.whereis(@table) == :undefined do
      Process.sleep(5)
      wait_for_table(keeper, attempts - 1)
    else
      :ok
    end
  end

  @doc false
  def handle(_event, _measurements, %{conn: conn}, _config) do
    with {:violation, detail} <- check(conn),
         name = name(conn) || detail.operation,
         false <- FountainWeb.SchemaGuardAllowlist.allowed?(name, detail.status) do
      :ets.insert(@table, {self(), report(name, detail, conn)})
    end

    :ok
  catch
    # A guard that breaks the suite it guards is worse than no guard. Anything
    # unexpected here is recorded as itself rather than allowed to detach the
    # handler and silently stop checking.
    kind, error ->
      :ets.insert(
        @table,
        {self(), "schema guard raised #{inspect(kind)}: #{Exception.format(kind, error)}"}
      )

      :ok
  end

  @doc """
  Take everything recorded against a process. Called by `ConnCase` on the way
  out of each test, which is what turns a recorded violation into a failure.
  """
  @spec take(pid()) :: [String.t()]
  def take(pid) do
    case :ets.whereis(@table) do
      :undefined -> []
      _ -> @table |> :ets.take(pid) |> Enum.map(&elem(&1, 1))
    end
  end

  defp report(name, detail, conn) do
    """
    #{name} rendered a #{detail.status} that does not match its declared schema.

        #{detail.message}

    The response body was:

        #{String.slice(to_string(conn.resp_body), 0, 800)}

    The OpenAPI document is the wire contract for four SDKs (#1411), so a schema
    that disagrees with its controller propagates into all of them. Fix whichever
    is wrong — usually the schema in apps/fountain/lib/fountain_web/schemas.ex,
    sometimes the action.

    If it genuinely cannot be fixed now, add {"#{name}", #{detail.status}} to
    FountainWeb.SchemaGuardAllowlist with a reason and an issue, and raise the
    ceiling in FountainWeb.SchemaGuardrailTest in the same diff.
    """
  end

  @typedoc """
  What one response was worth.

  `:skip` is not a pass — it is "there was nothing here to check", and the
  reason says which kind of nothing, so a guard can tell an undocumented route
  from a 204 with no body.
  """
  @type result ::
          {:ok, operation_id :: String.t()}
          | {:skip, reason :: atom()}
          | {:violation, %{operation: String.t(), status: integer(), message: String.t()}}

  @doc """
  Check one sent connection.

  Returns `{:ok, operation_id}`, `{:skip, reason}` or `{:violation, detail}`.
  """
  # `:set` is the state a response is in at `register_before_send`, which is
  # where the telemetry the guardrail listens on fires. Status and body are both
  # populated by then; waiting for `:sent` would see nothing at all.
  @spec check(Plug.Conn.t()) :: result()
  def check(%Plug.Conn{state: state}) when state not in [:set, :sent, :chunked],
    do: {:skip, :not_sent}

  def check(%Plug.Conn{status: 204}), do: {:skip, :no_content}

  def check(%Plug.Conn{} = conn) do
    with {:ok, template} <- template(conn),
         {:ok, operation} <- operation(conn, template),
         {:ok, schema} <- response_schema(operation, conn) do
      validate(conn, operation, schema)
    end
  end

  @doc """
  Validate an already-decoded value against a named component schema.

  `check/1` above never reaches an SSE frame: its `decode/1` step only handles
  `content-type: application/json`, and a stream is `text/event-stream`. A
  frame is not a `%Plug.Conn{}` response either — it is one `data:` line out of
  many chunks written to an open connection — so a test that wants a frame
  checked against `StreamLogEvent` (#2297) parses it out by hand and calls this
  directly rather than going through `check/1`.
  """
  @spec validate_value(module(), term()) :: :ok | {:error, String.t()}
  def validate_value(schema_module, value) do
    spec = spec()

    context = %Cast{
      value: value,
      schema: schema_module.schema(),
      schemas: spec.components.schemas,
      read_write_scope: :read
    }

    case Cast.cast(context) do
      {:ok, _} -> :ok
      {:error, errors} -> {:error, Enum.map_join(errors, "; ", &Cast.Error.message_with_path/1)}
    end
  end

  @doc """
  Every documented operation, as `"METHOD /path/{template}"`.

  The same spelling `sdk/contract/contract.json` uses, so a name is the same
  string in both halves of the guard and in an allowlist a person reads.
  """
  @spec operations() :: [String.t()]
  def operations do
    spec = spec()

    for {path, item} <- spec.paths,
        {method, operation} <- Map.from_struct(item),
        match?(%OpenApiSpex.Operation{}, operation),
        do: {"#{method |> to_string() |> String.upcase()} #{path}", operation.operationId}
  end

  @doc "The `METHOD /template` name for a conn, or nil when it routed nowhere documented."
  @spec name(Plug.Conn.t()) :: String.t() | nil
  def name(%Plug.Conn{} = conn) do
    case template(conn) do
      {:ok, template} -> "#{conn.method} #{template}"
      _ -> nil
    end
  end

  # ── resolution ──────────────────────────────────────────────────────────────

  # Phoenix spells a path parameter `:id`; OpenAPI spells it `{id}`. Going
  # through the router rather than pattern-matching the request path is what
  # makes this exact: two operations can share a controller action (the PUT
  # aliases of the PATCH routes all report `AgentController.update`), so the
  # action alone cannot say which operation answered.
  defp template(%Plug.Conn{} = conn) do
    case Phoenix.Router.route_info(@router, conn.method, conn.request_path, conn.host) do
      :error ->
        {:skip, :no_route}

      # An extension's routes sit behind `forward "/", ExtensionDispatch`, and a
      # forward is opaque to `route_info/4`: the core router reports the
      # forward's own route, `/api`, which matches no documented path. So every
      # extension response was skipped as `:undocumented` and the guard has
      # never seen one (ADR 0043, #1536). Re-resolve through the mount.
      %{plug: FountainWeb.Plugs.ExtensionDispatch} ->
        extension_template(conn)

      %{route: route} ->
        {:ok, spell(route)}

      _ ->
        {:skip, :no_route}
    end
  end

  # `Fountain.Extensions` is the host's own registry, so this reads no
  # extension module and crosses no ADR 0043 boundary.
  defp extension_template(%Plug.Conn{} = conn) do
    segments = conn.request_path |> String.split("/", trim: true) |> Enum.drop(1)

    with {_ext, mount, plug} when is_atom(plug) <- Fountain.Extensions.find_mount(segments),
         under = segments |> Enum.drop(length(mount)) |> Enum.join("/"),
         %{route: route} <-
           Phoenix.Router.route_info(plug, conn.method, "/" <> under, conn.host) do
      {:ok, spell("/api/" <> Enum.join(mount, "/") <> route)}
    else
      _ -> {:skip, :no_route}
    end
  end

  defp spell(route), do: Regex.replace(~r/:([a-zA-Z_][a-zA-Z0-9_]*)/, route, "{\\1}")

  defp operation(conn, template) do
    spec = spec()

    with %OpenApiSpex.PathItem{} = item <- Map.get(spec.paths, template, :none),
         %OpenApiSpex.Operation{} = operation <-
           Map.get(Map.from_struct(item), method_key(conn.method), :none) do
      {:ok, operation}
    else
      _ -> {:skip, :undocumented}
    end
  end

  defp method_key(method), do: method |> String.downcase() |> String.to_existing_atom()

  # A response the operation does not declare at all is a finding for the
  # guardrail to weigh, not something to pass over: an endpoint that answers
  # 404 while documenting only 200 is the same class of lie as a wrong field.
  defp response_schema(operation, conn) do
    responses = operation.responses || %{}

    case Map.get(responses, conn.status) || Map.get(responses, "#{conn.status}") do
      nil ->
        {:violation,
         %{
           operation: operation.operationId,
           status: conn.status,
           message:
             "the operation declares no #{conn.status} response. It declares: " <>
               (responses |> Map.keys() |> Enum.map_join(", ", &to_string/1))
         }}

      response ->
        schema =
          response
          |> resolve_response()
          |> Map.get(:content, %{})
          |> Map.get(content_type(conn), %{})
          |> Map.get(:schema)

        if schema, do: {:ok, schema}, else: {:skip, :no_json_schema}
    end
  end

  defp resolve_response(%Reference{} = ref),
    do: Reference.resolve_response(ref, spec().components.responses)

  defp resolve_response(response), do: response

  defp content_type(conn) do
    conn
    |> Plug.Conn.get_resp_header("content-type")
    |> List.first()
    |> to_string()
    |> String.split(";")
    |> List.first()
    |> String.trim()
  end

  # ── validation ──────────────────────────────────────────────────────────────

  defp validate(conn, operation, schema) do
    with {:ok, body} <- decode(conn) do
      spec = spec()
      resolved = resolve_schema(schema, spec)

      context = %Cast{
        value: body,
        schema: resolved,
        schemas: spec.components.schemas,
        # A response is read side: a `writeOnly` property being absent is
        # correct, not missing.
        read_write_scope: :read
      }

      case Cast.cast(context) do
        {:ok, _} ->
          {:ok, operation.operationId}

        {:error, errors} ->
          {:violation,
           %{
             operation: operation.operationId,
             status: conn.status,
             message: Enum.map_join(errors, "; ", &Cast.Error.message_with_path/1)
           }}
      end
    end
  end

  defp resolve_schema(%Reference{} = ref, spec),
    do: Reference.resolve_schema(ref, spec.components.schemas)

  defp resolve_schema(%Schema{} = schema, _spec), do: schema
  defp resolve_schema(other, _spec), do: other

  defp decode(conn) do
    if String.contains?(content_type(conn), "json") do
      case Jason.decode(conn.resp_body) do
        {:ok, body} -> {:ok, body}
        {:error, _} -> {:skip, :body_not_json}
      end
    else
      {:skip, :not_json}
    end
  end

  # Cached per test run, and keyed by the one thing a deployment can vary in
  # its own document: whether it names a fixture account, which decides if
  # `fountain-fixture` is in its runtime enums (#1716). A test that toggles
  # that config expects to be measured against the spec it is then serving.
  defp spec do
    key = {__MODULE__, :spec, Fountain.DeployedACPFixture.configured?()}

    case :persistent_term.get(key, nil) do
      nil ->
        spec = OpenApiSpex.resolve_schema_modules(@spec_module.spec())
        :persistent_term.put(key, spec)
        spec

      spec ->
        spec
    end
  end
end
