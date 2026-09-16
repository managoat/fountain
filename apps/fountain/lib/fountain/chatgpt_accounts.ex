defmodule Fountain.ChatGPTAccounts do
  @moduledoc """
  The deployment's ChatGPT grant for codex (ADR 0047): storage, refresh and
  the admin mutations.

  An admin signs the Fountain **server** in to ChatGPT once, by pasting the
  `auth.json` a laptop's `codex login` wrote or by the device-code flow
  (`Fountain.PlatformChatGPT.Device`). From then on Fountain owns the
  refresh token and is the only thing that ever uses it: the token rotates
  on every refresh, and the one place it lives is the one place that is
  refreshed. A sandbox never sees it. What a sandbox gets is `auth.json` in
  `chatgptAuthTokens` mode with a placeholder where the bearer goes
  (`Fountain.Conversations.CodexChatGPT`), and the broker substitutes the
  current access token on `chatgpt.com` (`Fountain.Broker`).

  Every function here is `platform_*` and queries `where: is_nil(a.user_id)`,
  the way `Fountain.PlatformInference` is deployment-scoped. None is
  `_unsafe_`: nothing reads across tenants, so there is no ownership for a
  call site to establish. The table keeps its `user_id` column and its
  owned-row uniqueness from ADR 0052, whose tenant-owner half was designed
  and partly built and then deleted (#2176 decision 1, #2188): no row has
  ever had an owner, and nothing here can read or write one. Token
  encryption still follows the row's ownership
  (`Fountain.ChatGPTAccounts.Cipher`), so an owned row could never decrypt
  under the platform key by accident.

    * `platform_access_token/0` -- the current access token, refreshed when
      it is within `platform_refresh_margin_seconds/0` of its expiry,
      through `Fountain.PlatformChatGPT.Refresher` so the deployment's many
      conversations queue on one round-trip rather than each making their
      own. The rotated refresh token is persisted *before* the new access
      token is handed out. A terminal refusal marks the row `revoked` with
      the server's reason code; a workspace token past its expiry marks it
      `expired`.
    * `platform_credential/1` -- `{:ok, token}` or `:none`, for
      `Fountain.PlatformInference.credential_for/2`, which takes the grant for a
      codex agent whose tenant has no OpenAI key of their own.
    * `platform_sandbox_auth/0` -- the account id and the synthesised
      `id_token` the sandbox file carries; never the real one.
    * `platform_connect_from_auth_json/2`,
      `platform_connect_from_tokens/3`,
      `platform_connect_workspace_token/3`, `platform_disconnect/1` -- the
      admin mutations, each leaving an `admin.platform_chatgpt.*` row on the
      privilege trail. Never a token, never a claim that is a secret.
    * `platform_keepalive/0` -- refresh a grant nobody has used for
      `platform_keepalive_days/0`, so it never idles past the auth
      server's window (`Fountain.Workers.PlatformChatGPTKeepalive`).
    * `platform_check_exhaustion/1`, `platform_confirm_exhausted/2` and
      `platform_exhausted_until/1` -- the account ran out of Codex usage
      (#2362). A codex turn on the grant that fails with `usageLimitExceeded`
      is only a hint, because a tenant's sandbox can forge it: the server
      asks the ChatGPT backend with the grant's token, and only a confirmed
      limit records the backend's reset time on the row.
      `Fountain.PlatformInference.credential_for/2` then skips the grant for
      new selections until it passes. Nothing is retried, and `status` stays
      `active`: the token is good, the account's quota is not.
    * `platform_status/0` -- what the admin page shows.

  The refresh margin must exceed the longest turn the deployment expects:
  a turn that outlives its access token fails at the proxy, because codex
  cannot refresh in this mode. The default is fifteen minutes.

  Platform refresh is coordinated across nodes with a per-grant PostgreSQL
  try-lock (`Fountain.ChatGPTAccounts.RefreshLock`). Only the holder
  retains a database checkout across the provider request; contenders
  release theirs between bounded retries.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.Audit
  alias Fountain.ChatGPTAccounts.{Cipher, RefreshLock}
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformChatGPT.{Account, OAuth, Refresher, Tokens, UsageLimit}
  alias Fountain.Repo

  @system_actor "system:platform_chatgpt"

  # ── reads ────────────────────────────────────────────────────────────────

  @doc "Whether the deployment holds a usable grant right now (no refresh is attempted)."
  @spec platform_active?() :: boolean()
  def platform_active?, do: match?(%Account{status: "active"}, platform_row())

  @doc """
  The grant as `Fountain.PlatformInference.credential_for/2` wants it:
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
  When the grant's account may serve Codex again, or nil: the recorded reset
  time while it is still in the future (#2362). A reset that has passed reads
  as nil without a write, so nothing has to clear it.
  """
  @spec platform_exhausted_until(DateTime.t()) :: DateTime.t() | nil
  def platform_exhausted_until(now \\ DateTime.utc_now()) do
    case platform_row() do
      %Account{} = row -> exhausted_until(row, now)
      nil -> nil
    end
  end

  @doc """
  How long after one usage check the grant may be checked again: five
  minutes. It bounds what a stream of hints can cost the shared account.
  """
  @spec platform_usage_check_cooldown_seconds() :: pos_integer()
  def platform_usage_check_cooldown_seconds, do: 300

  @doc """
  A codex turn bound to the platform grant failed with a usage-limit hint
  (`Fountain.PlatformChatGPT.UsageLimit.hint?/1`): check it in the
  background, off the caller's process. Returns at once; the check runs under
  `Fountain.TaskSupervisor`. Anything but the platform grant source is
  `:ignored` without starting anything.
  """
  @spec platform_check_exhaustion(Source.t() | nil) :: :started | :ignored
  def platform_check_exhaustion(source) do
    case grant_fence(source) do
      {:ok, _id, _generation} ->
        {:ok, _pid} =
          Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
            platform_confirm_exhausted(source)
          end)

        :started

      :error ->
        :ignored
    end
  end

  @doc """
  Confirm with OpenAI that the grant's account has spent its Codex usage, and
  record it only if so (#2362, ADR 0047 decision 6 as amended).

  A report from a sandbox is a hint and never writes anything by itself: the
  adapter runs where a tenant's `setup_script` can replace it, and the grant
  is shared by every tenant. The fact is what the ChatGPT backend says when
  the server asks with the grant's own token
  (`Fountain.PlatformChatGPT.UsageLimit.fetch/3`), and the reset time is the
  backend's.

  In order:

    1. `source` must be the platform `:codex_chatgpt_access_token` source a
       turn was bound to; anything else is `:ignored`.
    2. An exhaustion already recorded and not yet reset is `:already`, with
       no call.
    3. The check is claimed with one fenced `UPDATE` of
       `usage_checked_at` (grant id, generation, `active`, and no check in
       the last `platform_usage_check_cooldown_seconds/0`). That is both the
       in-flight bound and the cooldown, across nodes; a lost claim is
       `:throttled`. No lock or transaction is held past that statement.
    4. The HTTP call, outside any lock or transaction, as the refresher does.
    5. `{:limited, until}` writes `usage_exhausted_at` and
       `usage_exhausted_until`, fenced on the same grant id and generation,
       then records `admin.platform_chatgpt.exhausted` outside the write
       (account id, kind, `until`; never a token): `:recorded`. The row
       already saying exactly that is `:unchanged`.

  `:not_limited` and `{:error, _}` record nothing.
  """
  @spec platform_confirm_exhausted(Source.t() | nil, DateTime.t()) ::
          :recorded
          | :unchanged
          | :not_limited
          | :already
          | :throttled
          | :ignored
          | {:error, term()}
  def platform_confirm_exhausted(source, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    with {:ok, id, generation} <- grant_fence(source),
         %Account{} = row <- grant_row(id, generation),
         nil <- exhausted_until(row, now),
         :ok <- claim_usage_check(id, generation, now),
         {:ok, token} <- Cipher.decrypt_token(row, :access_token) do
      case UsageLimit.fetch(token, row.account_id, now) do
        {:limited, until} ->
          write_exhaustion(id, generation, until, now)

        :not_limited ->
          :not_limited

        {:error, reason} = error ->
          Logger.warning(
            "platform chatgpt: usage check was inconclusive; recording nothing: " <>
              inspect(reason)
          )

          error
      end
    else
      :error -> :ignored
      nil -> :ignored
      %DateTime{} -> :already
      :throttled -> :throttled
      {:error, _} = error -> error
    end
  end

  defp grant_fence(%Source{
         scope: :platform,
         kind: :codex_chatgpt_access_token,
         identity: "platform:chatgpt:" <> id,
         revision: generation
       })
       when is_binary(generation) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, generation} <- Ecto.UUID.cast(generation) do
      {:ok, id, generation}
    end
  end

  defp grant_fence(_source), do: :error

  defp grant_row(id, generation) do
    Repo.one(
      from a in Account,
        where:
          is_nil(a.user_id) and a.id == ^id and a.generation == ^generation and
            a.status == "active"
    )
  end

  defp claim_usage_check(id, generation, now) do
    since = DateTime.add(now, -platform_usage_check_cooldown_seconds(), :second)

    {count, _} =
      from(a in Account,
        where:
          is_nil(a.user_id) and a.id == ^id and a.generation == ^generation and
            a.status == "active" and
            (is_nil(a.usage_checked_at) or a.usage_checked_at <= ^since)
      )
      |> Repo.update_all(set: [usage_checked_at: now])

    if count == 1, do: :ok, else: :throttled
  end

  defp write_exhaustion(id, generation, until, now) do
    until = DateTime.truncate(until, :second)

    {count, rows} =
      Fountain.InferenceCredentials.with_platform_source_lock(fn ->
        from(a in Account,
          where:
            is_nil(a.user_id) and a.id == ^id and a.generation == ^generation and
              a.status == "active" and
              (is_nil(a.usage_exhausted_until) or a.usage_exhausted_until != ^until),
          select: %{account_id: a.account_id, kind: a.kind}
        )
        |> Repo.update_all(
          set: [usage_exhausted_at: now, usage_exhausted_until: until, updated_at: now]
        )
      end)

    case {count, rows} do
      {1, [row]} ->
        record_exhaustion(row, until)
        :recorded

      _ ->
        :unchanged
    end
  end

  defp record_exhaustion(row, until) do
    Audit.record_admin(%{
      actor_user_id: nil,
      event_type: "admin.platform_chatgpt.exhausted",
      metadata: %{
        "actor" => @system_actor,
        "kind" => row.kind,
        "account_id" => row.account_id,
        "until" => DateTime.to_iso8601(until),
        "confirmed_by" => "wham/usage"
      }
    })

    Logger.warning(
      "platform chatgpt: OpenAI confirms the account is at its Codex usage limit; new codex " <>
        "conversations skip the grant until #{DateTime.to_iso8601(until)} and use " <>
        "PLATFORM_OPENAI_API_KEY when one is set"
    )
  end

  @doc """
  The row for `/admin/inference`: `:not_connected`, or a map with `:status`
  (`"active"` | `"revoked"` | `"expired"`), `:kind`, `:account_email`,
  `:plan_type`, `:account_id`, `:access_expires_at`, `:last_refreshed_at`,
  `:revoked_reason`, `:exhausted_until` (nil unless the account's Codex
  usage is spent and has not reset, #2362), `:updated_at` and `:updated_by`.
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
          exhausted_until: exhausted_until(row, DateTime.utc_now()),
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
        Fountain.InferenceCredentials.lock_platform_source()

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
        Fountain.InferenceCredentials.lock_platform_source()

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
  Refresh the grant now if nobody has for `platform_keepalive_days/0`,
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

  defp finish_refresh(result), do: result

  defp do_refresh(current) do
    with {:ok, refresh} <- Cipher.decrypt_token(current, :refresh_token) do
      case OAuth.refresh(refresh) do
        {:ok, %{access_token: access} = fresh} ->
          # The rotated refresh token lands before the access token is
          # handed out: a crash between the two would otherwise leave the
          # row holding a refresh token the server has already retired.
          with {:ok, attrs} <- refresh_attrs(current, fresh) do
            swap_in(current, attrs, access)
          end

        {:error, {:terminal, code}} ->
          case mark_revoked(current, code) do
            :ok -> {:revoked, current.account_id, code}
            :stale -> current_result(current)
          end

        {:error, reason} ->
          Logger.warning(
            "platform chatgpt: refresh failed, keeping the current token: " <> inspect(reason)
          )

          {:error, reason}
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
      Fountain.InferenceCredentials.with_platform_source_lock(fn ->
        current_query(current) |> Repo.update_all(set: sets, inc: [lock_version: 1])
      end)

    case n do
      1 -> {:ok, access}
      0 -> current_result(current)
    end
  end

  defp current_query(row) do
    from(a in Account,
      where:
        is_nil(a.user_id) and a.id == ^row.id and a.generation == ^row.generation and
          a.lock_version == ^row.lock_version and a.status == "active"
    )
  end

  defp current_result(previous) do
    case platform_row() do
      nil ->
        {:error, :not_connected}

      %Account{id: id, generation: generation} = current
      when id == previous.id and generation == previous.generation ->
        case current.status do
          "active" -> Cipher.decrypt_token(current, :access_token)
          "revoked" -> {:error, :revoked}
          "expired" -> {:error, :expired}
          other -> {:error, {:unknown_status, other}}
        end

      %Account{} ->
        {:error, :stale_grant}
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
      Fountain.InferenceCredentials.with_platform_source_lock(fn ->
        current_query(row)
        |> Repo.update_all(
          set: [status: "revoked", revoked_reason: code, updated_at: now()],
          inc: [lock_version: 1]
        )
      end)

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
      Fountain.InferenceCredentials.with_platform_source_lock(fn ->
        current_query(row)
        |> Repo.update_all(set: [status: "expired", updated_at: now()], inc: [lock_version: 1])
      end)

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

  defp exhausted_until(%Account{usage_exhausted_until: %DateTime{} = until}, now) do
    if DateTime.compare(until, now) == :gt, do: until, else: nil
  end

  defp exhausted_until(_row, _now), do: nil

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

  @doc """
  How far ahead of the access token's expiry a refresh happens: fifteen
  minutes. It must exceed the longest turn the deployment expects, because
  codex cannot refresh in this mode and a turn that outlives the token fails
  at the proxy. It used to be `PLATFORM_CHATGPT_REFRESH_MARGIN_SECONDS`;
  nobody set it.
  """
  @spec platform_refresh_margin_seconds() :: non_neg_integer()
  def platform_refresh_margin_seconds, do: 900

  @doc """
  How long a grant may go unrefreshed before the keepalive renews it: six
  days, inside the auth server's eight-day window. It used to be
  `PLATFORM_CHATGPT_KEEPALIVE_DAYS`; nobody set it.
  """
  @spec platform_keepalive_days() :: non_neg_integer()
  def platform_keepalive_days, do: 6

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
