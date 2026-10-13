defmodule Fountain.Audit do
  @moduledoc """
  Append-only audit log for state-changing actions.

  Each event is attributed to a tenant via `user_id`. Pre-tenancy rows
  and system-originated events have `user_id = nil` and are only
  surfaced through admin views.

  Logging is best-effort: a log failure must never break the operation
  it's recording. Use `record!/1` only when you can tolerate raising;
  default to `record/1`.

  Best-effort means *rescuing*, which does not survive a transaction: a failed
  insert inside one aborts the enclosing transaction. Call this outside the
  transaction whose work you are recording — `Accounts.Deletion`,
  `Agents.upload_avatar/4` and `Accounts.register_user/2` all do.

  ## Where events come from

  Mutations audit **inside the context function**, not at each caller, so the
  UI, the API, background workers and any future surface are covered by
  construction rather than by remembering. Callers pass only what a context
  cannot know about its caller — `:actor` and `:request_ip`, from
  `FountainWeb.Audited.attribution/2` on a web surface, or a
  `"system:<worker>"` string from a background one.

  ADR 0013 owns this rule and the closed actor vocabulary (`self`, `ui`,
  `api`, `sprite`, `admin`, `admin:<id>`, `system:<worker>`); this moduledoc
  keeps the mechanics.

  The four conversation lifecycle events (`conversation.prompted`,
  `interrupted`, `terminated`, `released`) follow the same rule from the
  verb's owner: `Conversations.Termination.audit_lifecycle/5` records them
  after the server reply and outside any transaction, called from
  `Conversations.Termination`, `Conversations.Interruption` and the prompt
  door on `ConversationServer` (#2175). The interrupted-turn row writes
  (`Conversations.Interruption._unsafe_interrupt_turn/2` and
  `_unsafe_idle_interrupted_turn/1`, still reachable by their old names on
  `Conversations`) are conditional bookkeeping and record nothing themselves.

  ## Deliberately not audited

  High-volume machine state is not audit material, and recording it would bury
  the events that are. These are decisions, not oversights (#551):

    * `ConversationServer`'s per-turn state-machine writes — turn started,
      output chunk, turn ended. The conversation's own log events already hold
      this, at the right granularity.
    * `Accounts.touch_api_key/1` — a last-used stamp on every authenticated
      request. The key's *creation* and *revocation* are audited; its use is
      what the request log is for.
    * `Conversations.mark_read/2` and theme/preference updates — reading and
      display settings are not state changes anyone audits.

  One system path records a **summary per run** rather than per row, for the
  same reason: `Workers.RetentionPruner`, which deletes `audit_events`, so the
  trail must be able to account for its own shrinkage.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Audit.AdminEvent
  alias Fountain.Audit.Event
  alias Fountain.Repo

  @type attrs :: %{
          required(:action) => String.t(),
          required(:resource_type) => String.t(),
          optional(:resource_id) => String.t() | nil,
          optional(:actor) => String.t() | nil,
          optional(:request_ip) => String.t() | nil,
          optional(:metadata) => map(),
          optional(:user_id) => Ecto.UUID.t() | nil
        }

  @spec record(attrs()) :: {:ok, Event.t()} | {:error, term()}
  def record(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:metadata, %{})
      |> Map.put_new(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))

    case %Event{} |> Event.changeset(attrs) |> Repo.insert() do
      {:ok, _event} = ok ->
        ok

      {:error, changeset} = err ->
        if user_gone?(changeset), do: record_unattributed(attrs), else: err
    end
  rescue
    e ->
      require Logger
      Logger.warning("audit: record failed: #{inspect(e)}")
      {:error, :exception}
  end

  # The account was deleted between the action and this write, so `user_id`
  # references a row that no longer exists.
  #
  # The row is kept, attributed to nobody, because that is where it was headed
  # regardless: `audit_events.user_id` is `on_delete: :nilify_all`, so an
  # insert that had landed a moment earlier would have been accepted and then
  # nilified by the same cascade. Losing it is a race, not a policy — and the
  # trail of a deletion is the last thing that should have a hole in it (#590).
  #
  # The id is deliberately NOT denormalised into `metadata`. Nilifying is what
  # makes a deleted account stop naming anybody (ADR 0009); putting the id back
  # would defeat that on every self-deleting path. `Accounts.Deletion` does
  # denormalise, for one row, as a documented exception — this is not that.
  defp record_unattributed(attrs) do
    Logger.info(
      "audit: #{attrs[:action]} recorded unattributed — the account was deleted " <>
        "before the event could be written"
    )

    case %Event{} |> Event.changeset(Map.put(attrs, :user_id, nil)) |> Repo.insert() do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end

  # Ecto reports this as `constraint: :foreign` (not `:foreign_key`), and only
  # for `:user_id` — a failure on any other field is a real error and must
  # still surface rather than being rewritten into a system event.
  defp user_gone?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:user_id, {_msg, opts}} -> Keyword.get(opts, :constraint) == :foreign
      _ -> false
    end)
  end

  @doc """
  Record and raise on failure.

  **Deliberately unused in `lib/`** (#552). Every production call site wants
  `record/1`: a logging failure must never break the operation being logged,
  and there is no mutation in this system where losing the audit row is worse
  than failing the mutation itself — account deletion included, which
  denormalises the identifying fields into `metadata` precisely so its event
  stands alone.

  It stays because the test suite uses it to seed trails, where a silently
  dropped row would make the assertion below it vacuous. Reach for it in a
  test; do not reach for it in `lib/`.
  """
  @spec record!(attrs()) :: Event.t()
  def record!(attrs) do
    {:ok, event} = record(attrs)
    event
  end

  @doc """
  Record a mutation of an owned resource, from inside the context that made it.

      Audit.record_resource("agent.created", "agent", agent, opts)

  Auditing used to depend on which door a mutation came through: the `:api`
  pipeline plug covered every write, and the browser surface covered whatever
  its LiveView remembered to record. Resource CRUD landed on the wrong side of
  that — audited via `/api`, silent via the UI (#543). Recording inside the
  context covers UI, API, manifest apply and any future
  caller from one place.

  The resource supplies `user_id`, `id` and `name`; the caller supplies
  `:actor` and `:request_ip` (see `FountainWeb.Audited.attribution/2`) and any
  extra `:metadata`. Values are never recorded — only which fields moved — so
  this cannot become a second copy of anything a resource holds.
  """
  @spec record_resource(String.t(), String.t(), struct(), keyword()) ::
          {:ok, Event.t()} | {:error, term()}
  def record_resource(action, resource_type, resource, opts \\ []) do
    record(%{
      user_id: Map.get(resource, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: Map.get(resource, :id),
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata:
        %{"name" => Map.get(resource, :name)}
        |> Map.merge(Keyword.get(opts, :metadata, %{}))
    })
  end

  @doc """
  The names of the fields a changeset actually moves, sorted, as metadata.

  "What changed" is the whole value of an update event — an `agent.updated`
  row that does not say which fields moved is barely more than a timestamp.
  Names only: field *values* are the tenant's data, and the audit trail is
  not a place to keep a second copy of it.
  """
  @spec changed_fields(Ecto.Changeset.t()) :: map()
  def changed_fields(%Ecto.Changeset{changes: changes}) do
    %{"changed" => changes |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()}
  end

  @doc """
  Record an administrative action taken against another user.

  Separate from `record/1` because these need both an actor and a target, which
  `audit_events` cannot express. Best-effort on the same terms.
  """
  @spec record_admin(map()) :: {:ok, AdminEvent.t()} | {:error, term()}
  def record_admin(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:metadata, %{})
      |> Map.put_new(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))

    case %AdminEvent{} |> AdminEvent.changeset(attrs) |> Repo.insert() do
      {:ok, _} = ok ->
        ok

      {:error, changeset} = err ->
        # Callers ignore this return by design (best-effort), so a rejected
        # write — usually an event type missing from the AdminEvent allowlist
        # — silently erased its privilege-trail row. Twice, before #451. Log
        # at error and count it so the drop is visible and alertable.
        admin_record_lost(attrs, changeset.errors)
        err
    end
  rescue
    e ->
      admin_record_lost(attrs, e)
      {:error, :exception}
  end

  defp admin_record_lost(attrs, reason) do
    event_type = to_string(attrs[:event_type] || "unknown")

    Logger.error(
      "audit: admin event REJECTED, no privilege-trail row written " <>
        "(event_type=#{event_type}): #{inspect(reason)}"
    )

    :telemetry.execute(
      [:fountain, :audit, :admin_record_rejected],
      %{count: 1},
      %{event_type: event_type}
    )
  end

  @doc "Most recent administrative actions, newest first. Admin surfaces only."
  @spec _unsafe_list_recent_admin(pos_integer()) :: [AdminEvent.t()]
  def _unsafe_list_recent_admin(limit \\ 100) do
    Repo.all(from e in AdminEvent, order_by: [desc: e.inserted_at, desc: e.id], limit: ^limit)
  end

  @doc """
  One page of the privilege trail, newest first, with the unfiltered total.

  `/admin/activity` reads the whole trail rather than the newest 25 the admin
  overview used to show. The trail is the record of what an operator did to an
  account, so "only the last 25 are on screen" is the wrong answer to a
  support question about last Tuesday.
  """
  @spec _unsafe_page_admin_events(keyword()) :: %{
          events: [AdminEvent.t()],
          total: non_neg_integer()
        }
  def _unsafe_page_admin_events(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    events =
      Repo.all(
        from e in AdminEvent,
          order_by: [desc: e.inserted_at, desc: e.id],
          limit: ^per_page,
          offset: ^((page - 1) * per_page)
      )

    %{events: events, total: Repo.aggregate(AdminEvent, :count, :id)}
  end

  @doc """
  Administrative actions taken against one user, newest first. Admin surfaces
  only — this is the "what happened to account Y" half of the support story.
  """
  @spec _unsafe_list_admin_events_for_target(Ecto.UUID.t(), pos_integer()) :: [AdminEvent.t()]
  def _unsafe_list_admin_events_for_target(target_user_id, limit \\ 50)
      when is_binary(target_user_id) do
    Repo.all(
      from e in AdminEvent,
        where: e.target_user_id == ^target_user_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
  end

  @doc """
  List the most recent N events for one tenant, newest first.

  System events (`user_id = nil`) are excluded — those belong to admin
  views via `_unsafe_list_recent/1`.
  """
  @spec list_recent_for_user(Ecto.UUID.t(), pos_integer()) :: [Event.t()]
  def list_recent_for_user(user_id, limit \\ 200) when is_binary(user_id) do
    list_for_user(user_id, limit: limit)
  end

  @doc """
  Tenant-scoped events, newest first, with filters and a cursor.

  Options:

    * `:limit` — page size (default 200)
    * `:before_id` — only events with a smaller id; the cursor for paging
      back through history, since the order is newest-first
    * `:action_prefix` — e.g. `"vault."` for everything vault-related.
      LIKE metacharacters in the value are escaped, so a prefix of `%` is a
      literal `%` and not "match everything"
    * `:resource_type` — exact match
    * `:since` / `:until` — `DateTime` bounds on `inserted_at`, inclusive

  Unknown options are ignored. The trail is append-only, so paging by id is
  stable: nothing is inserted behind the cursor.
  """
  @spec list_for_user(Ecto.UUID.t(), keyword()) :: [Event.t()]
  def list_for_user(user_id, opts \\ []) when is_binary(user_id) do
    from(e in Event, where: e.user_id == ^user_id)
    |> recent_query(opts)
    |> Repo.all()
  end

  @doc """
  The distinct `resource_type` values present in one tenant's trail, sorted.

  Populates the resource-type filter on `/audit` — a select of what is
  actually there beats a free-text box the user has to guess into.
  """
  @spec list_resource_types_for_user(Ecto.UUID.t()) :: [String.t()]
  def list_resource_types_for_user(user_id) when is_binary(user_id) do
    Repo.all(
      from e in Event,
        where: e.user_id == ^user_id and not is_nil(e.resource_type),
        distinct: true,
        order_by: e.resource_type,
        select: e.resource_type
    )
  end

  # Ordering, page size and the five filters, shared by the tenant-scoped and
  # unscoped listings so the two cannot drift — the browser trail and
  # GET /api/audit answer the same question the same way.
  defp recent_query(query, opts) do
    from(e in query,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^Keyword.get(opts, :limit, 200)
    )
    |> filter_before_id(Keyword.get(opts, :before_id))
    |> filter_action_prefix(Keyword.get(opts, :action_prefix))
    |> filter_resource_type(Keyword.get(opts, :resource_type))
    |> filter_since(Keyword.get(opts, :since))
    |> filter_until(Keyword.get(opts, :until))
  end

  defp filter_before_id(query, nil), do: query

  defp filter_before_id(query, id) when is_integer(id),
    do: from(e in query, where: e.id < ^id)

  defp filter_action_prefix(query, nil), do: query
  defp filter_action_prefix(query, ""), do: query

  defp filter_action_prefix(query, prefix) when is_binary(prefix) do
    from(e in query, where: like(e.action, ^(escape_like(prefix) <> "%")))
  end

  defp filter_resource_type(query, nil), do: query
  defp filter_resource_type(query, ""), do: query

  defp filter_resource_type(query, type) when is_binary(type),
    do: from(e in query, where: e.resource_type == ^type)

  defp filter_since(query, nil), do: query

  defp filter_since(query, %DateTime{} = since),
    do: from(e in query, where: e.inserted_at >= ^since)

  defp filter_until(query, nil), do: query

  defp filter_until(query, %DateTime{} = until),
    do: from(e in query, where: e.inserted_at <= ^until)

  # A caller-supplied prefix is a literal, not a pattern: without this,
  # `?action_prefix=%` would match the whole trail and `_` would be a
  # single-character wildcard.
  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Unscoped: every event in the system, regardless of tenant.

  Reserved for admin/system surfaces. Anything user-facing must use
  `list_recent_for_user/2` instead.
  """
  @spec _unsafe_list_recent(pos_integer()) :: [Event.t()]
  def _unsafe_list_recent(limit \\ 200) do
    _unsafe_list_events(limit: limit)
  end

  @doc """
  Unscoped, with the same options as `list_for_user/2`.

  The admin half of `/audit`: an admin sees every tenant's events and needs
  the same filters a tenant has over their own, or the cross-tenant view is
  strictly worse than the scoped one.

  Reserved for admin/system surfaces. Anything user-facing must use
  `list_for_user/2` instead.
  """
  @spec _unsafe_list_events(keyword()) :: [Event.t()]
  def _unsafe_list_events(opts \\ []) do
    Event
    |> recent_query(opts)
    |> Repo.all()
  end

  @doc """
  Unscoped `list_resource_types_for_user/1` — every tenant's resource types.

  Reserved for admin surfaces; populates the `/audit` filter for an admin,
  who is looking at the whole system's trail.
  """
  @spec _unsafe_list_resource_types() :: [String.t()]
  def _unsafe_list_resource_types do
    Repo.all(
      from e in Event,
        where: not is_nil(e.resource_type),
        distinct: true,
        order_by: e.resource_type,
        select: e.resource_type
    )
  end

  @doc """
  List events for one resource, scoped to a tenant.
  """
  @spec list_for(String.t(), String.t(), Ecto.UUID.t(), pos_integer()) :: [Event.t()]
  def list_for(resource_type, resource_id, user_id, limit \\ 50)
      when is_binary(user_id) do
    Repo.all(
      from e in Event,
        where:
          e.resource_type == ^resource_type and e.resource_id == ^resource_id and
            e.user_id == ^user_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
  end
end
