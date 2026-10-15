defmodule Managoat.ACP.Elicitation do
  @moduledoc """
  What answers ACP's `elicitation/create`, in form mode (#2492).

  A client that declares `elicitation: %{form: %{}}` on `initialize` may be
  sent `elicitation/create`: the agent blocks on a form, described by a
  restricted JSON Schema (`requestedSchema`, an object of primitive-typed
  properties), and the client answers with one of three actions.

  | action | meaning |
  |---|---|
  | `accept` | the person filled the form; `content` maps property names to values |
  | `decline` | the person saw it and said no |
  | `cancel` | the form was dismissed without a choice |

  claude-agent-acp (0.81.2) sends it for three things once form elicitation is
  declared, and only then: its `AskUserQuestion` tool (removed from the
  toolset otherwise), an MCP server's form elicitation (auto-declined by the
  SDK otherwise), and the CLI's refusal-fallback consent prompt ("retry with
  another model?", which otherwise ends the turn with the refusal). All three
  arrive as the same request, so the host treats them the same way: hold it
  for a human, like an `ask` permission request.

  `AskUserQuestion`'s one to four questions arrive as **one** form: each
  question is a `question_<n>` property (a `oneOf` string for a single select,
  an `anyOf` array for a multi select) followed by a free-text
  `question_<n>_custom` property. The adapter folds the accepted content back
  into the tool's answers; `decline` tells the model the person skipped the
  questions, and `cancel` aborts the tool call.

  Nothing here is answered on a person's behalf except by declining: the
  timeout, the turn's end and a request for another session all decline,
  which the adapter reads as "skipped" rather than as an answer. A url-mode
  elicitation is declined at once, because Managoat does not declare url
  mode.

  The answer is checked against the schema the agent sent before it is
  forwarded — the same fail-closed rule `Managoat.ACP.Permissions` applies to
  option ids: a property the form did not ask for, a value of the wrong type,
  or a choice the form did not offer is refused rather than passed on.
  """

  @actions ~w(accept decline cancel)

  @doc "The three answer actions, as wire strings."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "Whether `capabilities` (the client's, as declared) include form elicitation."
  @spec form_declared?(map() | nil) :: boolean()
  def form_declared?(capabilities) when is_map(capabilities) do
    case Map.get(capabilities, :elicitation) || Map.get(capabilities, "elicitation") do
      %{} = elicitation -> is_map(Map.get(elicitation, :form) || Map.get(elicitation, "form"))
      _ -> false
    end
  end

  def form_declared?(_), do: false

  @doc "Whether the request's params are a form-mode elicitation (the default mode)."
  @spec form?(map()) :: boolean()
  def form?(params) when is_map(params), do: Map.get(params, "mode", "form") == "form"
  def form?(_), do: false

  @doc "The request's `requestedSchema`, or an empty object schema."
  @spec schema(map()) :: map()
  def schema(%{"requestedSchema" => %{} = schema}), do: schema
  def schema(_), do: %{"type" => "object", "properties" => %{}}

  @doc "The request's message, or `\"\"`."
  @spec message(map()) :: String.t()
  def message(%{"message" => message}) when is_binary(message), do: message
  def message(_), do: ""

  @doc "The JSON-RPC result that declines."
  @spec decline() :: map()
  def decline, do: %{action: "decline"}

  @doc """
  The JSON-RPC result for an answer, after checking it against `schema`.

  `content` is read only for `accept`; for `decline` and `cancel` it must be
  absent or empty, so a client cannot believe it sent values that were
  dropped.
  """
  @spec result(map(), String.t(), map() | nil) ::
          {:ok, map()} | {:error, :unknown_action | {:invalid_content, String.t()}}
  def result(schema, "accept", content) do
    content = content || %{}

    with :ok <- check_content(schema, content) do
      {:ok, %{action: "accept", content: content}}
    end
  end

  def result(_schema, action, content) when action in ["decline", "cancel"] do
    if content in [nil, %{}],
      do: {:ok, %{action: action}},
      else: {:error, {:invalid_content, "content is only sent with action accept"}}
  end

  def result(_schema, _action, _content), do: {:error, :unknown_action}

  defp check_content(schema, content) when is_map(content) do
    properties = Map.get(schema, "properties") || %{}
    required = List.wrap(Map.get(schema, "required"))

    with :ok <- check_required(required, content) do
      Enum.reduce_while(content, :ok, fn {key, value}, :ok ->
        case Map.fetch(properties, key) do
          {:ok, property} ->
            case check_value(property, value) do
              :ok -> {:cont, :ok}
              {:error, why} -> {:halt, {:error, {:invalid_content, "#{key}: #{why}"}}}
            end

          :error ->
            {:halt, {:error, {:invalid_content, "#{key}: not a field of this form"}}}
        end
      end)
    end
  end

  defp check_content(_schema, _content),
    do: {:error, {:invalid_content, "content must be an object"}}

  defp check_required(required, content) do
    case Enum.reject(required, &Map.has_key?(content, &1)) do
      [] -> :ok
      missing -> {:error, {:invalid_content, "missing required #{Enum.join(missing, ", ")}"}}
    end
  end

  defp check_value(%{"type" => "string"} = property, value) when is_binary(value) do
    case choices(property) do
      nil -> :ok
      allowed -> if value in allowed, do: :ok, else: {:error, "not one of the offered choices"}
    end
  end

  defp check_value(%{"type" => "number"}, value) when is_number(value), do: :ok
  defp check_value(%{"type" => "integer"}, value) when is_integer(value), do: :ok
  defp check_value(%{"type" => "boolean"}, value) when is_boolean(value), do: :ok

  defp check_value(%{"type" => "array"} = property, value) when is_list(value) do
    allowed = choices(Map.get(property, "items") || %{})

    cond do
      not Enum.all?(value, &is_binary/1) -> {:error, "must be a list of strings"}
      is_nil(allowed) -> :ok
      Enum.all?(value, &(&1 in allowed)) -> :ok
      true -> {:error, "not one of the offered choices"}
    end
  end

  # A property type ACP's schema does not name: accept any value its content
  # union allows, and let the agent judge it.
  defp check_value(%{"type" => type}, value)
       when type not in ~w(string number integer boolean array) do
    if content_value?(value), do: :ok, else: {:error, "unsupported value"}
  end

  defp check_value(%{"type" => type}, _value), do: {:error, "must be a #{type}"}

  defp check_value(_property, value),
    do: if(content_value?(value), do: :ok, else: {:error, "unsupported value"})

  # The offered values of a select: `enum`, or the `const` of each titled
  # `oneOf` (single) / `anyOf` (multi) option. nil for a free-text field.
  defp choices(property) do
    cond do
      is_list(property["enum"]) -> property["enum"]
      is_list(property["oneOf"]) -> consts(property["oneOf"])
      is_list(property["anyOf"]) -> consts(property["anyOf"])
      true -> nil
    end
  end

  defp consts(options), do: for(%{"const" => c} <- options, do: c)

  defp content_value?(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: true

  defp content_value?(value) when is_list(value), do: Enum.all?(value, &is_binary/1)
  defp content_value?(_), do: false
end
