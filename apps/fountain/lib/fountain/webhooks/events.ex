defmodule Fountain.Webhooks.Events do
  @moduledoc """
  The webhook event catalogue: which stage transitions become
  `conversation.<stage>.<status>`, and what an endpoint's filter may say.

  `Fountain.Conversations.publish_stage/4` is the single chokepoint every
  operationally meaningful outcome flows through, so hanging dispatch off it
  means a new lifecycle outcome cannot be added without subscribers seeing it.
  The list below is that guarantee written down: `webhook_events_test.exs`
  reads the `publish_stage/4` call sites out of the source and fails if one
  produces a type this module does not name.

  `kind: "output"` rows are deliberately absent. A chatty turn writes
  thousands of stdout chunks, and turning those into HTTP POSTs is a
  self-inflicted denial of service on both ends. Streaming output is what
  `GET /api/conversations/:id/events` is for.

  `@retired` is the other list: stages Fountain **used** to publish and never
  will again. They are not in `types/0`, not in the catalogue the manual
  renders, and **not accepted by `valid_filter?/1`** — nobody may subscribe to
  one, because an endpoint that did would look saved and receive nothing,
  which is exactly the outcome save-time validation exists to prevent.

  `retired_filter?/1` is the narrow exception, and it is about *existing* rows
  only. An endpoint's whole `event_types` array is re-validated on every update
  (`Webhooks.Endpoint.validate_event_types/1`), so a row that already carries a
  retired type would be refused the next time its owner changed the URL — made
  uneditable by a removal it had no part in. `validate_event_types/1` therefore
  grandfathers a retired value it finds unchanged on the stored row, and
  refuses one on create or newly added on update. Keeping such a value costs
  nothing: it matches no type, so it never fires, and `matches?/2` is a string
  compare that never consults this module.

  That also keeps the code release reversible, which ADR 0057 requires while
  the physical tool definitions remain: rolling back restores the emitter and
  finds the filters that consumed it still in place, rather than a subscription
  someone's migration rewrote. Delete an entry here only once the rollback
  floor has moved past the release that retired it — for `caller_tool`, the
  same gate as [#2273](https://github.com/managoat/fountain/issues/2273).
  """

  # stage => the statuses that stage is published with.
  @catalogue [
    {"provision", ~w(started done failed)},
    {"clone", ~w(started done failed)},
    {"packages", ~w(started done failed)},
    {"network", ~w(started done failed)},
    {"broker", ~w(started done failed)},
    {"setup", ~w(started done failed)},
    {"checkpoint_restore", ~w(started done failed)},
    {"checkpoint", ~w(done failed)},
    {"reattach", ~w(started done failed interrupted)},
    {"wake", ~w(failed)},
    {"connection", ~w(started done)},
    {"turn", ~w(started done failed interrupted)},
    {"request", ~w(started done)},
    {"model", ~w(done failed)},
    {"config", ~w(done failed)},
    {"session", ~w(done)},
    {"sandbox", ~w(done)},
    {"configuration", ~w(done failed)},
    {"terminate", ~w(done)}
  ]

  @types for {stage, statuses} <- @catalogue,
             status <- statuses,
             do: "conversation.#{stage}.#{status}"

  # Retired stages: still accepted as a filter, never emitted. The moduledoc
  # says why these are not simply deleted.
  @retired [{"caller_tool", ~w(started done)}]

  @retired_types for {stage, statuses} <- @retired,
                     status <- statuses,
                     do: "conversation.#{stage}.#{status}"

  # What a new endpoint subscribes to when it names nothing. The three an
  # integrator almost always wants; everything else is opt-in.
  @defaults ~w(conversation.turn.done conversation.turn.failed conversation.provision.failed)

  @doc "Every event type this instance can emit, in catalogue order."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The catalogue as `{stage, statuses}` pairs — what the docs page renders."
  @spec catalogue() :: [{String.t(), [String.t()]}]
  def catalogue, do: @catalogue

  @doc "The default subscription for an endpoint that names no event types."
  @spec defaults() :: [String.t()]
  def defaults, do: @defaults

  @doc "The event type for a stage transition."
  @spec type(String.t(), String.t()) :: String.t()
  def type(stage, status), do: "conversation.#{stage}.#{status}"

  @doc "Whether `type` is in the catalogue."
  @spec known?(String.t()) :: boolean()
  def known?(type), do: type in @types

  @doc """
  Stages that were published once and are not any more, as `{stage, statuses}`.

  Not subscribable: `valid_filter?/1` refuses them. `retired_filter?/1`
  recognises them so `Webhooks.Endpoint` can grandfather one already stored on
  a row, which is what keeps that row editable.
  """
  @spec retired() :: [{String.t(), [String.t()]}]
  def retired, do: @retired

  @doc """
  Whether `entry` is something an endpoint may subscribe to.

  Three shapes: `"*"` (everything), a trailing wildcard over one stage
  (`"conversation.turn.*"`), or an exact type from the catalogue. A typo in
  an exact type is rejected at create time rather than silently subscribing
  to nothing.
  """
  @spec valid_filter?(term()) :: boolean()
  def valid_filter?("*"), do: true

  def valid_filter?(entry) when is_binary(entry) do
    case String.split(entry, ".") do
      ["conversation", stage, "*"] -> List.keymember?(@catalogue, stage, 0)
      _ -> known?(entry)
    end
  end

  def valid_filter?(_), do: false

  @doc """
  Whether `entry` names a retired stage — an exact type or its wildcard.

  Not a licence to subscribe. `Webhooks.Endpoint` asks this only about a value
  it found already stored on the row it is updating, so that removing a stage
  from the catalogue does not make such a row impossible to edit.
  """
  @spec retired_filter?(term()) :: boolean()
  def retired_filter?(entry) when is_binary(entry) do
    case String.split(entry, ".") do
      ["conversation", stage, "*"] -> List.keymember?(@retired, stage, 0)
      _ -> entry in @retired_types
    end
  end

  def retired_filter?(_), do: false

  @doc "Whether an endpoint subscribing to `filters` wants `type`."
  @spec matches?([String.t()], String.t()) :: boolean()
  def matches?(filters, type) when is_list(filters) do
    Enum.any?(filters, &filter_matches?(&1, type))
  end

  defp filter_matches?("*", _type), do: true

  defp filter_matches?(filter, type) do
    case String.split(filter, ".") do
      ["conversation", stage, "*"] -> String.starts_with?(type, "conversation.#{stage}.")
      _ -> filter == type
    end
  end
end
