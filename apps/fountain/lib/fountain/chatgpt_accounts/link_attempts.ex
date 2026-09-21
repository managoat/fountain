defmodule Fountain.ChatGPTAccounts.LinkAttempts do
  @moduledoc false
  # The lifecycle of a user's device-code sign-in (ADR 0060 decision 3, stage
  # 4). `Fountain.ChatGPTAccounts` is the interface and documents every
  # function here; this is the body, kept out of a module that is long enough.
  #
  # Every write is `ChatGPTAccounts.user_write/2`: one transaction, the
  # owner's source key first and the attempt row after it, which is the
  # context's lock order with one more row in it. No write here touches a
  # grant row; the two of the context's that end a grant come here for its
  # open attempt (`lock_open_for_grant/2`). The auth server is never called inside a transaction: the two
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

  # Sign-ins one account may begin in an hour, whatever became of them. The
  # pending limit is no bound on a start that is cancelled and started again,
  # and each one costs `auth.openai.com` a device code: the host every grant's
  # refresh goes to, the platform's included. It is counted from the rows,
  # under the owner's key, so it holds across API keys, nodes, deploys and
  # callers that are not the API. `purge/0` keeps a row far longer than this.
  @start_limit 10
  @start_window_seconds 60 * 60

  # Codex backs off to a minute at most, and so does this. It is also the
  # longest interval a row will keep, whoever answered `device_start`.
  @max_backoff_seconds 60

  @system_actor "system:chatgpt_link_attempt"

  def ttl_seconds, do: @ttl_seconds
  def pending_limit, do: @pending_limit
  def start_limit, do: @start_limit
  def start_window_seconds, do: @start_window_seconds
  def system_actor, do: @system_actor

  # ── start ────────────────────────────────────────────────────────────────

  def start(user_id, target, opts) when is_binary(user_id) and is_list(opts) do
    device_start = Keyword.get(opts, :device_start, &OAuth.device_start/0)

    with {:ok, target} <- target(target),
         :ok <- enabled(user_id, target),
         # Asked twice: here, so a request that will be refused costs the auth
         # server nothing, and again in the transaction that inserts the row.
         {:ok, _pins} <- admitted(user_id, fn now -> admit(user_id, target, now) end),
         {:ok, started} <- device_code(device_start),
         {:ok, {attempt, label, now}} <-
           admitted(user_id, fn now -> insert(user_id, target, started, now) end) do
      audit(attempt, "chatgpt_link_attempt.started", opts, %{"name" => label})
      ChatGPTAccounts.broadcast_changed(user_id)
      {:ok, view(attempt, now)}
    end
  end

  # One admission: the clock is read when it begins, because the auth server
  # may have taken seconds to answer between the two, and the account's
  # overdue rows are written `expired` in its transaction before anything is
  # counted. A refusal rolls that sweep back with the rest, which costs
  # nothing: no query here counts a row past its time (`pending_query/2`).
  defp admitted(user_id, fun) do
    now = now()

    result =
      ChatGPTAccounts.user_write(user_id, :ineligible_owner, fn ->
        expired = expire_overdue(user_id, now)
        with {:ok, admitted} <- fun.(now), do: {:ok, {admitted, expired}}
      end)

    with {:ok, {admitted, expired}} <- result do
      Enum.each(expired, &expired/1)
      {:ok, admitted}
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
         :ok <- under_start_limit(user_id, now),
         :ok <- key_loads(user_id),
         :ok <- under_pending_limit(user_id, now) do
      admit_target(user_id, target, now)
    end
  end

  # The code the auth server hands back has to be encrypted to be kept, so an
  # account whose key will not load is told before the auth server is asked.
  # Not the key's own reason: `:not_found` here would read as "no such grant".
  defp key_loads(user_id) do
    case Fountain.Crypto.load_tenant_key(user_id) do
      {:ok, _dek} -> :ok
      {:error, _} -> {:error, :tenant_key_unavailable}
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

  # Every row counts, ended ones too. `retry_after` is when the oldest of
  # them leaves the window.
  defp under_start_limit(user_id, now) do
    since = DateTime.add(now, -@start_window_seconds, :second)

    recent =
      from(a in LinkAttempt,
        where: a.user_id == ^user_id and a.inserted_at > ^since,
        select: {count(a.id), min(a.inserted_at)}
      )

    case Repo.one(recent) do
      {count, oldest} when count >= @start_limit ->
        retry_after = max(DateTime.diff(oldest, since, :second), 1)
        {:error, {:link_attempts_rate_limited, %{limit: @start_limit, retry_after: retry_after}}}

      _under ->
        :ok
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

  # What the auth server said is logged as a status at most (`shape/1`) and is
  # not the caller's to read.
  defp device_code(device_start) do
    case device_start.() do
      {:ok, %{user_code: code, device_auth_id: id, interval: _, verification_url: _} = started}
      when is_binary(code) and is_binary(id) ->
        {:ok, started}

      {:error, reason} ->
        Logger.warning("chatgpt link attempt: no device code: #{shape(reason)}")
        {:error, :auth_unreachable}

      # Kept, and never bound: an answer of another shape may still carry a
      # code, and a clause error or a `MatchError` would carry the answer into
      # a crash report.
      _unexpected ->
        Logger.warning("chatgpt link attempt: no device code: unexpected answer")
        {:error, :auth_unreachable}
    end
  end

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
          poll_interval: started.interval |> max(1) |> min(@max_backoff_seconds),
          expires_at: DateTime.add(now, @ttl_seconds, :second)
        })

      # The job is inserted with the row or not at all: it carries the two
      # ids and nothing else.
      with {:ok, attempt} <-
             %LinkAttempt{id: id, user_id: user_id}
             |> LinkAttempt.start_changeset(attrs)
             |> Repo.insert(),
           {:ok, _job} <- Fountain.Workers.ChatGPTLinkAttempt.enqueue(attempt) do
        {:ok, {attempt, Map.get(pins, :label) || attempt.name, now}}
      end
    end
  end

  defp encrypt(user_id, id, started) do
    case Cipher.encrypt_attempt_secrets(user_id, id, started) do
      {:ok, secrets} -> {:ok, secrets}
      {:error, _} -> {:error, :tenant_key_unavailable}
    end
  end

  # ── reads ────────────────────────────────────────────────────────────────

  def get(attempt_id, user_id) when is_binary(attempt_id) and is_binary(user_id) do
    now = now()

    with {:ok, query} <- owned_query(attempt_id, user_id),
         %LinkAttempt{} = attempt <- Repo.one(query) do
      {:ok, attempt |> polled(now) |> view(now)}
    else
      _ -> {:error, :not_found}
    end
  end

  # A pending attempt in time whose job was lost gets it back from whoever
  # reads it (`Fountain.Workers.ChatGPTLinkAttempt.ensure_enqueued/1`).
  defp polled(%LinkAttempt{state: "pending"} = attempt, now) do
    unless LinkAttempt.expired?(attempt, now),
      do: Fountain.Workers.ChatGPTLinkAttempt.ensure_enqueued(attempt)

    attempt
  end

  defp polled(%LinkAttempt{} = attempt, _now), do: attempt

  def list_pending(user_id) when is_binary(user_id) do
    now = now()

    case Ecto.UUID.cast(user_id) do
      {:ok, owner} ->
        from(a in pending_query(owner, now), order_by: [asc: a.inserted_at, asc: a.id])
        |> Repo.all()
        |> Enum.map(&(&1 |> polled(now) |> view(now)))

      :error ->
        []
    end
  end

  # How long an ended attempt stays worth showing, and how many of them.
  @recent_seconds 30 * 60
  @recent_limit 10

  def list_recent(user_id) when is_binary(user_id) do
    now = now()
    since = DateTime.add(now, -@recent_seconds, :second)

    case Ecto.UUID.cast(user_id) do
      {:ok, owner} ->
        # Ended when the row was last written, or, for one that ran out and
        # that nobody has written yet, when it ran out.
        from(a in LinkAttempt,
          where: a.user_id == ^owner,
          where:
            (a.state != "pending" and a.updated_at > ^since) or
              (a.state == "pending" and a.expires_at <= ^now and a.expires_at > ^since)
        )
        |> Repo.all()
        |> Enum.sort_by(&{ended_at(&1), &1.id}, fn {a, x}, {b, y} ->
          case DateTime.compare(a, b) do
            :eq -> x >= y
            order -> order == :gt
          end
        end)
        |> Enum.take(@recent_limit)
        |> Enum.map(&view(&1, now))

      :error ->
        []
    end
  end

  defp ended_at(%LinkAttempt{state: "pending", expires_at: at}), do: at
  defp ended_at(%LinkAttempt{updated_at: at}), do: at

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
        ChatGPTAccounts.broadcast_changed(user_id)
        {:ok, view(attempt, now)}

      {:ok, {:unchanged, %LinkAttempt{state: "cancelled"} = attempt}} ->
        {:ok, view(attempt, now)}

      {:ok, {:unchanged, attempt}} ->
        {:error, {:link_attempt_not_pending, %{state: attempt.state}}}

      # It ran out before the cancel arrived. That is written, and it is what
      # the caller is told: the attempt was not cancelled.
      {:ok, {:expired, attempt}} ->
        expired(attempt)
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

  # ── poll ─────────────────────────────────────────────────────────────────

  def poll(attempt_id, user_id, opts)
      when is_binary(attempt_id) and is_binary(user_id) and is_list(opts) do
    now = now()

    with {:ok, query} <- owned_query(attempt_id, user_id),
         %LinkAttempt{state: "pending"} = attempt <- Repo.one(query) do
      if LinkAttempt.expired?(attempt, now) do
        conclude(attempt, "expired", %{}, [])
        :done
      else
        ask(attempt, opts)
      end
    else
      # Gone with its account, or ended already: nothing is asked of anybody.
      _ -> :done
    end
  end

  # Everything the auth server is asked happens here, with no transaction
  # open and no lock held. The device id, the user code, the authorization
  # code and the tokens are locals of this call and of nothing else.
  defp ask(attempt, opts) do
    device_poll = Keyword.get(opts, :device_poll, &OAuth.device_poll/2)

    with {:ok, device_auth_id} <- Cipher.decrypt_attempt_secret(attempt, :device_auth_id),
         {:ok, user_code} <- Cipher.decrypt_attempt_secret(attempt, :user_code) do
      case device_poll.(device_auth_id, user_code) do
        :pending -> again(attempt, 0)
        {:ok, approval} -> exchange(attempt, approval, opts)
        {:error, reason} -> unanswered(attempt, reason, "authorization_failed")
      end
    else
      {:error, _} -> failed(attempt, "tenant_key_unavailable")
    end
  end

  defp exchange(attempt, approval, opts) do
    device_exchange = Keyword.get(opts, :device_exchange, &OAuth.device_exchange/1)

    # Asked before the exchange as well as by the completion, so a link that
    # will be refused for this does not have tokens issued to be dropped.
    with :ok <- still_enabled(attempt),
         {:ok, tokens} <- device_exchange.(approval) do
      complete(attempt.id, attempt.user_id, tokens, actor: @system_actor)
      :done
    else
      {:error, :subscriptions_not_enabled} -> failed(attempt, "linking_disabled")
      {:error, reason} -> unanswered(attempt, reason, "exchange_failed")
    end
  end

  # A refusal ends the attempt; an auth server that could not be reached, or
  # asked for patience, is asked again later and less often.
  defp unanswered(attempt, reason, failure) do
    Logger.warning("chatgpt link attempt #{attempt.id}: #{failure}: #{shape(reason)}")

    if retryable?(reason),
      do: again(attempt, attempt.poll_failures + 1),
      else: failed(attempt, failure)
  end

  defp retryable?({_leg, status, _body}) when is_integer(status),
    do: status in [408, 425, 429] or status >= 500

  defp retryable?({:terminal, _code}), do: false
  defp retryable?(_transport), do: true

  # A status or a terminal code, both the auth server's own vocabulary and
  # neither a secret. A transport error is not printed: it may name a URL.
  defp shape({_leg, status, _body}) when is_integer(status), do: "status #{status}"
  defp shape({:terminal, code}) when is_binary(code), do: "terminal #{code}"
  defp shape(_transport), do: "unreachable"

  defp failed(attempt, reason) do
    conclude(attempt, "failed", %{failure_reason: reason}, actor: @system_actor)
    :done
  end

  # One statement on one row, which waits for nothing while it holds it, so it
  # takes no key. It writes only a row that is still pending.
  defp again(%LinkAttempt{poll_failures: failures} = attempt, failures),
    do: {:again, delay(attempt, failures)}

  defp again(%LinkAttempt{id: id, poll_failures: before} = attempt, failures) do
    {written, _} =
      from(a in LinkAttempt, where: a.id == ^id and a.state == "pending")
      |> Repo.update_all(set: [poll_failures: failures])

    # Said when the auth server stops answering and when it answers again,
    # which is when `AttemptView`'s `:auth_unreachable` changes; not on every
    # failure in between, which changes nothing anybody is shown.
    if written == 1 and before == 0 != (failures == 0),
      do: ChatGPTAccounts.broadcast_changed(attempt.user_id)

    {:again, delay(attempt, failures)}
  end

  defp delay(%LinkAttempt{poll_interval: interval}, 0), do: interval

  defp delay(%LinkAttempt{poll_interval: interval}, failures),
    do: min(interval * Integer.pow(2, min(failures, 6)), max(interval, @max_backoff_seconds))

  # ── purge ────────────────────────────────────────────────────────────────

  # Ended a week ago, or never ended and a week past its time (its job was
  # lost): either way nothing reads it again. A pending row in time is never
  # touched whatever the cutoff says.
  @purge_after_days 7

  def purge do
    cutoff = DateTime.add(now(), -@purge_after_days, :day)

    {count, _} =
      from(a in LinkAttempt,
        where:
          (a.state != "pending" and a.updated_at < ^cutoff) or
            (a.state == "pending" and a.expires_at < ^cutoff)
      )
      |> Repo.delete_all()

    count
  end

  # ── complete ─────────────────────────────────────────────────────────────

  def complete(attempt_id, user_id, %{access_token: _} = tokens, opts)
      when is_binary(attempt_id) and is_binary(user_id) and is_list(opts) do
    now = now()

    # Unlocked, and only to learn what the attempt is for, which never
    # changes. Whether it may still complete is asked again under the lock.
    with {:ok, query} <- owned_query(attempt_id, user_id),
         %LinkAttempt{} = attempt <- Repo.one(query) do
      result =
        with :ok <- still_enabled(attempt),
             do: write_grant(attempt, tokens, fence(attempt, now), opts)

      completed(result, attempt, opts, now)
    else
      _ -> {:error, :not_found}
    end
  end

  # Linking may have been turned off in the minutes since a new link began,
  # for this account or for the deployment. Everything else a completion asks
  # again is asked by the write, in its transaction; this one is asked out
  # here, as the start asks it, because the flag's answer may be an HTTP
  # call. A reconnect asks nothing: it is how a grant that exists keeps
  # working with linking off. Neither does a row that has ended, which is a
  # replay's to read.
  defp still_enabled(%LinkAttempt{state: "pending", grant_id: nil, user_id: user_id}),
    do: enabled(user_id, {:link, nil})

  defp still_enabled(%LinkAttempt{}), do: :ok

  # `connect_for_user/4`'s and `reconnect_for_user/4`'s `:within`. It runs in
  # their transaction, under the owner's key and before the grant's row is
  # touched: the attempt's row is locked, must still be pending and in time,
  # and is marked in the transaction that stores the grant, or none of it
  # happens.
  defp fence(%LinkAttempt{id: id, user_id: user_id}, now) do
    fn write ->
      with {:ok, attempt} <- locked(id, user_id),
           :ok <- still_pending(attempt, now),
           {:ok, account} <- write.(),
           {:ok, _done} <-
             attempt
             |> LinkAttempt.finish_changeset("completed", %{result_grant_id: account.id})
             |> Repo.update() do
        {:ok, account}
      end
    end
  end

  defp still_pending(%LinkAttempt{state: "pending"} = attempt, now) do
    if LinkAttempt.expired?(attempt, now),
      do: {:error, {:link_attempt_not_pending, %{state: "expired"}}},
      else: :ok
  end

  defp still_pending(%LinkAttempt{state: state}, _now),
    do: {:error, {:link_attempt_not_pending, %{state: state}}}

  defp write_grant(%LinkAttempt{grant_id: nil} = attempt, tokens, fence, opts) do
    ChatGPTAccounts.connect_for_user(
      attempt.user_id,
      attempt.name,
      tokens,
      grant_opts(opts, within: fence, attempt_id: attempt.id)
    )
  end

  defp write_grant(%LinkAttempt{grant_id: grant_id} = attempt, tokens, fence, opts) do
    ChatGPTAccounts.reconnect_for_user(
      grant_id,
      attempt.user_id,
      tokens,
      grant_opts(opts,
        within: fence,
        attempt_id: attempt.id,
        expected_generation: attempt.expected_generation
      )
    )
  end

  defp grant_opts(opts, extra),
    do: opts |> Keyword.take([:actor, :request_ip]) |> Keyword.merge(extra)

  defp completed({:ok, _grant}, attempt, _opts, now), do: reread(attempt, now)

  # Somebody else ended it first. A replay of a completion that landed reads
  # the completed attempt; a cancel is left as the cancel wrote it; a row
  # that only ran out of time is written so.
  defp completed(
         {:error, {:link_attempt_not_pending, %{state: state}}} = refusal,
         attempt,
         _,
         now
       ) do
    case state do
      "completed" -> reread(attempt, now)
      "expired" -> with {:ok, _view} <- conclude(attempt, "expired", %{}, []), do: refusal
      _ -> refusal
    end
  end

  defp completed({:error, reason} = refusal, attempt, opts, _now) do
    with {:ok, _view} <- conclude(attempt, "failed", failure_attrs(reason), opts), do: refusal
  end

  defp reread(%LinkAttempt{id: id, user_id: user_id}, now),
    do: {:ok, view(Repo.get_by!(LinkAttempt, id: id, user_id: user_id), now)}

  # Only what the context itself answered, mapped onto the schema's list:
  # nothing the auth server said is stored.
  defp failure_attrs(:stale_grant), do: %{failure_reason: "stale_grant"}

  defp failure_attrs({:account_already_linked, %{grant_id: grant_id}}),
    do: %{failure_reason: "account_already_linked", conflict_grant_id: grant_id}

  defp failure_attrs({:grant_limit_reached, _}), do: %{failure_reason: "grant_limit_reached"}
  defp failure_attrs(:not_found), do: %{failure_reason: "grant_not_found"}
  defp failure_attrs(:ineligible_owner), do: %{failure_reason: "owner_ineligible"}
  defp failure_attrs(:subscriptions_not_enabled), do: %{failure_reason: "linking_disabled"}
  defp failure_attrs(:tenant_key_unavailable), do: %{failure_reason: "tenant_key_unavailable"}

  defp failure_attrs(reason) when reason in [:no_refresh_token, :invalid_id_token],
    do: %{failure_reason: "invalid_sign_in"}

  # The grant's two unique indexes, which the admission answers first. The
  # account's is the backstop of `{:account_already_linked, _}`.
  defp failure_attrs(%Ecto.Changeset{} = changeset) do
    cond do
      Keyword.has_key?(changeset.errors, :name) ->
        %{failure_reason: "name_taken"}

      Keyword.has_key?(changeset.errors, :account_id) ->
        %{failure_reason: "account_already_linked"}

      true ->
        %{failure_reason: "internal_error"}
    end
  end

  defp failure_attrs(_reason), do: %{failure_reason: "internal_error"}

  # The write that ends an attempt some other way than by completing or being
  # cancelled: its own transaction, after whatever refused has rolled back,
  # under the same two locks. A row that is no longer pending is left alone.
  defp conclude(%LinkAttempt{id: id, user_id: user_id}, state, attrs, opts) do
    result =
      ChatGPTAccounts.user_write(user_id, fn ->
        with {:ok, attempt} <- locked(id, user_id) do
          conclude_locked(attempt, state, attrs)
        end
      end)

    with {:ok, {written?, attempt}} <- result do
      if written?, do: concluded(attempt, opts)
      {:ok, view(attempt, now())}
    end
  end

  defp conclude_locked(%LinkAttempt{state: "pending"} = attempt, state, attrs) do
    with {:ok, ended} <- attempt |> LinkAttempt.finish_changeset(state, attrs) |> Repo.update() do
      {:ok, {true, ended}}
    end
  end

  defp conclude_locked(%LinkAttempt{} = attempt, _state, _attrs), do: {:ok, {false, attempt}}

  defp concluded(%LinkAttempt{state: "expired"} = attempt, _opts), do: expired(attempt)

  defp concluded(%LinkAttempt{state: "failed"} = attempt, opts) do
    audit(attempt, "chatgpt_link_attempt.failed", opts, %{"reason" => attempt.failure_reason})
    ChatGPTAccounts.broadcast_changed(attempt.user_id)
  end

  # ── a grant that ends under an open attempt ──────────────────────────────

  # `disconnect_for_user/3` and `remove_for_user/3` end the grant's open
  # reconnect with it. Left pending it could only ever end `stale_grant` or
  # `grant_not_found`, and until it did it was the grant's one open sign-in:
  # the reconnect the user asks for next was a 409.
  #
  # Two halves, because the first has to come before the grant's row is
  # locked (the order is key, attempt, grant) and what the second writes
  # depends on what that row says. Both run in the caller's transaction,
  # under the owner's key. `announce_ended/2` is for after it has committed.
  def lock_open_for_grant(user_id, grant_id) do
    case Ecto.UUID.cast(grant_id) do
      {:ok, id} ->
        from(a in LinkAttempt,
          where: a.user_id == ^user_id and a.grant_id == ^id and a.state == "pending",
          lock: "FOR UPDATE"
        )
        |> Repo.all()

      :error ->
        []
    end
  end

  def end_locked(attempts, reason) when is_list(attempts) and is_binary(reason) do
    now = now()

    Enum.flat_map(attempts, fn attempt ->
      {state, attrs} =
        if LinkAttempt.expired?(attempt, now),
          do: {"expired", %{}},
          else: {"failed", %{failure_reason: reason}}

      case attempt |> LinkAttempt.finish_changeset(state, attrs) |> Repo.update() do
        {:ok, ended} -> [ended]
        {:error, _changeset} -> []
      end
    end)
  end

  def announce_ended(ended, opts) when is_list(ended), do: Enum.each(ended, &concluded(&1, opts))

  # ── expiry ───────────────────────────────────────────────────────────────

  # Correctness never waits for this: every reader and every write compares
  # `expires_at` itself. It is here so an overdue row stops holding its
  # grant's one open reconnect, and so the row says what happened. Inside
  # `admitted/2`'s transaction, under the owner's key; the rows it answers
  # are announced by `expired/1` once that has committed.
  defp expire_overdue(user_id, now) do
    from(a in LinkAttempt,
      where: a.user_id == ^user_id and a.state == "pending" and a.expires_at <= ^now,
      lock: "FOR UPDATE"
    )
    |> Repo.all()
    |> Enum.flat_map(&expire/1)
  end

  defp expire(attempt) do
    case attempt |> LinkAttempt.finish_changeset("expired") |> Repo.update() do
      {:ok, expired} -> [expired]
      {:error, _changeset} -> []
    end
  end

  defp expired(attempt) do
    audit(attempt, "chatgpt_link_attempt.expired", actor: @system_actor)
    ChatGPTAccounts.broadcast_changed(attempt.user_id)
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
      auth_unreachable: pending? and attempt.poll_failures > 0,
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
