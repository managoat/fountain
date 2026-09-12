defmodule Fountain.ChatGPTAccounts do
  @moduledoc """
  ChatGPT grant storage for both owners a grant can have (ADRs 0047/0052):
  the deployment, and -- when the rest of ADR 0052 lands -- a tenant.

  Token encryption follows the row's ownership, which never changes: the
  null-owner row keeps the deployed platform format, an owned row uses its
  owner's DEK with an AAD naming both the owner and the token field, so no
  blob decrypts in the wrong row or the wrong column
  (`Fountain.ChatGPTAccounts.Cipher`).

  ## The two prefixes

  `platform_*` is the deployment's grant: every one of those functions
  queries `where: is_nil(a.user_id)` and cannot reach a tenant's row, the
  way `Fountain.PlatformInference` is deployment-scoped. `*_for_user` takes
  the owner as its first scope. Neither is `_unsafe_`: nothing here reads
  across tenants, so there is no ownership for a call site to establish.

  ## Platform grant

  An admin signs the Fountain **server** in to ChatGPT once, by pasting the
  `auth.json` a laptop's `codex login` wrote or by the device-code flow
  (`Fountain.PlatformChatGPT.Device`). From then on Fountain owns the
  refresh token and is the only thing that ever uses it: the token rotates
  on every refresh, and the one place it lives is the one place that is
  refreshed. A sandbox never sees it. What a sandbox gets is `auth.json` in
  `chatgptAuthTokens` mode with a placeholder where the bearer goes
  (`Fountain.Conversations.CodexChatGPT`), and the broker substitutes the
  current access token on `chatgpt.com` (`Fountain.Broker`).

    * `platform_access_token/0` -- the current access token, refreshed when
      it is within `PLATFORM_CHATGPT_REFRESH_MARGIN_SECONDS` of its expiry,
      through `Fountain.PlatformChatGPT.Refresher` so the deployment's many
      conversations queue on one round-trip rather than each making their
      own. The rotated refresh token is persisted *before* the new access
      token is handed out. A terminal refusal marks the row `revoked` with
      the server's reason code; a workspace token past its expiry marks it
      `expired`.
    * `platform_credential/1` -- `{:ok, token}` or `:none`, for
      `Fountain.InferenceCredentials.select/4`, which takes the grant for a
      codex agent whose tenant has no OpenAI key of their own.
    * `platform_sandbox_auth/0` -- the account id and the synthesised
      `id_token` the sandbox file carries; never the real one.
    * `platform_connect_from_auth_json/2`,
      `platform_connect_from_tokens/3`,
      `platform_connect_workspace_token/3`, `platform_disconnect/1` -- the
      admin mutations, each leaving an `admin.platform_chatgpt.*` row on the
      privilege trail. Never a token, never a claim that is a secret.
    * `platform_keepalive/0` -- refresh a grant nobody has used for
      `PLATFORM_CHATGPT_KEEPALIVE_DAYS`, so it never idles past the auth
      server's window (`Fountain.Workers.PlatformChatGPTKeepalive`).
    * `platform_status/0` -- what the admin page shows.

  The refresh margin must exceed the longest turn the deployment expects:
  a turn that outlives its access token fails at the proxy, because codex
  cannot refresh in this mode. The default is fifteen minutes.

  Platform refresh is coordinated across nodes with a per-grant PostgreSQL
  try-lock. Only the holder retains a database checkout across the provider
  request; contenders release theirs between bounded retries.

  ## User grants

  `status_for_user/1` and `credential_for_user/3` read a tenant's own grant.
  Both are scoped by the owner and neither falls through to the platform
  row. Near-expiry reads renew through bounded per-grant workers and the
  PostgreSQL refresh lock, using only the owner's encryption key. Callers
  re-read their pinned grant after renewal; the coordinator holds no tokens.
  User linking, conversation selection and user keepalive scheduling remain
  unbuilt. No account API exposes this internal credential read.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.Audit
  alias Fountain.Accounts.User
  alias Fountain.ChatGPTAccounts.{Cipher, Grant, RefreshCoordinator, RefreshLock}
  alias Fountain.PlatformChatGPT.{Account, OAuth, Refresher, Tokens}
  alias Fountain.Repo

  @system_actor "system:platform_chatgpt"

  @doc """
  Connection metadata only; does not decrypt tokens or start a refresh.

  `:grant_id` and `:generation` are the pin `credential_for_user/3` takes,
  so the two halves compose: a caller reads the grant here and asks for a
  bearer from that exact version. Neither is a secret -- the generation is
  a lifecycle counter, not key material.
  """
  @spec status_for_user(String.t()) :: :not_connected | map()
  def status_for_user(user_id) when is_binary(user_id) do
    from(a in Account,
      where: a.user_id == ^user_id,
      select: %{
        grant_id: a.id,
        generation: a.generation,
        status: a.status,
        kind: a.kind,
        account_id: a.account_id,
        account_email: a.account_email,
        plan_type: a.plan_type,
        access_expires_at: a.access_expires_at,
        last_refreshed_at: a.last_refreshed_at,
        revoked_reason: a.revoked_reason,
        updated_at: a.updated_at
      }
    )
    |> Repo.one()
    |> case do
      nil -> :not_connected
      status -> Map.update!(status, :revoked_reason, &safe_reason/1)
    end
  end

  @doc """
  Internal server credential read for an explicitly selected user grant.

  The owner scopes the first query. The returned bearer and provider metadata
  come from one row version. A near-expiry grant renews through the bounded
  user coordinator, then the caller reads that same generation again. With
  `refresh: false`, near-expiry grants return `:refresh_required`. Neither path
  falls back to a different grant or paid inference. Only verified, claimed,
  non-suspended owners can obtain or renew a credential.
  """
  @spec credential_for_user(String.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Grant.t()} | {:error, atom()}
  def credential_for_user(grant_id, user_id, generation, opts \\ [])
      when is_binary(grant_id) and is_binary(user_id) and is_binary(generation) do
    with {:ok, account} <- pinned_user_grant(grant_id, user_id, generation) do
      case {user_credential(account), Keyword.get(opts, :refresh, true)} do
        {{:error, :refresh_required}, true} ->
          with :ok <- refresh_for_user(grant_id, user_id, generation) do
            credential_for_user(grant_id, user_id, generation, refresh: false)
          end

        {result, _} ->
          result
      end
    end
  end

  @doc "Internal renewal admission; returns only status, never a bearer."
  @spec refresh_for_user(String.t(), String.t(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def refresh_for_user(grant_id, user_id, generation)
      when is_binary(grant_id) and is_binary(user_id) and is_binary(generation) do
    with {:ok, account} <- pinned_user_grant(grant_id, user_id, generation),
         :ok <- user_account_state(account) do
      RefreshCoordinator.run(grant_id, user_id, generation)
    end
  end

  @doc false
  def refresh_serialized_for_user(grant_id, user_id, generation)
      when is_binary(grant_id) and is_binary(user_id) and is_binary(generation) do
    with {:ok, observed} <- pinned_user_grant(grant_id, user_id, generation),
         :ok <- user_account_state(observed) do
      grant_id
      |> RefreshLock.run(fn -> refresh_user_locked(observed) end)
      |> finish_refresh()
    end
  end

  defp refresh_user_locked(observed) do
    with {:ok, current} <- pinned_user_grant(observed.id, observed.user_id, observed.generation),
         :ok <- user_account_state(current) do
      cond do
        current.lock_version != observed.lock_version -> :ok
        fresh?(current) and not stale_for_keepalive?(current) -> :ok
        true -> do_refresh(current)
      end
    end
  end

  defp user_credential(account) do
    with :ok <- user_account_state(account) do
      if fresh?(account) do
        with {:ok, access_token} <- Cipher.decrypt_token(account, :access_token) do
          {:ok, Grant.new(account, access_token)}
        end
      else
        {:error, :refresh_required}
      end
    end
  end

  defp user_account_state(%Account{status: "revoked"}), do: {:error, :revoked}
  defp user_account_state(%Account{status: "expired"}), do: {:error, :expired}

  defp user_account_state(%Account{
         status: "active",
         kind: "chatgpt",
         account_id: id,
         refresh_token_ciphertext: cipher
       })
       when is_binary(id) and id != "" and is_binary(cipher) and byte_size(cipher) > 0,
       do: :ok

  defp user_account_state(_), do: {:error, :invalid_grant}

  defp pinned_user_grant(grant_id, user_id, generation) do
    case Repo.one(user_grant_query(grant_id, user_id)) do
      nil -> {:error, :not_connected}
      %Account{generation: ^generation} = account -> {:ok, account}
      %Account{} -> {:error, :stale_grant}
    end
  end

  defp user_grant_query(grant_id, user_id) when is_binary(user_id) do
    from(a in Account,
      where: a.user_id == ^user_id and a.id == ^grant_id,
      join: u in User,
      on: u.id == a.user_id,
      where: not u.principal and not is_nil(u.email_verified_at) and is_nil(u.suspended_at)
    )
  end

  # Only a code `OAuth` itself names can reach a tenant: a reason that is not
  # one of those did not come from the paths that write this column, and the
  # tenant page is the wrong place to find out what it was. Allowlisted
  # against `OAuth.terminal_codes/0` rather than a second copy of the list,
  # because the copy this replaced was already missing
  # `invalid_refresh_token_ciphertext_integrity`.
  defp safe_reason(nil), do: nil

  defp safe_reason(reason) do
    if reason in OAuth.terminal_codes(), do: reason, else: "provider_error"
  end

  # ── reads ────────────────────────────────────────────────────────────────

  @doc "Whether the deployment holds a usable grant right now (no refresh is attempted)."
  @spec platform_active?() :: boolean()
  def platform_active?, do: match?(%Account{status: "active"}, platform_row())

  @doc """
  The grant as `Fountain.InferenceCredentials.select/4` wants it:
  `{:ok, access_token}` when it is active and refreshable, else `:none`.

  `refresh: false` answers from the row alone, refreshing nothing: for a
  caller that only asks whether a grant is there (a page render), not for
  one about to hand the token to a sandbox.
  """
  @spec platform_credential(keyword()) :: {:ok, String.t()} | :none
  def platform_credential(opts \\ []) do
    if Keyword.get(opts, :refresh, true) do
      case platform_access_token() do
        {:ok, token} -> {:ok, token}
        _ -> :none
      end
    else
      case platform_row() do
        %Account{status: "active"} = row ->
          case Cipher.decrypt_token(row, :access_token) do
            {:ok, token} -> {:ok, token}
            _ -> :none
          end

        _ ->
          :none
      end
    end
  end

  @doc """
  A valid access token, refreshing when within the margin of expiry.
  `{:error, :not_connected}`, `{:error, :revoked}` or `{:error, :expired}`
  when there is nothing to hand out; a transient refresh failure comes
  back as its reason and the caller keeps what it has.
  """
  @spec platform_access_token() :: {:ok, String.t()} | {:error, term()}
  def platform_access_token do
    case platform_row() do
      nil -> {:error, :not_connected}
      %Account{status: "revoked"} -> {:error, :revoked}
      %Account{status: "expired"} -> {:error, :expired}
      %Account{} = row -> serve(row)
    end
  end

  defp serve(row) do
    cond do
      fresh?(row) -> Cipher.decrypt_token(row, :access_token)
      is_nil(row.refresh_token_ciphertext) -> expire_or_serve(row)
      true -> Refresher.refresh(:if_stale)
    end
  end

  # A workspace token has no refresh token: it is served until it has
  # really lapsed (the margin is for refreshing, not for cutting off), then
  # the row goes `expired`.
  defp expire_or_serve(row) do
    if lapsed?(row) do
      case mark_expired(row) do
        :ok -> {:error, :expired}
        :stale -> current_result(row)
      end
    else
      Cipher.decrypt_token(row, :access_token)
    end
  end

  @doc """
  What the sandbox's `auth.json` carries beside the placeholder: the real
  account id (not a secret; it goes in a header codex sends in the clear)
  and an unsigned `id_token` built from the stored claims. Whatever the
  row's status: the file holds a placeholder, and the token that matters is
  the one the broker already took at selection. Only a row that is gone, or
  one with no account id, is `:none`.
  """
  @spec platform_sandbox_auth() ::
          {:ok, %{account_id: String.t(), id_token: String.t()}} | :none
  def platform_sandbox_auth do
    case platform_row() do
      %Account{account_id: account_id, id_claims: claims} when is_binary(account_id) ->
        {:ok, %{account_id: account_id, id_token: Tokens.synthesize_id_token(claims)}}

      _ ->
        :none
    end
  end

  @doc """
  The row for `/admin/inference`: `:not_connected`, or a map with `:status`
  (`"active"` | `"revoked"` | `"expired"`), `:kind`, `:account_email`,
  `:plan_type`, `:account_id`, `:access_expires_at`, `:last_refreshed_at`,
  `:revoked_reason`, `:updated_at` and `:updated_by`.
  """
  @spec platform_status() :: :not_connected | map()
  def platform_status do
    case platform_row([:updated_by]) do
      nil ->
        :not_connected

      row ->
        %{
          status: row.status,
          kind: row.kind,
          account_email: row.account_email,
          plan_type: row.plan_type,
          account_id: row.account_id,
          access_expires_at: row.access_expires_at,
          last_refreshed_at: row.last_refreshed_at,
          revoked_reason: row.revoked_reason,
          updated_at: row.updated_at,
          updated_by: row.updated_by && row.updated_by.email
        }
    end
  end

  # ── connect / disconnect ─────────────────────────────────────────────────

  @doc """
  Connect from the `auth.json` a laptop's `codex login` wrote (OpenAI's own
  CI recipe). Refused unless it is a ChatGPT login with a refresh token.
  From here on that file is Fountain's: using it anywhere else breaks both.
  """
  @spec platform_connect_from_auth_json(String.t(), keyword()) ::
          {:ok, Account.t()} | {:error, term()}
  def platform_connect_from_auth_json(json, opts \\ []) do
    with {:ok, tokens} <- Tokens.parse_auth_json(json) do
      platform_connect_from_tokens(tokens, "paste", opts)
    end
  end

  @doc """
  Store a token set from a paste or the device flow. `method` is recorded
  on the `admin.platform_chatgpt.connected` event. The `id_token` must
  carry an account id: without it codex has nothing to send in
  `chatgpt-account-id`, and the backend refuses the request.
  """
  @spec platform_connect_from_tokens(OAuth.tokens(), String.t(), keyword()) ::
          {:ok, Account.t()} | {:error, term()}
  def platform_connect_from_tokens(%{access_token: access} = tokens, method, opts \\ [])
      when is_binary(access) and is_binary(method) do
    with refresh when is_binary(refresh) and refresh != "" <-
           Map.get(tokens, :refresh_token) || {:error, :no_refresh_token},
         {:ok, claims} <- Tokens.claims(Map.get(tokens, :id_token) || "") do
      actor_user_id = Keyword.get(opts, :actor_user_id)

      attrs = %{
        kind: "chatgpt",
        refresh_token_ciphertext: Cipher.encrypt_platform_token(refresh),
        access_token_ciphertext: Cipher.encrypt_platform_token(access),
        id_claims: Map.drop(claims, ["email"]),
        account_id: claims["account_id"],
        account_email: claims["email"],
        plan_type: claims["plan_type"],
        access_expires_at: Tokens.expires_at(access),
        last_refreshed_at: now(),
        updated_by_user_id: actor_user_id
      }

      store(attrs, method, actor_user_id)
    else
      {:error, _} = error -> error
      _ -> {:error, :no_refresh_token}
    end
  end

  @doc """
  Connect with a ChatGPT Business or Enterprise workspace access token
  (`CODEX_ACCESS_TOKEN`): static, non-refreshing, and OpenAI's sanctioned
  non-interactive credential, so where it exists it is the one to use.
  `expires_on` is the expiry the admin console shows, or nil for none;
  the row goes `expired` when it passes. The account id is taken from the
  token when it is a JWT, else from `:account_id` in `opts`; without one
  the connect is refused (`{:error, :no_account_id}`), because codex sends
  it on every request and a row without it would fail every provision
  while the page said "connected".
  """
  @spec platform_connect_workspace_token(String.t(), Date.t() | nil, keyword()) ::
          {:ok, Account.t()} | {:error, term()}
  def platform_connect_workspace_token(token, expires_on, opts \\ [])
      when is_binary(token) do
    token = String.trim(token)
    actor_user_id = Keyword.get(opts, :actor_user_id)

    with :ok <- validate_token(token),
         {:ok, account_id, claims} <- workspace_claims(token, Keyword.get(opts, :account_id)) do
      attrs = %{
        kind: "workspace_token",
        refresh_token_ciphertext: nil,
        access_token_ciphertext: Cipher.encrypt_platform_token(token),
        id_claims: claims,
        account_id: account_id,
        account_email: nil,
        plan_type: claims["plan_type"] || "workspace",
        access_expires_at: workspace_expiry(token, expires_on),
        last_refreshed_at: now(),
        updated_by_user_id: actor_user_id
      }

      store(attrs, "workspace_token", actor_user_id)
    end
  end

  @doc """
  Forget the grant. Running conversations keep the session they hold until
  their next turn's re-read; new codex conversations fall through to the
  platform `OPENAI_API_KEY`, or to no credential. `:ok` either way; the
  event is recorded only when a row was there.
  """
  @spec platform_disconnect(keyword()) :: :ok
  def platform_disconnect(opts \\ []) do
    {:ok, deleted} =
      Repo.transaction(fn ->
        case locked_platform_row() do
          nil -> nil
          row -> Repo.delete!(row)
        end
      end)

    case deleted do
      nil ->
        :ok

      %Account{} = row ->
        Audit.record_admin(%{
          actor_user_id: Keyword.get(opts, :actor_user_id),
          event_type: "admin.platform_chatgpt.disconnected",
          metadata: %{"account_id" => row.account_id, "kind" => row.kind}
        })

        :ok
    end
  end

  # `locked_platform_row/0` holds `FOR UPDATE` for the whole transaction, so
  # the optimistic lock in `connect_changeset/2` cannot lose a race; it is
  # there to advance `lock_version` on a reconnect, not to detect one. Two
  # concurrent connects onto an empty table meet
  # `platform_chatgpt_account_platform_row` instead and one is refused.
  defp store(attrs, method, actor_user_id) do
    result =
      Repo.transaction(fn ->
        case (locked_platform_row() || %Account{})
             |> Account.connect_changeset(attrs)
             |> Repo.insert_or_update() do
          {:ok, account} -> account
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, account} ->
        Audit.record_admin(%{
          actor_user_id: actor_user_id,
          event_type: "admin.platform_chatgpt.connected",
          metadata: %{
            "method" => method,
            "kind" => account.kind,
            "account_id" => account.account_id,
            "email" => account.account_email,
            "plan" => account.plan_type
          }
        })

        {:ok, account}

      {:error, _changeset} ->
        {:error, :invalid_grant}
    end
  end

  # ── refresh ──────────────────────────────────────────────────────────────

  @doc """
  Refresh the grant now if nobody has for `PLATFORM_CHATGPT_KEEPALIVE_DAYS`,
  whatever the access token's expiry says. `{:ok, :refreshed}`,
  `{:ok, :skipped}` (nothing to do: not connected, not a refreshable grant,
  or renewed recently), or the refresh's error.
  """
  @spec platform_keepalive() :: {:ok, :refreshed | :skipped} | {:error, term()}
  def platform_keepalive do
    case platform_row() do
      %Account{status: "active", refresh_token_ciphertext: cipher} = row
      when is_binary(cipher) ->
        if stale_for_keepalive?(row) do
          case Refresher.refresh(:force) do
            {:ok, _token} -> {:ok, :refreshed}
            {:error, _} = error -> error
          end
        else
          {:ok, :skipped}
        end

      _ ->
        {:ok, :skipped}
    end
  end

  @doc false
  # The local queue bounds platform holders to one per node. The database
  # try-lock excludes other nodes without parking waiters on pool connections.
  # Observe identity before waiting, then re-read under the lock: even forced
  # refresh contenders serve a winner instead of exchanging its rotated token.
  def platform_refresh_serialized(mode) do
    case platform_row() do
      %Account{status: "active", refresh_token_ciphertext: cipher} = observed
      when is_binary(cipher) ->
        observed.id
        |> RefreshLock.run(fn -> refresh_locked(observed, mode) end)
        |> finish_refresh()

      _ ->
        refresh_without_exchange()
    end
  end

  defp refresh_locked(observed, mode) do
    case platform_row() do
      %Account{id: id, generation: generation} = current
      when id == observed.id and generation == observed.generation ->
        cond do
          current.status != "active" or current.lock_version != observed.lock_version ->
            current_result(observed)

          mode == :if_stale and fresh?(current) ->
            Cipher.decrypt_token(current, :access_token)

          true ->
            do_refresh(current)
        end

      nil ->
        {:error, :not_connected}

      %Account{} ->
        {:error, :stale_grant}
    end
  end

  # Static workspace tokens do not need a refresh lock.
  defp refresh_without_exchange do
    case platform_row() do
      nil ->
        {:error, :not_connected}

      %Account{status: "revoked"} ->
        {:error, :revoked}

      %Account{status: "expired"} ->
        {:error, :expired}

      %Account{refresh_token_ciphertext: nil} = row ->
        Cipher.decrypt_token(row, :access_token)

      %Account{} ->
        {:error, :stale_grant}
    end
  end

  defp finish_refresh({:revoked, account_id, code}) do
    record_revocation(account_id, code)
    {:error, :revoked}
  end

  defp finish_refresh({:user_revoked, user_id, grant_id, generation, code}) do
    Audit.record(%{
      user_id: user_id,
      actor: "system:chatgpt_accounts",
      action: "chatgpt.reconnect_required",
      resource_type: "chatgpt_grant",
      resource_id: grant_id,
      metadata: %{"generation" => generation, "reason" => code}
    })

    {:error, :revoked}
  end

  defp finish_refresh(result), do: result

  defp do_refresh(current) do
    with {:ok, refresh} <- Cipher.decrypt_token(current, :refresh_token) do
      case OAuth.refresh(refresh) do
        {:ok, %{access_token: access} = fresh} ->
          # The rotated refresh token lands before the access token is
          # handed out: a crash between the two would otherwise leave the
          # row holding a refresh token the server has already retired.
          with :ok <- validate_refresh_identity(current, fresh),
               {:ok, attrs} <- refresh_attrs(current, fresh) do
            swap_in(current, attrs, access)
          end

        {:error, {:terminal, code}} ->
          case mark_revoked(current, code) do
            :ok -> revoked_result(current, code)
            :stale -> current_result(current)
          end

        {:error, reason} ->
          refresh_error(current, reason)
      end
    end
  end

  # Refresh and terminal writes share a fence. A reconnect may reuse the
  # same refresh token, and a refresh need not rotate it, so ciphertext alone
  # is not a lifecycle version. Never serve a replacement generation here:
  # the caller may already have pinned the old provider account metadata.
  defp swap_in(current, attrs, access) do
    sets = attrs |> Map.put(:updated_at, now()) |> Enum.to_list()

    {n, _} =
      current_query(current)
      |> Repo.update_all(set: sets, inc: [lock_version: 1])

    case n do
      1 -> refreshed_result(current, access)
      0 -> current_result(current)
    end
  end

  defp current_query(row) do
    query =
      if is_nil(row.user_id),
        do: from(a in Account, where: is_nil(a.user_id)),
        else: user_grant_query(row.id, row.user_id)

    from(a in query,
      where:
        a.id == ^row.id and a.generation == ^row.generation and
          a.lock_version == ^row.lock_version and a.status == "active"
    )
  end

  defp current_result(previous) do
    row =
      if is_nil(previous.user_id),
        do: platform_row(),
        else: Repo.one(user_grant_query(previous.id, previous.user_id))

    case row do
      nil ->
        {:error, :not_connected}

      %Account{id: id, generation: generation} = current
      when id == previous.id and generation == previous.generation ->
        case current.status do
          "active" -> current_active_result(current)
          "revoked" -> {:error, :revoked}
          "expired" -> {:error, :expired}
          other -> {:error, {:unknown_status, other}}
        end

      %Account{} ->
        {:error, :stale_grant}
    end
  end

  defp current_active_result(%Account{user_id: nil} = account),
    do: Cipher.decrypt_token(account, :access_token)

  defp current_active_result(account), do: user_account_state(account)

  defp refreshed_result(%Account{user_id: nil}, access), do: {:ok, access}
  defp refreshed_result(%Account{}, _access), do: :ok

  defp revoked_result(%Account{user_id: nil} = account, code),
    do: {:revoked, account.account_id, code}

  defp revoked_result(account, code),
    do: {:user_revoked, account.user_id, account.id, account.generation, code}

  defp refresh_error(%Account{user_id: nil}, reason) do
    Logger.warning(
      "platform chatgpt: refresh failed, keeping the current token: " <> inspect(reason)
    )

    {:error, reason}
  end

  defp refresh_error(%Account{}, _reason) do
    # Provider bodies can echo tokens. Neither queue replies nor logs carry
    # that response; callers get a stable retryable error instead.
    :telemetry.execute([:fountain, :chatgpt, :refresh, :failure], %{count: 1}, %{scope: :user})
    {:error, :refresh_failed}
  end

  defp validate_refresh_identity(%Account{user_id: nil}, _fresh), do: :ok
  defp validate_refresh_identity(_account, %{id_token: nil}), do: :ok

  defp validate_refresh_identity(account, fresh) do
    case fresh[:id_token] && Tokens.claims(fresh[:id_token]) do
      nil ->
        :ok

      {:ok, claims} ->
        same_user =
          is_nil(account.id_claims["user_id"]) or
            claims["user_id"] == account.id_claims["user_id"]

        if claims["account_id"] == account.account_id and same_user,
          do: :ok,
          else: {:error, :account_mismatch}

      _ ->
        {:error, :account_mismatch}
    end
  end

  defp refresh_attrs(current, fresh) do
    with {:ok, encrypted} <- Cipher.encrypt_refresh_tokens(current, fresh) do
      {:ok, Map.merge(refresh_metadata(fresh), encrypted)}
    end
  end

  defp refresh_metadata(%{access_token: access} = fresh) do
    base = %{
      access_expires_at: Tokens.expires_at(access),
      last_refreshed_at: now()
    }

    case fresh[:id_token] && Tokens.claims(fresh[:id_token]) do
      {:ok, claims} ->
        Map.merge(base, %{
          id_claims: Map.drop(claims, ["email"]),
          account_id: claims["account_id"],
          account_email: claims["email"],
          plan_type: claims["plan_type"]
        })

      _ ->
        base
    end
  end

  defp mark_revoked(row, code) do
    {count, _} =
      current_query(row)
      |> Repo.update_all(
        set: [status: "revoked", revoked_reason: code, updated_at: now()],
        inc: [lock_version: 1]
      )

    if count == 1 do
      :ok
    else
      :stale
    end
  end

  defp record_revocation(account_id, code) do
    Audit.record_admin(%{
      actor_user_id: nil,
      event_type: "admin.platform_chatgpt.revoked",
      metadata: %{"actor" => @system_actor, "reason" => code, "account_id" => account_id}
    })

    Logger.warning(
      "platform chatgpt: the auth server refused the refresh token (#{code}); " <>
        "codex conversations fall back to PLATFORM_OPENAI_API_KEY. Reconnect at /admin/inference."
    )
  end

  # `:stale` is narrow here in a way it is not on the refresh path: nothing
  # blocks between the read in `platform_access_token/0` and this write, so
  # only a reconnect landing inside those microseconds loses the fence. It is
  # still routed through `current_result/1` rather than assumed away, because
  # reporting `:expired` for a grant that is now active is the same class of
  # wrong answer the fence exists to prevent.
  defp mark_expired(row) do
    {count, _} =
      current_query(row)
      |> Repo.update_all(set: [status: "expired", updated_at: now()], inc: [lock_version: 1])

    if count == 1 do
      Audit.record_admin(%{
        actor_user_id: nil,
        event_type: "admin.platform_chatgpt.expired",
        metadata: %{"actor" => @system_actor, "kind" => row.kind, "account_id" => row.account_id}
      })

      :ok
    else
      :stale
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp locked_platform_row do
    Repo.one(from(a in Account, where: is_nil(a.user_id), lock: "FOR UPDATE"))
  end

  defp platform_row(preload \\ []) do
    from(a in Account, where: is_nil(a.user_id))
    |> Repo.one()
    |> case do
      nil -> nil
      row -> Repo.preload(row, preload)
    end
  end

  # No expiry known: the token stands until the server refuses it.
  defp fresh?(%Account{access_expires_at: nil}), do: true

  defp fresh?(%Account{access_expires_at: at}) do
    DateTime.diff(at, DateTime.utc_now(), :second) > platform_refresh_margin_seconds()
  end

  defp lapsed?(%Account{access_expires_at: %DateTime{} = at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp lapsed?(_row), do: false

  defp stale_for_keepalive?(%Account{last_refreshed_at: nil}), do: true

  defp stale_for_keepalive?(%Account{last_refreshed_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :day) >= platform_keepalive_days()
  end

  @doc "How far ahead of the access token's expiry a refresh happens (`PLATFORM_CHATGPT_REFRESH_MARGIN_SECONDS`, default 900)."
  @spec platform_refresh_margin_seconds() :: non_neg_integer()
  def platform_refresh_margin_seconds do
    case Application.get_env(:fountain, :platform_chatgpt_refresh_margin_seconds) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 900
    end
  end

  @doc "How long a grant may go unrefreshed before the keepalive renews it (`PLATFORM_CHATGPT_KEEPALIVE_DAYS`, default 6)."
  @spec platform_keepalive_days() :: non_neg_integer()
  def platform_keepalive_days do
    case Application.get_env(:fountain, :platform_chatgpt_keepalive_days) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 6
    end
  end

  # A workspace token is opaque or a JWT; either way the account id comes
  # from the token's claims when it has them, else from the admin.
  defp workspace_claims(token, given_account_id) do
    case Tokens.claims(token) do
      {:ok, claims} ->
        {:ok, claims["account_id"], Map.drop(claims, ["email"])}

      {:error, _} ->
        case String.trim(given_account_id || "") do
          "" -> {:error, :no_account_id}
          id -> {:ok, id, %{"account_id" => id}}
        end
    end
  end

  defp workspace_expiry(token, expires_on) do
    case {Tokens.expires_at(token), expires_on} do
      {%DateTime{} = at, _} -> at
      {nil, %Date{} = on} -> DateTime.new!(on, ~T[23:59:59], "Etc/UTC")
      {nil, _} -> nil
    end
  end

  # Long enough for any token seen so far, short enough that a pasted file
  # is refused rather than stored as a token.
  @max_token_bytes 8_192

  defp validate_token(""), do: {:error, :invalid_token}
  defp validate_token(t) when byte_size(t) > @max_token_bytes, do: {:error, :invalid_token}

  defp validate_token(t) do
    if Regex.match?(~r/[[:space:][:cntrl:]]/u, t), do: {:error, :invalid_token}, else: :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
