defmodule Fountain.ChatGPTAccounts.LinkAttempts do
  @moduledoc false
  # The lifecycle of a user's device-code sign-in (ADR 0060 decision 3, stage
  # 4). `Fountain.ChatGPTAccounts` is the interface and documents every
  # function here; this is the body, kept out of a module that is long enough.
  #
  # Every write is `ChatGPTAccounts.user_write/2`: one transaction, the
  # owner's source key first and the attempt row after it, which is the
  # context's lock order with one more row in it. No write here touches a
  # grant row. The auth server is never called inside a transaction: the two
  # admissions below run on either side of `device_start`.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.Audit
  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.{AttemptView, Cipher, LinkAttempt}
  alias Fountain.PlatformChatGPT.OAuth
  alias Fountain.Repo

  # Codex gives a device code fifteen minutes, and so does the admin's flow
  # (`Fountain.PlatformChatGPT.Device`).
  @ttl_seconds 15 * 60

  # Open sign-ins one account may have at once, across all of its grants.
  @pending_limit 3

  @system_actor "system:chatgpt_link_attempt"

  def ttl_seconds, do: @ttl_seconds
  def pending_limit, do: @pending_limit
  def system_actor, do: @system_actor

  # ── start ────────────────────────────────────────────────────────────────

  def start(user_id, target, opts) when is_binary(user_id) and is_list(opts) do
    now = now()
    device_start = Keyword.get(opts, :device_start, &OAuth.device_start/0)

    with {:ok, target} <- target(target),
         :ok <- enabled(user_id, target),
         :ok <- expire_overdue(user_id, now),
         # Asked twice: here, so a request that will be refused costs the auth
         # server nothing, and again in the transaction that inserts the row.
         {:ok, _pins} <-
           ChatGPTAccounts.user_write(user_id, fn -> admit(user_id, target, now) end),
         {:ok, started} <- device_code(device_start),
         {:ok, {attempt, label}} <-
           ChatGPTAccounts.user_write(user_id, fn -> insert(user_id, target, started, now) end) do
      audit(attempt, "chatgpt_link_attempt.started", opts, %{"name" => label})
      {:ok, view(attempt, now)}
    end
  end

  defp target(%{name: name}) when is_binary(name), do: {:ok, {:link, name}}
  defp target(%{grant_id: grant_id}) when is_binary(grant_id), do: {:ok, {:reconnect, grant_id}}
  defp target(_other), do: {:error, :invalid_target}

  # A new link is behind the rollout; a reconnect only needs the deployment to
  # broker at all, so turning linking off strands no grant that exists. The
  # flag is asked out here because its answer may be an HTTP call.
  defp enabled(user_id, {:link, _name}) do
    if ChatGPTAccounts.linking_enabled_for?(user_id),
      do: :ok,
      else: {:error, :subscriptions_not_enabled}
  end

  defp enabled(_user_id, {:reconnect, _grant_id}) do
    if Fountain.Broker.configured?(), do: :ok, else: {:error, :subscriptions_not_enabled}
  end

  defp admit(user_id, target, now) do
    with :ok <- ChatGPTAccounts.eligible_owner(user_id),
         :ok <- under_pending_limit(user_id, now) do
      admit_target(user_id, target, now)
    end
  end

  # The ceiling is asked here so a full account is told at once, and again by
  # the write that completes the attempt, which is the one that counts.
  defp admit_target(user_id, {:link, name}, now) do
    with {:ok, name} <- free_name(user_id, name, now),
         :ok <- ChatGPTAccounts.under_ceiling(user_id) do
      {:ok, %{name: name}}
    end
  end

  defp admit_target(user_id, {:reconnect, grant_id}, now) do
    with {:ok, grant} <- ChatGPTAccounts.get_for_user(grant_id, user_id),
         :ok <- no_open_reconnect(user_id, grant.grant_id, now) do
      {:ok, %{grant_id: grant.grant_id, expected_generation: grant.generation, label: grant.name}}
    end
  end

  defp under_pending_limit(user_id, now) do
    count = Repo.aggregate(pending_query(user_id, now), :count)

    if count < @pending_limit,
      do: :ok,
      else: {:error, {:link_attempts_exceeded, %{count: count, limit: @pending_limit}}}
  end

  # A grant's name is unique per owner, and an open attempt is holding one. It
  # is the grant's own index that decides at completion; this answers while
  # the user can still choose another.
  defp free_name(user_id, name, now) do
    changeset = LinkAttempt.name_changeset(name)

    with {:ok, %{name: name}} <- Ecto.Changeset.apply_action(changeset, :insert) do
      held_by_grant? = Enum.any?(ChatGPTAccounts.list_for_user(user_id), &(&1.name == name))

      held_by_attempt? =
        Repo.exists?(from(a in pending_query(user_id, now), where: a.name == ^name))

      if held_by_grant? or held_by_attempt? do
        {:error,
         Ecto.Changeset.add_error(
           %{changeset | action: :insert},
           :name,
           "already names a ChatGPT subscription on this account"
         )}
      else
        {:ok, name}
      end
    end
  end

  defp no_open_reconnect(user_id, grant_id, now) do
    open = from(a in pending_query(user_id, now), where: a.grant_id == ^grant_id, select: a.id)

    case Repo.one(open) do
      nil -> :ok
      attempt_id -> {:error, {:link_attempt_pending, %{attempt_id: attempt_id}}}
    end
  end

  # What the auth server said is logged without its body (`OAuth` keeps only
  # the error's shape) and is not the caller's to read.
  defp device_code(device_start) do
    case device_start.() do
      {:ok, %{user_code: code, device_auth_id: id, interval: _, verification_url: _} = started}
      when is_binary(code) and is_binary(id) ->
        {:ok, started}

      other ->
        Logger.warning("chatgpt link attempt: no device code: #{inspect(failure_shape(other))}")
        {:error, :auth_unreachable}
    end
  end

  defp failure_shape({:error, reason}), do: reason
  defp failure_shape(_answer), do: :unexpected_answer

  defp insert(user_id, target, started, now) do
    # The row's id comes first: the secrets are encrypted to it (`Cipher`).
    id = Ecto.UUID.generate()

    with {:ok, pins} <- admit(user_id, target, now),
         {:ok, secrets} <- encrypt(user_id, id, started) do
      attrs =
        pins
        |> Map.take([:name, :grant_id, :expected_generation])
        |> Map.merge(secrets)
        |> Map.merge(%{
          verification_url: started.verification_url,
          poll_interval: max(started.interval, 1),
          expires_at: DateTime.add(now, @ttl_seconds, :second)
        })

      with {:ok, attempt} <-
             %LinkAttempt{id: id, user_id: user_id}
             |> LinkAttempt.start_changeset(attrs)
             |> Repo.insert() do
        {:ok, {attempt, Map.get(pins, :label) || attempt.name}}
      end
    end
  end

  # Not the key's own reason: `:not_found` here would read as "no such grant".
  defp encrypt(user_id, id, started) do
    case Cipher.encrypt_attempt_secrets(user_id, id, started) do
      {:ok, secrets} -> {:ok, secrets}
      {:error, _} -> {:error, :tenant_key_unavailable}
    end
  end

  # ── reads ────────────────────────────────────────────────────────────────

  def get(attempt_id, user_id) when is_binary(attempt_id) and is_binary(user_id) do
    with {:ok, query} <- owned_query(attempt_id, user_id),
         %LinkAttempt{} = attempt <- Repo.one(query) do
      {:ok, view(attempt, now())}
    else
      _ -> {:error, :not_found}
    end
  end

  def list_pending(user_id) when is_binary(user_id) do
    now = now()

    case Ecto.UUID.cast(user_id) do
      {:ok, owner} ->
        from(a in pending_query(owner, now), order_by: [asc: a.inserted_at, asc: a.id])
        |> Repo.all()
        |> Enum.map(&view(&1, now))

      :error ->
        []
    end
  end

  # ── cancel ───────────────────────────────────────────────────────────────

  def cancel(attempt_id, user_id, opts)
      when is_binary(attempt_id) and is_binary(user_id) and is_list(opts) do
    now = now()

    result =
      ChatGPTAccounts.user_write(user_id, fn ->
        with {:ok, attempt} <- locked(attempt_id, user_id) do
          end_pending(attempt, now)
        end
      end)

    case result do
      {:ok, {:cancelled, attempt}} ->
        audit(attempt, "chatgpt_link_attempt.cancelled", opts)
        {:ok, view(attempt, now)}

      {:ok, {:unchanged, %LinkAttempt{state: "cancelled"} = attempt}} ->
        {:ok, view(attempt, now)}

      {:ok, {:unchanged, attempt}} ->
        {:error, {:link_attempt_not_pending, %{state: attempt.state}}}

      # It ran out before the cancel arrived. That is written, and it is what
      # the caller is told: the attempt was not cancelled.
      {:ok, {:expired, attempt}} ->
        audit_expired(attempt)
        {:error, {:link_attempt_not_pending, %{state: attempt.state}}}

      {:error, _} = error ->
        error
    end
  end

  defp end_pending(%LinkAttempt{state: "pending"} = attempt, now) do
    {state, tag} =
      if LinkAttempt.expired?(attempt, now),
        do: {"expired", :expired},
        else: {"cancelled", :cancelled}

    with {:ok, ended} <- attempt |> LinkAttempt.finish_changeset(state) |> Repo.update() do
      {:ok, {tag, ended}}
    end
  end

  defp end_pending(%LinkAttempt{} = attempt, _now), do: {:ok, {:unchanged, attempt}}

  # ── expiry ───────────────────────────────────────────────────────────────

  # Correctness never waits for this: every reader and every write compares
  # `expires_at` itself. It is here so an overdue row stops holding its
  # grant's one open reconnect, and so the row says what happened.
  defp expire_overdue(user_id, now) do
    result =
      ChatGPTAccounts.user_write(user_id, :ineligible_owner, fn ->
        overdue =
          from(a in LinkAttempt,
            where: a.user_id == ^user_id and a.state == "pending" and a.expires_at <= ^now,
            lock: "FOR UPDATE"
          )

        {:ok, overdue |> Repo.all() |> Enum.flat_map(&expire/1)}
      end)

    with {:ok, expired} <- result do
      Enum.each(expired, &audit_expired/1)
      :ok
    end
  end

  defp expire(attempt) do
    case attempt |> LinkAttempt.finish_changeset("expired") |> Repo.update() do
      {:ok, expired} -> [expired]
      {:error, _changeset} -> []
    end
  end

  defp audit_expired(attempt) do
    audit(attempt, "chatgpt_link_attempt.expired", actor: @system_actor)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp locked(attempt_id, user_id) do
    with {:ok, query} <- owned_query(attempt_id, user_id),
         %LinkAttempt{} = attempt <- Repo.one(from(a in query, lock: "FOR UPDATE")) do
      {:ok, attempt}
    else
      _ -> {:error, :not_found}
    end
  end

  # Both halves of the scope. An id that is not a UUID names nothing.
  defp owned_query(attempt_id, user_id) do
    with {:ok, id} <- Ecto.UUID.cast(attempt_id),
         {:ok, owner} <- Ecto.UUID.cast(user_id) do
      {:ok, from(a in LinkAttempt, where: a.user_id == ^owner and a.id == ^id)}
    end
  end

  defp pending_query(user_id, now) do
    from(a in LinkAttempt,
      where: a.user_id == ^user_id and a.state == "pending" and a.expires_at > ^now
    )
  end

  defp view(%LinkAttempt{} = attempt, now) do
    pending? = attempt.state == "pending" and not LinkAttempt.expired?(attempt, now)

    %AttemptView{
      id: attempt.id,
      kind: if(attempt.grant_id, do: :reconnect, else: :link),
      name: attempt.name,
      grant_id: attempt.grant_id,
      state: if(LinkAttempt.expired?(attempt, now), do: "expired", else: attempt.state),
      user_code: if(pending?, do: user_code(attempt)),
      verification_url: if(pending?, do: attempt.verification_url),
      poll_interval: attempt.poll_interval,
      expires_at: attempt.expires_at,
      result_grant_id: attempt.result_grant_id,
      failure: failure(attempt),
      inserted_at: attempt.inserted_at,
      updated_at: attempt.updated_at
    }
  end

  defp user_code(attempt) do
    case Cipher.decrypt_attempt_secret(attempt, :user_code) do
      {:ok, code} -> code
      {:error, _} -> nil
    end
  end

  defp failure(%LinkAttempt{failure_reason: nil}), do: nil

  defp failure(%LinkAttempt{failure_reason: reason, conflict_grant_id: nil}),
    do: %{reason: reason, grant_id: nil, grant: nil}

  # Scoped by the owner like every other read of a grant: the name is the
  # owner's own, or nothing.
  defp failure(%LinkAttempt{failure_reason: reason, conflict_grant_id: grant_id} = attempt) do
    case ChatGPTAccounts.get_for_user(grant_id, attempt.user_id) do
      {:ok, grant} -> %{reason: reason, grant_id: grant.grant_id, grant: grant.name}
      {:error, :not_found} -> %{reason: reason, grant_id: nil, grant: nil}
    end
  end

  # What the attempt is for: a link's name, or a reconnect's grant.
  defp metadata(%LinkAttempt{grant_id: nil, name: name}), do: %{"kind" => "link", "name" => name}

  defp metadata(%LinkAttempt{grant_id: grant_id}),
    do: %{"kind" => "reconnect", "grant_id" => grant_id}

  # After the transaction has returned, never inside it. The attempt's id and
  # what it is for; never the user code, the device id or anything the auth
  # server said.
  defp audit(%LinkAttempt{} = attempt, action, opts, extra \\ %{}) do
    Audit.record(%{
      user_id: attempt.user_id,
      action: action,
      resource_type: "chatgpt_link_attempt",
      resource_id: attempt.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: Map.merge(metadata(attempt), extra)
    })
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
