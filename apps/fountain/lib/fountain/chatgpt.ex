defmodule Fountain.ChatGPT do
  @moduledoc """
  ChatGPT subscriptions for the codex runtime (ADR 0070): at most one per
  user. The deployment's own subscription was removed (ADR 0075).

  Every read and write here is keyed by the owner's user id, so a
  user-facing caller passes the signed-in user's id and reaches nothing else.

  ## When a codex conversation runs on one

  The user's own subscription wins over the user's own OpenAI API key
  (`Fountain.InferenceCredentials.Resolver`; ADR 0070, ADR 0075). Only on a
  brokered deployment:
  the access token is handed to the egress broker under
  `CODEX_CHATGPT_ACCESS_TOKEN`, substituted on `chatgpt.com`, and never
  enters the sandbox (`Fountain.Conversations.CodexChatGPT`).

  ## When Fountain talks to auth.openai.com

  To link (the device-code legs), to end a sign-in Fountain no longer
  holds (`OAuth.revoke/1`, below), from the daily keepalive
  (`Fountain.Workers.ChatGPTKeepalive`: every subscription last refreshed
  more than six days ago; an access token lives about ten), and as a safety
  net before a turn when the stored access token has expired or expires
  within ten minutes (`token_for/2`). A turn otherwise only re-reads the
  stored token from the database into the broker's rule.

  A refresh first takes a short lease on the row (`refresh_lease_until`,
  set by one conditional `UPDATE`), so no two processes spend one refresh
  token: OpenAI rotates it on use. The call to auth.openai.com runs outside
  any transaction and holds no database connection. The rotated pair is
  then written by a compare-and-swap on the lease and the spent refresh
  token, retried if the write fails, before the new access token is used
  (#2661). A refresh the auth server refuses for good marks the subscription
  `revoked`; its conversations then fail with `chatgpt_reconnect_required`
  until the owner links again.

  ## Ending a sign-in at OpenAI

  When Fountain lets go of a refresh token it revokes it at auth.openai.com,
  as `codex logout` does (ADR 0070, addendum of 2026-10-15): on disconnect,
  for the token a relink replaces, for tokens a device-code sign-in obtained
  but could not store, for a refresh's rotated tokens a relink or disconnect
  overtook, and on account deletion. The call runs after the local write has
  committed, outside any transaction or lock. Its failure never undoes that
  write: it is logged with a status and a code, and audited as
  `chatgpt_subscription.not_revoked_at_openai` (a success as
  `.revoked_at_openai`).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.{Audit, Crypto, InferenceCredentials, Repo}
  alias Fountain.ChatGPT.{OAuth, Subscription, Tokens}

  @refresh_margin_seconds 10 * 60
  @refresh_after_days 6

  # How long a refresh may hold the row. The exchange is bounded at about
  # eighteen seconds (`OAuth`) and the store's retries at under two, so the
  # lease outlives a refresh that is still running; it lapses on its own
  # when the process holding it died.
  @lease_seconds 60
  @store_backoff_ms [200, 1_000]

  @doc "The user's subscription, active or revoked, or nil."
  @spec get(Ecto.UUID.t()) :: Subscription.t() | nil
  def get(user_id) when is_binary(user_id), do: Repo.get_by(Subscription, user_id: user_id)

  @doc "Whether the user has an active subscription."
  @spec active?(Ecto.UUID.t()) :: boolean()
  def active?(user_id), do: match?(%Subscription{status: "active"}, get(user_id))

  @doc """
  Link the user's subscription from the tokens a sign-in produced, replacing
  the one it had. The account comes from the `id_token`'s claims. The
  replaced sign-in, and a device-code sign-in that fails to link, are then
  ended at OpenAI.

  `opts`: `:method` (`"device_code"` or `"auth_json"`), and attribution:
  `:actor` and `:request_ip`.
  """
  @spec connect(Ecto.UUID.t(), OAuth.tokens(), keyword()) ::
          {:ok, Subscription.t()} | {:error, atom()}
  def connect(user_id, %{access_token: access} = tokens, opts \\ [])
      when is_binary(user_id) and is_binary(access) do
    case link(user_id, access, tokens) do
      {:ok, sub, replaced} ->
        audit(user_id, :connected, sub, opts, %{"method" => Keyword.get(opts, :method)})

        if replaced != tokens[:refresh_token],
          do: end_sign_in(user_id, sub.id, replaced, "replaced", opts)

        {:ok, sub}

      {:error, _} = error ->
        # A device-code sign-in's tokens are Fountain's own, issued for this
        # link alone, so a link that fails discards them. A pasted auth.json
        # is the sign-in of the machine it came from, and is left alone.
        if Keyword.get(opts, :method) == "device_code",
          do: end_sign_in(user_id, nil, present(tokens[:refresh_token]), "discarded", opts)

        error
    end
  end

  # `{:ok, sub, replaced}`, where `replaced` is the refresh token of the
  # active row this link overwrote, if any.
  defp link(user_id, access, tokens) do
    with refresh when is_binary(refresh) and refresh != "" <- tokens[:refresh_token],
         {:ok, claims} <- Tokens.claims(tokens[:id_token]) do
      now = now()

      result =
        locked_write(user_id, fn existing ->
          sub = existing || %Subscription{id: Ecto.UUID.generate(), user_id: user_id}
          replaced = existing && revocable(existing)

          with {:ok, access_ct} <- seal(sub, :access_token, access),
               {:ok, refresh_ct} <- seal(sub, :refresh_token, refresh),
               {:ok, linked} <-
                 sub
                 |> Ecto.Changeset.change(%{
                   account_id: claims.account_id,
                   chatgpt_user_id: claims.chatgpt_user_id,
                   plan_type: claims.plan_type,
                   access_token_ciphertext: access_ct,
                   refresh_token_ciphertext: refresh_ct,
                   expires_at: Tokens.expires_at(access),
                   last_refreshed_at: now,
                   status: "active",
                   revoked_reason: nil,
                   refresh_lease_until: nil
                 })
                 |> Repo.insert_or_update() do
            {:ok, {linked, replaced}}
          end
        end)

      with {:ok, {sub, replaced}} <- result, do: {:ok, sub, replaced}
    else
      {:error, _} = error -> error
      _ -> {:error, :no_refresh_token}
    end
  end

  @doc "`connect/3` from the `auth.json` that `codex login` wrote."
  @spec connect_auth_json(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Subscription.t()} | {:error, atom()}
  def connect_auth_json(user_id, json, opts \\ []) do
    with {:ok, tokens} <- Tokens.parse_auth_json(json) do
      connect(user_id, tokens, Keyword.put(opts, :method, "auth_json"))
    end
  end

  @doc """
  Remove the user's subscription and its tokens, then end the sign-in at
  OpenAI. `:ok` whether or not there was one, and whether or not OpenAI
  confirmed; only a removal is audited.
  """
  @spec disconnect(Ecto.UUID.t(), keyword()) :: :ok
  def disconnect(user_id, opts \\ []) do
    removed =
      locked_write(user_id, fn
        nil -> {:ok, nil}
        existing -> {:ok, {Repo.delete!(existing), revocable(existing)}}
      end)

    case removed do
      {:ok, {%Subscription{} = sub, refresh}} ->
        audit(user_id, :disconnected, sub, opts, %{})
        end_sign_in(user_id, sub.id, refresh, "disconnected", opts)

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  For account deletion, before the user row goes: the subscription's id and
  refresh token, read while the key that decrypts it still exists. The
  cascade then deletes the row and the key; pass this to
  `end_sign_in_after_deletion/3` once the deletion has committed. `nil` when
  there is nothing to end.
  """
  @spec sign_in_to_end(Ecto.UUID.t()) :: {Ecto.UUID.t(), String.t()} | nil
  def sign_in_to_end(user_id) do
    with %Subscription{} = sub <- get(user_id),
         refresh when is_binary(refresh) <- revocable(sub) do
      {sub.id, refresh}
    else
      _ -> nil
    end
  end

  @doc """
  End at OpenAI the sign-in `sign_in_to_end/1` read, after the account is
  deleted. Audited with no `user_id` (the row is gone) and the id in the
  metadata, as `account.deleted` is. `opts`: `:actor`, `:request_ip`.
  """
  @spec end_sign_in_after_deletion(Ecto.UUID.t(), {Ecto.UUID.t(), String.t()} | nil, keyword()) ::
          :ok
  def end_sign_in_after_deletion(_user_id, nil, _opts), do: :ok

  def end_sign_in_after_deletion(user_id, {sub_id, refresh}, opts) do
    end_sign_in(
      user_id,
      sub_id,
      refresh,
      "account_deleted",
      Keyword.put(opts, :audit_user_id, nil)
    )
  end

  @doc """
  The user's subscription, if a codex run could use it now, with its access
  token. `:none` when it is not linked, not active, or its token does not
  decrypt.

  A database read and a decrypt, no provider I/O: it runs under the
  inference source lock. An expired token is returned as it is; the turn's
  `token_for/2` deals with that.
  """
  @spec serving(Ecto.UUID.t()) :: {:ok, Subscription.t(), String.t()} | :none
  def serving(user_id) do
    with %Subscription{status: "active"} = sub <- get(user_id),
         {:ok, token} <- open(sub, :access_token) do
      {:ok, sub, token}
    else
      _ -> :none
    end
  end

  @doc """
  The access token to put in the broker's rule before a turn of a
  conversation bound to the user's subscription on `account_id`.

  Reads the stored token. Only when it has expired or expires within ten
  minutes does it refresh first (the keepalive should have); a refresh that
  fails for a transient reason, or that another replica is running, leaves
  the stored token in place. `{:error, :chatgpt_reconnect_required}` when the
  subscription is gone, revoked, or now on another account.
  """
  @spec token_for(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :chatgpt_reconnect_required}
  def token_for(user_id, account_id) do
    with %Subscription{status: "active", account_id: ^account_id} = sub <- get(user_id),
         sub <- refresh_if_expiring(sub),
         %Subscription{status: "active"} <- sub,
         {:ok, token} <- open(sub, :access_token) do
      {:ok, token}
    else
      _ -> {:error, :chatgpt_reconnect_required}
    end
  end

  @doc """
  What a sandbox's `auth.json` needs besides the placeholder: the account
  id and a synthesised `id_token`. `{:error, :chatgpt_reconnect_required}`
  on the same terms as `token_for/2`.
  """
  @spec sandbox_auth(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, %{account_id: String.t(), id_token: String.t()}}
          | {:error, :chatgpt_reconnect_required}
  def sandbox_auth(user_id, account_id) do
    case get(user_id) do
      %Subscription{status: "active", account_id: ^account_id} = sub ->
        {:ok, %{account_id: sub.account_id, id_token: Tokens.synthesize_id_token(claims(sub))}}

      _ ->
        {:error, :chatgpt_reconnect_required}
    end
  end

  @doc """
  Exchange the subscription's refresh token for a new pair, under a lease on
  the row. No transaction is open and no connection is held while
  auth.openai.com answers (#2661).

  `{:ok, sub}` with the row as it now is (refreshed here, or by whoever
  refreshed it since `sub` was read, which is not refreshed twice);
  `{:error, :locked}` when another process holds the lease now;
  `{:error, :revoked}` when the auth server refused the refresh token for
  good, which marks the row and audits it; `{:error, :gone}` when the row was
  removed or is already revoked; `{:error, :superseded}` when the row was
  linked again or removed while the exchange ran, which discards the old
  chain's tokens; `{:error, :store_failed}` when the rotated pair could not
  be written after retries, logged as an error because the stored refresh
  token is now spent. Any other error is transient and the row is unchanged.
  """
  @spec refresh(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term()}
  def refresh(%Subscription{id: id, last_refreshed_at: cutoff}) do
    case take_lease(id, cutoff) do
      {:leased, leased} -> exchange(leased)
      other -> other
    end
  end

  @doc """
  The active subscriptions last refreshed more than six days ago. For the
  keepalive.
  """
  @spec _unsafe_due_for_refresh() :: [Subscription.t()]
  def _unsafe_due_for_refresh do
    cutoff = DateTime.add(now(), -@refresh_after_days * 86_400)

    Repo.all(
      from s in Subscription,
        where: s.status == "active" and s.last_refreshed_at < ^cutoff,
        order_by: s.last_refreshed_at
    )
  end

  # ── internals ────────────────────────────────────────────────────────────

  # One conditional UPDATE, no transaction: the row is leased when it is
  # active, not refreshed since `cutoff`, and holds no live lease. The lease
  # is stamped with the database's clock, and its exact value identifies
  # this refresh when it writes back. `{:leased, sub}` carries the row as
  # the lease found it.
  defp take_lease(id, cutoff) do
    query =
      from s in Subscription,
        where:
          s.id == ^id and s.status == "active" and s.last_refreshed_at <= ^cutoff and
            (is_nil(s.refresh_lease_until) or s.refresh_lease_until < fragment("now()")),
        update: [
          set: [
            refresh_lease_until: fragment("now() + make_interval(secs => ?)", ^@lease_seconds)
          ]
        ],
        select: s

    case Repo.update_all(query, []) do
      {1, [leased]} ->
        {:leased, leased}

      {0, _} ->
        case Repo.get(Subscription, id) do
          %Subscription{status: "active"} = sub ->
            if DateTime.compare(sub.last_refreshed_at, cutoff) == :gt,
              do: {:ok, sub},
              else: {:error, :locked}

          _ ->
            {:error, :gone}
        end
    end
  end

  defp exchange(leased) do
    with {:ok, refresh_token} <- open(leased, :refresh_token),
         {:ok, tokens} <- OAuth.refresh(refresh_token) do
      store_refreshed(leased, tokens)
    else
      {:error, {:terminal, code}} ->
        case attempt_write_back(leased, status: "revoked", revoked_reason: code) do
          {:ok, revoked} ->
            audit(revoked.user_id, :revoked, revoked, [actor: "system:chatgpt_refresh"], %{
              "reason" => code
            })

            {:error, :revoked}

          :superseded ->
            {:error, :superseded}

          {:failed, reason} ->
            Logger.warning(
              "chatgpt subscription #{leased.id}: refused for good (#{code}), but marking " <>
                "it revoked failed (#{reason})"
            )

            {:error, :refresh_failed}
        end

      {:error, reason} ->
        Logger.warning("chatgpt subscription #{leased.id}: refresh failed: #{loggable(reason)}")
        release_lease(leased)
        {:error, :refresh_failed}
    end
  end

  # OpenAI has already rotated the refresh token, so the stored one is spent:
  # the new pair must reach the row before anyone sees the new access token,
  # and a failed write is retried. A response without a refresh token keeps
  # the old.
  defp store_refreshed(sub, %{access_token: access} = tokens) do
    claims =
      case Tokens.claims(tokens[:id_token]) do
        {:ok, %{account_id: account_id} = c} when account_id == sub.account_id -> c
        _ -> claims(sub)
      end

    with {:ok, access_ct} <- seal(sub, :access_token, access),
         {:ok, refresh_ct} <-
           if(tokens[:refresh_token],
             do: seal(sub, :refresh_token, tokens.refresh_token),
             else: {:ok, sub.refresh_token_ciphertext}
           ) do
      store(
        sub,
        tokens[:refresh_token],
        [
          access_token_ciphertext: access_ct,
          refresh_token_ciphertext: refresh_ct,
          expires_at: Tokens.expires_at(access),
          last_refreshed_at: now(),
          plan_type: claims.plan_type
        ],
        @store_backoff_ms
      )
    else
      {:error, reason} ->
        Logger.error(
          "chatgpt subscription #{sub.id}: refreshed, but the new tokens could not be " <>
            "sealed (#{loggable(reason)}); the stored refresh token is spent and the owner " <>
            "will have to link again"
        )

        {:error, :store_failed}
    end
  end

  defp store(leased, rotated, changes, backoff) do
    case attempt_write_back(leased, changes) do
      {:ok, sub} ->
        {:ok, sub}

      :superseded ->
        # A write whose reply was lost may have landed: then the row holds
        # this refresh's access token.
        written = Keyword.fetch!(changes, :access_token_ciphertext)

        case safely(fn -> Repo.get(Subscription, leased.id) end) do
          {:ok, %Subscription{access_token_ciphertext: ^written} = sub} ->
            {:ok, sub}

          _ ->
            Logger.info(
              "chatgpt subscription #{leased.id}: linked again or removed during a refresh; " <>
                "the old chain's tokens are discarded"
            )

            end_sign_in(leased.user_id, leased.id, present(rotated), "discarded",
              actor: "system:chatgpt_refresh"
            )

            {:error, :superseded}
        end

      {:failed, reason} ->
        case backoff do
          [wait | rest] ->
            Logger.warning(
              "chatgpt subscription #{leased.id}: storing the refreshed tokens failed " <>
                "(#{reason}); retrying"
            )

            Process.sleep(wait)
            store(leased, rotated, changes, rest)

          [] ->
            Logger.error(
              "chatgpt subscription #{leased.id}: refreshed at auth.openai.com, but the " <>
                "rotated refresh token could not be stored (#{reason}); the stored one is " <>
                "spent and the owner will have to link again"
            )

            {:error, :store_failed}
        end
    end
  end

  # The compare-and-swap that ends a refresh, as `{:ok, sub}`, `:superseded`
  # or `{:failed, reason}`. It lands only while this refresh's lease is the
  # row's and the refresh token it spent is still the stored one: a relink
  # (which clears the lease) or a removal in between wins. Clears the lease.
  defp attempt_write_back(leased, changes) do
    query =
      from s in Subscription,
        where:
          s.id == ^leased.id and s.refresh_lease_until == ^leased.refresh_lease_until and
            s.refresh_token_ciphertext == ^leased.refresh_token_ciphertext,
        select: s

    set = Keyword.merge(changes, refresh_lease_until: nil, updated_at: now())

    case safely(fn -> Repo.update_all(query, set: set) end) do
      {:ok, {1, [sub]}} -> {:ok, sub}
      {:ok, {0, _}} -> :superseded
      {:error, reason} -> {:failed, reason}
    end
  end

  # After a transient failure the refresh token was not spent, so the row is
  # free for the next try at once. A failed release lapses with the lease.
  defp release_lease(leased) do
    safely(fn ->
      Repo.update_all(
        from(s in Subscription,
          where: s.id == ^leased.id and s.refresh_lease_until == ^leased.refresh_lease_until
        ),
        set: [refresh_lease_until: nil]
      )
    end)

    :ok
  end

  # A database error as a value. The reason names the error, never a
  # parameter: the statement carries ciphertext.
  defp safely(fun) do
    {:ok, fun.()}
  rescue
    e in DBConnection.ConnectionError -> {:error, "connection: " <> e.message}
    e in Postgrex.Error -> {:error, "postgres " <> to_string(e.postgres[:code] || "error")}
  end

  defp refresh_if_expiring(%Subscription{expires_at: %DateTime{} = at} = sub) do
    if DateTime.diff(at, now()) <= @refresh_margin_seconds do
      case refresh(sub) do
        {:ok, fresh} -> fresh
        {:error, :revoked} -> nil
        {:error, _transient} -> sub
      end
    else
      sub
    end
  end

  defp refresh_if_expiring(sub), do: sub

  # A write to the subscription changes which source a codex run resolves,
  # so it takes its owner's inference source lock. It does not wait for a
  # refresh in flight: a relink clears the lease and replaces the refresh
  # token, so that refresh's write-back no longer matches and its tokens are
  # discarded.
  defp locked_write(user_id, fun) do
    Repo.transaction(fn ->
      InferenceCredentials.lock_source(user_id)

      case fun.(get(user_id)) do
        {:ok, value} -> value
        {:error, %Ecto.Changeset{}} -> Repo.rollback(:invalid)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp seal(%Subscription{user_id: user_id, id: id}, field, token) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      {:ok, Crypto.encrypt(token, dek, aad(user_id, id, field))}
    end
  end

  defp open(%Subscription{} = sub, field) do
    blob =
      case field do
        :access_token -> sub.access_token_ciphertext
        :refresh_token -> sub.refresh_token_ciphertext
      end

    opened =
      with {:ok, dek} <- Crypto.load_tenant_key(sub.user_id),
           do: Crypto.decrypt(blob, dek, aad(sub.user_id, sub.id, field))

    case opened do
      {:ok, token} ->
        {:ok, token}

      _ ->
        Logger.warning(
          "chatgpt subscription #{sub.id}: the stored #{field} does not decrypt; link it again"
        )

        {:error, :undecryptable}
    end
  end

  defp aad(user_id, id, field), do: "fountain.chatgpt_subscription:#{user_id}:#{id}:#{field}"

  defp claims(sub),
    do: %{
      account_id: sub.account_id,
      chatgpt_user_id: sub.chatgpt_user_id,
      plan_type: sub.plan_type
    }

  # The refresh token to end at OpenAI when Fountain lets go of `sub`. A row
  # the auth server already refused holds nothing left to end.
  defp revocable(%Subscription{status: "active"} = sub) do
    case open(sub, :refresh_token) do
      {:ok, token} -> token
      _ -> nil
    end
  end

  defp revocable(_sub), do: nil

  # After the write that let go of `refresh` has committed. Never raises,
  # never undoes that write, never logs the token.
  defp end_sign_in(_user_id, _sub_id, nil, _trigger, _opts), do: :ok

  defp end_sign_in(user_id, sub_id, refresh, trigger, opts) do
    result =
      try do
        OAuth.revoke(refresh)
      rescue
        e -> {:error, {:revoke, inspect(e.__struct__)}}
      end

    {action, metadata} =
      case result do
        :ok ->
          {"revoked_at_openai", %{}}

        {:error, reason} ->
          Logger.warning(
            "chatgpt subscription #{sub_id || "(not stored)"} of user #{user_id}: ending the " <>
              "sign-in at OpenAI failed (#{loggable(reason)}); it stays valid there until it " <>
              "lapses or the owner signs the device out in their ChatGPT account"
          )

          {"not_revoked_at_openai", %{"error" => loggable(reason)}}
      end

    Audit.record(%{
      user_id: Keyword.get(opts, :audit_user_id, user_id),
      action: "chatgpt_subscription.#{action}",
      resource_type: "chatgpt_subscription",
      resource_id: sub_id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: Map.merge(metadata, %{"trigger" => trigger, "user_id" => user_id})
    })

    :ok
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp audit(user_id, what, sub, opts, metadata) do
    Audit.record(%{
      user_id: user_id,
      action: "chatgpt_subscription.#{what}",
      resource_type: "chatgpt_subscription",
      resource_id: sub.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: Map.put(metadata, "plan_type", sub.plan_type)
    })

    :ok
  end

  # Never a body: the OAuth client reduces every failure to a status and a code.
  defp loggable({:token, status, code}), do: "#{status} #{code}"
  defp loggable({:revoke, status, code}), do: "#{status} #{code}"
  defp loggable({:revoke, reason}) when is_binary(reason), do: reason
  defp loggable({:token, reason}) when is_binary(reason), do: reason
  defp loggable(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
