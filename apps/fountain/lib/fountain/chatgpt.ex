defmodule Fountain.ChatGPT do
  @moduledoc """
  ChatGPT subscriptions for the codex runtime (ADR 0070): one per user, and
  one for the deployment that an admin links at `/admin/inference`.

  An owner is `{:user, user_id}` or `:platform`. Every read and write here is
  keyed by owner, so a user-facing caller passes the signed-in user's id and
  reaches nothing else.

  ## Which subscription a codex conversation runs on

  The user's own, else the deployment's, else an OpenAI API key as before
  (`Fountain.InferenceCredentials.Resolver`). Only on a brokered deployment:
  the access token is handed to the egress broker under
  `CODEX_CHATGPT_ACCESS_TOKEN`, substituted on `chatgpt.com`, and never
  enters the sandbox (`Fountain.Conversations.CodexChatGPT`).

  ## When Fountain talks to auth.openai.com

  Only to link (the device-code legs), from the daily keepalive
  (`Fountain.Workers.ChatGPTKeepalive`: every subscription last refreshed
  more than six days ago; an access token lives about ten), and as a safety
  net before a turn when the stored access token has expired or expires
  within ten minutes (`token_for/2`). A turn otherwise only re-reads the
  stored token from the database into the broker's rule.

  A refresh runs under a Postgres advisory try-lock on the row, so the two
  replicas never spend one refresh token twice, and writes the rotated
  refresh token in the same transaction before the new access token is used.
  A refresh the auth server refuses for good marks the subscription
  `revoked`; its conversations then fail with `chatgpt_reconnect_required`
  until the owner links again.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.{Audit, Crypto, InferenceCredentials, Repo}
  alias Fountain.ChatGPT.{OAuth, Subscription, Tokens}

  @type owner :: {:user, Ecto.UUID.t()} | :platform

  @refresh_margin_seconds 10 * 60
  @refresh_after_days 6

  @doc "The subscription of `owner`, active or revoked, or nil."
  @spec get(owner()) :: Subscription.t() | nil
  def get({:user, user_id}) when is_binary(user_id),
    do: Repo.get_by(Subscription, user_id: user_id)

  def get(:platform) do
    Repo.one(from s in Subscription, where: is_nil(s.user_id))
  end

  @doc "Whether `owner` has an active subscription."
  @spec active?(owner()) :: boolean()
  def active?(owner), do: match?(%Subscription{status: "active"}, get(owner))

  @doc """
  Link `owner`'s subscription from the tokens a sign-in produced, replacing
  the one it had. The account comes from the `id_token`'s claims.

  `opts`: `:method` (`"device_code"` or `"auth_json"`), and attribution:
  `:actor` and `:request_ip` for a user, `:actor_user_id` for the platform.
  """
  @spec connect(owner(), OAuth.tokens(), keyword()) ::
          {:ok, Subscription.t()} | {:error, atom()}
  def connect(owner, %{access_token: access} = tokens, opts \\ []) when is_binary(access) do
    with refresh when is_binary(refresh) and refresh != "" <- tokens[:refresh_token],
         {:ok, claims} <- Tokens.claims(tokens[:id_token]) do
      now = now()

      result =
        locked_write(owner, fn existing ->
          sub = existing || %Subscription{id: Ecto.UUID.generate(), user_id: user_id(owner)}

          with {:ok, access_ct} <- seal(sub, :access_token, access),
               {:ok, refresh_ct} <- seal(sub, :refresh_token, refresh) do
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
              revoked_reason: nil
            })
            |> Repo.insert_or_update()
          end
        end)

      with {:ok, sub} <- result do
        audit(owner, :connected, sub, opts, %{"method" => Keyword.get(opts, :method)})
        {:ok, sub}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :no_refresh_token}
    end
  end

  @doc "`connect/3` from the `auth.json` that `codex login` wrote."
  @spec connect_auth_json(owner(), String.t(), keyword()) ::
          {:ok, Subscription.t()} | {:error, atom()}
  def connect_auth_json(owner, json, opts \\ []) do
    with {:ok, tokens} <- Tokens.parse_auth_json(json) do
      connect(owner, tokens, Keyword.put(opts, :method, "auth_json"))
    end
  end

  @doc """
  Remove `owner`'s subscription and its tokens. Fountain cannot revoke a
  sign-in at OpenAI. `:ok` whether or not there was one; only a removal is
  audited.
  """
  @spec disconnect(owner(), keyword()) :: :ok
  def disconnect(owner, opts \\ []) do
    case locked_write(owner, fn existing -> {:ok, existing && Repo.delete!(existing)} end) do
      {:ok, %Subscription{} = sub} -> audit(owner, :disconnected, sub, opts, %{})
      _ -> :ok
    end

    :ok
  end

  @doc """
  The subscription a codex run of `user_id` would use, with its access
  token: the user's own, else (when `platform?`) the deployment's.
  `:none` when neither is active or a token does not decrypt.

  A database read and a decrypt, no provider I/O: it runs under the
  inference source lock (`InferenceCredentials.Resolver`). An expired token
  is returned as it is; the turn's `token_for/2` deals with that.
  """
  @spec serving(Ecto.UUID.t(), boolean()) :: {:ok, owner(), Subscription.t(), String.t()} | :none
  def serving(user_id, platform?) do
    owners = if platform?, do: [{:user, user_id}, :platform], else: [{:user, user_id}]

    Enum.find_value(owners, :none, fn owner ->
      with %Subscription{status: "active"} = sub <- get(owner),
           {:ok, token} <- open(sub, :access_token) do
        {:ok, owner, sub, token}
      else
        _ -> nil
      end
    end)
  end

  @doc """
  The access token to put in the broker's rule before a turn of a
  conversation bound to `owner`'s subscription on `account_id`.

  Reads the stored token. Only when it has expired or expires within ten
  minutes does it refresh first (the keepalive should have); a refresh that
  fails for a transient reason, or that another replica is running, leaves
  the stored token in place. `{:error, :chatgpt_reconnect_required}` when the
  subscription is gone, revoked, or now on another account.
  """
  @spec token_for(owner(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :chatgpt_reconnect_required}
  def token_for(owner, account_id) do
    with %Subscription{status: "active", account_id: ^account_id} = sub <- get(owner),
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
  @spec sandbox_auth(owner(), String.t() | nil) ::
          {:ok, %{account_id: String.t(), id_token: String.t()}}
          | {:error, :chatgpt_reconnect_required}
  def sandbox_auth(owner, account_id) do
    case get(owner) do
      %Subscription{status: "active", account_id: ^account_id} = sub ->
        {:ok, %{account_id: sub.account_id, id_token: Tokens.synthesize_id_token(claims(sub))}}

      _ ->
        {:error, :chatgpt_reconnect_required}
    end
  end

  @doc """
  Exchange the subscription's refresh token for a new pair, under a
  Postgres advisory try-lock on the row.

  `{:ok, sub}` with the row as it now is (refreshed here, or by whoever held
  the lock and finished first); `{:error, :locked}` when another process
  holds it now; `{:error, :revoked}` when the auth server refused the
  refresh token for good, which marks the row and audits it; `{:error, :gone}`
  when the row was removed or is already revoked; any other error is
  transient and the row is unchanged. A row refreshed since `seen` was read
  is returned as it is, not refreshed twice.
  """
  @spec refresh(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term()}
  def refresh(%Subscription{id: id, last_refreshed_at: cutoff}) do
    result =
      Repo.transaction(
        fn ->
          if try_lock(id), do: refresh_locked(id, cutoff), else: {:error, :locked}
        end,
        timeout: 30_000
      )

    case result do
      {:ok, {:revoked, sub, code}} ->
        audit(owner(sub), :revoked, sub, [actor: "system:chatgpt_refresh"], %{"reason" => code})
        {:error, :revoked}

      {:ok, result} ->
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The active subscriptions last refreshed more than six days ago. For the keepalive."
  @spec _unsafe_due_for_refresh() :: [Subscription.t()]
  def _unsafe_due_for_refresh do
    cutoff = DateTime.add(now(), -@refresh_after_days * 86_400)

    Repo.all(
      from s in Subscription,
        where: s.status == "active" and s.last_refreshed_at < ^cutoff,
        order_by: s.last_refreshed_at
    )
  end

  @doc "The owner of a row."
  @spec owner(Subscription.t()) :: owner()
  def owner(%Subscription{user_id: nil}), do: :platform
  def owner(%Subscription{user_id: user_id}), do: {:user, user_id}

  # ── internals ────────────────────────────────────────────────────────────

  defp refresh_locked(id, cutoff) do
    case Repo.get(Subscription, id) do
      %Subscription{status: "active"} = sub ->
        if DateTime.compare(sub.last_refreshed_at, cutoff) == :gt,
          do: {:ok, sub},
          else: exchange(sub)

      _ ->
        {:error, :gone}
    end
  end

  defp exchange(sub) do
    with {:ok, refresh_token} <- open(sub, :refresh_token),
         {:ok, tokens} <- OAuth.refresh(refresh_token) do
      store_refreshed(sub, tokens)
    else
      {:error, {:terminal, code}} ->
        revoked =
          sub
          |> Ecto.Changeset.change(status: "revoked", revoked_reason: code)
          |> Repo.update!()

        {:revoked, revoked, code}

      {:error, reason} ->
        Logger.warning("chatgpt subscription #{sub.id}: refresh failed: #{loggable(reason)}")
        {:error, :refresh_failed}
    end
  end

  # The rotated refresh token is written in this transaction, before anyone
  # sees the new access token. A response without one keeps the old.
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
      {:ok,
       sub
       |> Ecto.Changeset.change(%{
         access_token_ciphertext: access_ct,
         refresh_token_ciphertext: refresh_ct,
         expires_at: Tokens.expires_at(access),
         last_refreshed_at: now(),
         plan_type: claims.plan_type
       })
       |> Repo.update!()}
    end
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
  # so it takes the inference source lock of its owner (platform before
  # tenant, as everywhere), then the row's own lock, which a refresh holds
  # while it talks to the auth server: a relink never interleaves with a
  # refresh of the old chain.
  defp locked_write(owner, fun) do
    Repo.transaction(fn ->
      case owner do
        {:user, user_id} -> InferenceCredentials.lock_tenant_source(user_id)
        :platform -> InferenceCredentials.lock_platform_source()
      end

      existing = get(owner)
      if existing, do: lock(existing.id)

      case fun.(existing) do
        {:ok, value} -> value
        {:error, %Ecto.Changeset{}} -> Repo.rollback(:invalid)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock(id),
    do: Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_key(id)])

  defp try_lock(id) do
    %{rows: [[locked?]]} =
      Repo.query!("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))", [lock_key(id)])

    locked?
  end

  defp lock_key(id), do: "chatgpt_subscription:" <> id

  defp seal(%Subscription{user_id: nil}, _field, token), do: {:ok, Crypto.encrypt_platform(token)}

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
      case sub.user_id do
        nil ->
          Crypto.decrypt_platform(blob)

        user_id ->
          with {:ok, dek} <- Crypto.load_tenant_key(user_id),
               do: Crypto.decrypt(blob, dek, aad(user_id, sub.id, field))
      end

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

  defp user_id({:user, user_id}), do: user_id
  defp user_id(:platform), do: nil

  defp audit({:user, user_id}, what, sub, opts, metadata) do
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

  defp audit(:platform, what, sub, opts, metadata) do
    Audit.record_admin(%{
      actor_user_id: Keyword.get(opts, :actor_user_id),
      event_type: "admin.platform_chatgpt.#{what}",
      metadata: Map.put(metadata, "plan_type", sub.plan_type)
    })

    :ok
  end

  # Never a body: the OAuth client reduces every failure to a status and a code.
  defp loggable({:token, status, code}), do: "#{status} #{code}"
  defp loggable({:token, reason}) when is_binary(reason), do: reason
  defp loggable(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
