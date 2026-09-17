defmodule Fountain.Conversations.Turn do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Conversations.{Conversation, TurnImage}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running completed failed interrupted)
  # `user`: a prompt somebody sent. `autonomous`: a turn the server opened
  # for a background cycle that ran after the prompt was answered (#817) —
  # the prompt column then carries a marker, not a person's words.
  @origins ~w(user autonomous)
  # The API schema declares the same bound, so a request is refused at the
  # door (422) and this is the backstop for a caller that is not the API.
  @client_request_id_max 200
  # The one character the id may not contain. PostgreSQL rejects U+0000 in a
  # text column with 22021, from inside an insert nothing rescues: an ordinary
  # prompt would end its conversation server over its label. The API schema
  # declares this pattern (`Schemas.ClientRequestId`), which makes it a 422 at
  # the door; `has_nul?/1` below is the same rule for a caller that is not the
  # API, and "the door's pattern and the row agree about NUL"
  # (`PromptCorrelationTest`) pins the two statements together.
  @client_request_id_pattern ~S(^[^\x00]*$)

  schema "turns" do
    field :turn_number, :integer
    field :prompt, :string
    field :status, :string, default: "pending"
    field :exit_code, :integer
    # A service-enforced limit is incomplete even if a late runtime exits zero.
    field :limit_reason, :string
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    # Set when Fountain, rather than the runtime or the user, reconciles a
    # running turn that no longer has anything driving it. Billing and usage
    # exclude these intervals because the true end of work is unknowable.
    field :orphaned_at, :utc_datetime
    # JSON-RPC id of the ACP `session/prompt` in flight; nil on the legacy
    # path and until the peer has written the prompt. See the migration.
    field :acp_prompt_id, :integer
    # The `session/request_permission` this turn is blocked on (#940): the
    # agent's JSON-RPC id, the tool, and the options it offered. nil whenever
    # nothing is outstanding. Persisted so a request raised before a deploy is
    # still answerable after one.
    field :pending_permission, :map
    # The turn ended with that request still open (#1635): the agent answered
    # `session/prompt` with the `waiting` stop reason instead of holding the
    # turn until a human decided. The turn is `completed`, the conversation is
    # `idle` and the sandbox may park; the request stays on the row until it
    # is answered or `permission_deadline` passes. False on every other turn.
    field :waiting, :boolean, default: false
    # When a detached request is denied for want of an answer. A column rather
    # than a key inside `pending_permission` because the sweep that fires it
    # (`Fountain.Workers.DetachedRequestSweeper`) is an indexed query, and
    # because a process timer cannot outlive the suspend this whole path
    # exists to allow. nil while nothing is waiting.
    field :permission_deadline, :utc_datetime
    # The turn's token usage as the runtime reported it when the turn ended
    # (#827): `%{"input" => n, "output" => n, "cache_read" => n?,
    # "cache_write" => n?}`. Written once by `Conversations._unsafe_record_turn_usage/2`,
    # never summed from the live `usage_update`s (their meaning differs per
    # runtime). Optional "accounting" preserves adapter scope/version/completeness;
    # it may be the only key when token counts are unknown. nil when nothing was reported.
    #
    # Two more keys, written at turn start rather than at its end (#1685):
    # "inference" (and, on a platform turn, "model") — see
    # `inference_stamp_only?/1`.
    field :usage, :map
    field :inference_source, :map
    # ACP selection evidence, distinct from the agent's saved configuration.
    field :model_selection, :map
    # The assistant's text for the turn — its events' `text` blocks, joined —
    # materialised by `Conversations._unsafe_update_turn/2` when the turn
    # ends, for `Fountain.Search` (#826). nil while the turn runs and on
    # turns that predate the column (see `Fountain.Release.backfill_turn_replies/0`).
    field :reply_text, :string
    field :origin, :string, default: "user"
    # The caller's name for the prompt that opened this turn (#1406), so a
    # client can bind its own work item to the turn without inferring it from
    # turn order. nil when the caller sent none, and on every autonomous turn.
    # A correlation, not an idempotency key: it is not unique.
    field :client_request_id, :string
    belongs_to :conversation, Conversation
    has_many :images, TurnImage, preload_order: [asc: :position]
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def statuses, do: @statuses
  def origins, do: @origins
  def client_request_id_max, do: @client_request_id_max
  def client_request_id_pattern, do: @client_request_id_pattern

  @doc """
  Whether this id carries the one character a turn cannot store (#1406).

  The door refuses it with 422. `PromptDelivery.travelling/1` asks this before
  it changes a prompt's message shape, and `changeset/2` asks it again, so an
  id that would raise 22021 at the insert never reaches turn admission.
  """
  @spec has_nul?(String.t()) :: boolean()
  def has_nul?(value) when is_binary(value), do: String.contains?(value, <<0>>)

  @doc """
  Put the caller's `client_request_id` (#1406) on a `turn` / `started` stage
  event, beside its `turn_id`. That event is how a client following the stream
  finds a candidate turn. It is not the record: `log!/1` redacts every event's
  data, so an id holding a registered environment value reaches its event with
  `[REDACTED]` in that place — a string another client may legally have sent as
  its own id. The row is what the caller sent, and the manual tells a client to
  confirm a candidate against it. A turn whose caller sent none leaves the
  event in the shape it always had.
  """
  @spec correlate(t(), map()) :: map()
  def correlate(%__MODULE__{client_request_id: id}, meta) when is_binary(id),
    do: Map.put(meta, :client_request_id, id)

  def correlate(%__MODULE__{}, meta), do: meta

  # The two keys the turn-start inference stamp writes (#1685). Both are also
  # written by `TurnMachine.with_inference/2` at the end of a turn that
  # answers its prompt, which is why the late write merges over the early one
  # rather than colliding with it.
  @inference_stamp_keys ~w(inference model)

  @doc """
  Whether this `usage` map is the turn-start inference stamp and nothing else
  (#1685) — the turn ran on a known inference source, and no token figure has
  been recorded for it.

  Such a row exists so the platform-inference pass can see the turn at all: a
  turn that ends any way other than a `session/prompt` response never reaches
  `{:done, ...}`, and before #1685 left no trace of whose key it spent. It is
  not an end-of-turn usage record, so the two places that treat a usage map as
  one — the "already recorded" refusal in
  `Conversations._unsafe_record_turn_usage/2` and the API's turn `usage` field
  — ask this first.

  An `"accounting"`-only map (a runtime that reported its scope but no counts)
  is *not* a stamp: that is a real end-of-turn record, and a second one must
  still be refused.

  An **empty** map is a stamp by this test, because every key it has is in the
  set. That is a widening rather than a decision, and it is safe twice over:
  `Managoat.ACP.Usage.normalize/1` returns `nil` or a map carrying both
  counters, so no runtime produces one; and a row holding `%{}` debited
  nothing, so accepting a later figure over it debits exactly once.
  """
  @spec inference_stamp_only?(map()) :: boolean()
  def inference_stamp_only?(%{} = usage), do: Map.keys(usage) -- @inference_stamp_keys == []

  def changeset(turn, attrs) do
    turn
    |> cast(attrs, [
      :turn_number,
      :prompt,
      :status,
      :inference_source,
      :exit_code,
      :limit_reason,
      :started_at,
      :ended_at,
      :orphaned_at,
      :acp_prompt_id,
      :pending_permission,
      :waiting,
      :permission_deadline,
      :usage,
      :model_selection,
      :reply_text,
      :origin,
      :conversation_id
    ])
    |> cast_client_request_id(attrs)
    |> validate_required([:turn_number, :prompt, :status, :conversation_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:origin, @origins)
    |> validate_length(:client_request_id, min: 1, max: @client_request_id_max)
    |> validate_change(:client_request_id, &refuse_nul/2)
    |> unique_constraint([:conversation_id, :turn_number])
  end

  defp refuse_nul(:client_request_id, value) do
    if has_nul?(value), do: [client_request_id: "cannot contain a null character"], else: []
  end

  # The caller's id is an opaque label, so it is stored as it was sent. Ecto
  # trims a string before it decides the value is empty, which turns an id of
  # spaces into `nil`: the response would echo the id the caller sent while the
  # turn carried none, and the started event would omit the field the caller is
  # waiting for. Casting it untrimmed leaves only a literal "" reading as "the
  # caller sent none", which is what the API (minLength 1) and
  # `PromptDelivery.travelling/1` already refuse to carry.
  defp cast_client_request_id(changeset, attrs),
    do: cast(changeset, attrs, [:client_request_id], trim_values: fn _type, value -> value end)
end
