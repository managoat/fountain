defmodule Fountain.ChatGPTAccounts do
  @moduledoc """
  ChatGPT grant storage for both owners a grant can have: the deployment
  (ADR 0047) and a user, who may hold several (ADRs 0052, 0060).

  Token encryption follows the row's ownership, which never changes: the
  null-owner row keeps the deployed platform format, an owned row uses its
  owner's DEK (`Fountain.ChatGPTAccounts.Cipher`), so no blob decrypts under
  the wrong owner's key or in the wrong column.

  ## The two prefixes

  `platform_*` is the deployment's grant: every one of those functions
  queries `where: is_nil(a.user_id)` and cannot reach a user's row, the way
  `Fountain.PlatformInference` is deployment-scoped. `*_for_user` takes a
  grant id **and** its owner, and the first query is scoped by both; a `nil`
  owner raises rather than meaning "the platform". Neither is `_unsafe_`:
  nothing here reads across tenants, so there is no ownership for a call
  site to establish.

  ## User grants

  A user may hold several, each a named row, up to `grant_ceiling/0` (ADR
  0060 decision 1). Every function below is scoped by the owner, and by the
  grant id wherever it addresses one; none falls through to another of the
  user's grants or to the platform row.

    * `list_for_user/1`, `get_for_user/2` -- metadata only (`t:grant_view/0`):
      no decrypt, no refresh, no provider I/O, no ciphertext fetched. Safe
      under the source lock. The view's `:grant_id` and `:generation` are the
      pin the credential read takes.
    * `connect_for_user/4`, `reconnect_for_user/4`, `rename_for_user/4`,
      `disconnect_for_user/3`, `remove_for_user/3` -- the writes, each one
      transaction under the owner's source lock and each leaving a
      `chatgpt_grant.*` tenant event after it commits: the grant's id and
      name, never a token, an email or the provider's account id. A
      disconnect keeps the row as a tombstone with no token in it, so what
      named the grant fails by name rather than resolving to something else;
      a removal deletes a tombstone.
    * `credential_for_user/4`, `refresh_for_user/3` -- read and renew one
      grant, pinned by id, owner and generation. Near-expiry reads renew
      through bounded per-grant workers
      (`Fountain.ChatGPTAccounts.RefreshCoordinator`) and the PostgreSQL
      refresh lock, using only the owner's encryption key. Callers re-read
      their pinned grant after renewal; the coordinator holds no tokens.

  **Nothing in production calls any of these yet.** There is no route, no
  page and no job; selection by a credential set, the broker path, the
  account surface and the keepalive schedule are stages 2 to 5 of ADR 0060.
  Until the keepalive exists an idle user grant would lapse at the auth
  server's window, which is one reason linking is not reachable.

  ### The source lock, and one rule for whoever selects a grant

  A write to a user's grant takes that user's source lock
  (`InferenceCredentials.lock_tenant_source/1`) and never the platform's, in
  Elixir and in the table's trigger alike, so one user's refresh cannot park
  another user's turn admission (ADR 0060 decision 5). The order everywhere
  is platform key, then tenant key, then a row lock; the refresh try-lock is
  never waited on.

  **Any writer of an owned grant row takes the owner's source key in Elixir
  before it locks the row.** The trigger is not enough on its own: it is
  `BEFORE ROW`, and PostgreSQL locks the target row before it fires one, so
  an `update_all`, a `FOR UPDATE` or a delete that leaves the key to the
  trigger takes row then key. Every function here takes key then row, and
  the two orders deadlock against each other on one row. `user_write/2` and
  `with_grant_source_lock/2` are the two ways in; use one.

  **Never call `credential_for_user/4` with `refresh: true` (the default),
  or `refresh_for_user/3`, while holding `InferenceCredentials.lock_source/1`
  for that user.** The caller would hold the tenant key and wait on the
  coordinator; the worker's fenced write would wait on the tenant key with
  the rotated refresh token in hand, until `RefreshLock`'s transaction
  timeout rolls it back and the grant needs a reconnect. Inside the lock
  pass `refresh: false` and answer from the row alone, as the platform path
  does, and renew outside it.

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

  alias Fountain.Accounts.User
  alias Fountain.Audit
  alias Fountain.ChatGPTAccounts.{Cipher, Grant, RefreshCoordinator, RefreshLock}
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformChatGPT.{Account, OAuth, Refresher, Tokens, UsageLimit}
  alias Fountain.Repo

  @system_actor "system:platform_chatgpt"
  @user_system_actor "system:chatgpt_accounts"

  # ── a user's grants ──────────────────────────────────────────────────────

  @typedoc """
  One grant as its owner may see it: metadata only, never a token or a
  ciphertext. `:grant_id` and `:generation` are the pin
  `credential_for_user/4` takes, so the two halves compose: a caller reads
  the grant here and asks for a bearer from that exact version. Neither is a
  secret; the generation is a lifecycle counter, not key material.
  `:refreshable` says whether a refresh token is stored, without loading it.
  `:exhausted_until` is the recorded usage reset while it is still in the
  future, else nil; nothing records one for a user's grant yet.
  """
  @type grant_view :: %{
          grant_id: Ecto.UUID.t(),
          name: String.t(),
          generation: Ecto.UUID.t(),
          lock_version: pos_integer(),
          status: String.t(),
          kind: String.t(),
          refreshable: boolean(),
          account_id: String.t() | nil,
          account_email: String.t() | nil,
          plan_type: String.t() | nil,
          access_expires_at: DateTime.t() | nil,
          last_refreshed_at: DateTime.t() | nil,
          revoked_reason: String.t() | nil,
          exhausted_until: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Every grant the user holds, by name: connected, revoked and disconnected
  alike, `[]` when there is none. One query, scoped by the owner; decrypts
  nothing, refreshes nothing and contacts nobody. It does not ask whether
  the owner may still link or use a grant, so it keeps answering when they
  may not.
  """
  @spec list_for_user(String.t()) :: [grant_view()]
  def list_for_user(user_id) when is_binary(user_id) do
    now = DateTime.utc_now()

    case Ecto.UUID.cast(user_id) do
      {:ok, owner} ->
        from(a in Account, where: a.user_id == ^owner, order_by: [asc: a.name, asc: a.id])
        |> select_view()
        |> Repo.all()
        |> Enum.map(&view(&1, now))

      :error ->
        []
    end
  end

  @doc """
  One grant, by its id and its owner. Another user's grant, the platform
  row and an id that is not one are all `{:error, :not_found}`. The same
  no-decrypt, no-I/O read as `list_for_user/1`, so it is safe under the
  source lock.
  """
  @spec get_for_user(Ecto.UUID.t(), String.t()) :: {:ok, grant_view()} | {:error, :not_found}
  def get_for_user(grant_id, user_id) when is_binary(grant_id) and is_binary(user_id) do
    with {:ok, query} <- owned_query(grant_id, user_id),
         %{} = row <- query |> select_view() |> Repo.one() do
      {:ok, view(row, DateTime.utc_now())}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  How many grants one account may hold: `config :fountain,
  :chatgpt_grant_ceiling`, five unless set. It stops a runaway client; it
  does not price anything. Lowering it below what an account already holds
  refuses new links only.
  """
  @spec grant_ceiling() :: pos_integer()
  def grant_ceiling, do: Application.get_env(:fountain, :chatgpt_grant_ceiling, 5)

  @doc """
  Link one more subscription to `user_id` under `name`, from a token set the
  caller obtained for them. **Nothing in production calls this yet.**

  Refused, with nothing written and nothing audited:

    * `:no_refresh_token`, `:invalid_id_token` -- a user's grant is always a
      refreshable ChatGPT sign-in whose `id_token` names an account.
    * `:ineligible_owner` -- not a verified, claimed, unsuspended account.
    * `:tenant_key_unavailable` -- the owner's encryption key would not load.
    * `{:account_already_linked, %{grant_id: _, name: _}}` -- this user
      already holds that upstream account. A second row would be a second
      refresh chain over one subscription; the answer names the grant to
      reconnect instead, which is also how a disconnected one comes back.
    * `{:grant_limit_reached, %{count: _, limit: _}}` -- at
      `grant_ceiling/0`. Every row counts, a disconnected one included,
      until `remove_for_user/3` deletes it.
    * a changeset -- the name is blank, too long, or already names one of
      this user's grants.

  The count and the insert cannot interleave with another link for the same
  user: both run under that user's source lock, which the table's trigger
  also takes for any other writer of the user's rows.

  `opts`: `:actor` (default `"self"`), `:request_ip`, and `:method` (default
  `"device_code"`), all for the `chatgpt_grant.connected` event.
  """
  @spec connect_for_user(String.t(), String.t(), OAuth.tokens(), keyword()) ::
          {:ok, grant_view()} | {:error, term()}
  def connect_for_user(user_id, name, %{access_token: access} = tokens, opts \\ [])
      when is_binary(user_id) and is_binary(name) and is_binary(access) do
    # The row's id comes first: the tokens are encrypted to it (`Cipher`).
    id = Ecto.UUID.generate()

    with {:ok, claims} <- user_claims(tokens),
         {:ok, account} <-
           user_write(user_id, :ineligible_owner, fn ->
             with :ok <- eligible_owner(user_id),
                  :ok <- account_unlinked(user_id, claims["account_id"], id),
                  :ok <- under_ceiling(user_id),
                  {:ok, attrs} <- user_attrs(user_id, id, tokens, claims) do
               %Account{id: id, user_id: user_id}
               |> Account.user_connect_changeset(Map.put(attrs, :name, name))
               |> Repo.insert()
             end
           end) do
      audit_grant(account, "chatgpt_grant.connected", opts, connected_metadata(account, opts))
      {:ok, view(account, DateTime.utc_now())}
    end
  end

  @doc """
  Replace one grant's credential with a fresh sign-in, keeping its id and
  its name, so whatever names the grant keeps naming it. `generation`
  changes and `lock_version` advances, which fences every refresh begun
  against the old credential; until this commits the old credential keeps
  working. A revoked or disconnected grant comes back this way, and it does
  not count against the ceiling.

  The sign-in may be for a different upstream account than the grant held
  (as for the platform grant): its recorded usage exhaustion is then
  cleared. It is refused as `{:account_already_linked, _}` only when another
  of this user's grants holds that account. Between reconnects the account
  is pinned: a refresh that answers as another one is refused.

  A sign-in takes minutes, and two may be open on one grant. Pass
  `:expected_generation`, the generation the attempt began against, and a
  completion that finds another one is `{:error, :stale_grant}` with nothing
  written: the later sign-in to finish does not replace the credential the
  earlier one already installed. It is compared under the row lock. Without
  the option the reconnect is unconditional.

  Refusals are `connect_for_user/4`'s, less the ceiling and the name, plus
  `:not_found` for a grant that is not this user's and `:stale_grant`. The
  event is `chatgpt_grant.connected` with `"reconnect" => true`.
  """
  @spec reconnect_for_user(Ecto.UUID.t(), String.t(), OAuth.tokens(), keyword()) ::
          {:ok, grant_view()} | {:error, term()}
  def reconnect_for_user(grant_id, user_id, %{access_token: access} = tokens, opts \\ [])
      when is_binary(grant_id) and is_binary(user_id) and is_binary(access) do
    with {:ok, claims} <- user_claims(tokens),
         {:ok, account} <-
           user_write(user_id, fn ->
             with :ok <- eligible_owner(user_id),
                  {:ok, current} <- locked_user_grant(grant_id, user_id),
                  :ok <- expected_generation(current, opts[:expected_generation]),
                  :ok <- account_unlinked(user_id, claims["account_id"], current.id),
                  {:ok, attrs} <- user_attrs(user_id, current.id, tokens, claims) do
               current |> Account.user_reconnect_changeset(attrs) |> Repo.update()
             end
           end) do
      metadata = account |> connected_metadata(opts) |> Map.put("reconnect", true)
      audit_grant(account, "chatgpt_grant.connected", opts, metadata)
      {:ok, view(account, DateTime.utc_now())}
    end
  end

  @doc """
  Give one grant a new name. A label, not a credential: `generation` and
  `lock_version` are left alone, so a pin taken before the rename still
  reads and an in-flight refresh still lands. A name that does not change
  writes and records nothing.

  It is a write all the same, so it asks what a link asks of the owner:
  `:ineligible_owner` for an account that is suspended, unverified or a
  principal. Seeing, disconnecting and removing a grant stay open to them.
  """
  @spec rename_for_user(Ecto.UUID.t(), String.t(), String.t(), keyword()) ::
          {:ok, grant_view()} | {:error, :not_found | :ineligible_owner | Ecto.Changeset.t()}
  def rename_for_user(grant_id, user_id, name, opts \\ [])
      when is_binary(grant_id) and is_binary(user_id) and is_binary(name) do
    result =
      user_write(user_id, fn ->
        with :ok <- eligible_owner(user_id),
             {:ok, account} <- locked_user_grant(grant_id, user_id),
             {:ok, renamed} <-
               account |> Account.rename_changeset(%{name: name}) |> Repo.update() do
          {:ok, {account.name, renamed}}
        end
      end)

    case result do
      {:ok, {previous, %Account{name: previous} = account}} ->
        {:ok, view(account, DateTime.utc_now())}

      {:ok, {previous, account}} ->
        audit_grant(account, "chatgpt_grant.renamed", opts, %{
          "name" => account.name,
          "previous_name" => previous
        })

        {:ok, view(account, DateTime.utc_now())}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Disconnect one grant: forget its tokens and keep the row.

  The row becomes a tombstone (`status: "disconnected"`): both tokens and
  the stored claims are dropped, `generation` and `lock_version` advance so
  a refresh already in flight writes nothing and every pin goes stale, and
  the id, the name and the upstream account stay. Whatever named the grant
  still names it and fails by name instead of silently resolving to
  something else (ADR 0060 decision 4). The same subscription comes back
  through `reconnect_for_user/4`; the row still counts against the ceiling
  until `remove_for_user/3` deletes it.

  `:ok` for a grant already disconnected, with no second event. The
  platform grant is not like this: `platform_disconnect/1` deletes its row.

  A changeset is the database refusing the tombstone
  (`chatgpt_grant_tokens_follow_status`). The changeset this writes cannot
  produce one; it is in the type so that a caller matches it rather than
  meeting it as a crash.
  """
  @spec disconnect_for_user(Ecto.UUID.t(), String.t(), keyword()) ::
          :ok | {:error, :not_found | Ecto.Changeset.t()}
  def disconnect_for_user(grant_id, user_id, opts \\ [])
      when is_binary(grant_id) and is_binary(user_id) do
    result =
      user_write(user_id, fn ->
        case locked_user_grant(grant_id, user_id) do
          {:ok, %Account{status: "disconnected"}} ->
            {:ok, :already}

          {:ok, account} ->
            with {:ok, tombstone} <- account |> Account.disconnect_changeset() |> Repo.update() do
              {:ok, {account.generation, tombstone}}
            end

          {:error, _} = error ->
            error
        end
      end)

    case result do
      {:ok, :already} ->
        :ok

      # The generation on the event is the one that was retired.
      {:ok, {retired, account}} ->
        audit_grant(account, "chatgpt_grant.disconnected", opts, %{
          "name" => account.name,
          "generation" => retired
        })

        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Delete a disconnected grant's row, which frees its slot under the ceiling
  and lets its upstream account be linked afresh. A grant that still holds
  a credential is `{:error, :still_connected}`: disconnect it first, so
  removal never drops a live refresh token as a side effect. A changeset is
  the database refusing the delete; nothing declares a constraint that
  would produce one yet.
  """
  @spec remove_for_user(Ecto.UUID.t(), String.t(), keyword()) ::
          :ok | {:error, :not_found | :still_connected | Ecto.Changeset.t()}
  def remove_for_user(grant_id, user_id, opts \\ [])
      when is_binary(grant_id) and is_binary(user_id) do
    result =
      user_write(user_id, fn ->
        case locked_user_grant(grant_id, user_id) do
          # ADR 0060 stage 2 adds the refusal for a grant a credential set names.
          {:ok, %Account{status: "disconnected"} = account} -> Repo.delete(account)
          {:ok, %Account{}} -> {:error, :still_connected}
          {:error, _} = error -> error
        end
      end)

    with {:ok, account} <- result do
      audit_grant(account, "chatgpt_grant.removed", opts, %{"name" => account.name})
      :ok
    end
  end

  # Every write to a user's grants: one transaction under that user's source
  # lock, taken before any row lock, rolled back on a refusal. The platform
  # key is never taken here (`InferenceCredentials.lock_tenant_source/1`).
  #
  # An owner id that is not a UUID owns nothing, so it is refused with
  # `malformed` before the lock or any query is asked to cast it.
  defp user_write(user_id, malformed \\ :not_found, fun)
       when is_binary(user_id) and is_function(fun, 0) do
    case Ecto.UUID.cast(user_id) do
      {:ok, _} ->
        Repo.transaction(fn ->
          Fountain.InferenceCredentials.lock_tenant_source(user_id)

          case fun.() do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      :error ->
        {:error, malformed}
    end
  end

  # After the transaction has returned, never inside it. A tenant event: the
  # grant's id and name and the caller's attribution. No account email, no
  # provider account id, no claim and nothing the provider said, because a
  # tenant event's metadata travels further than an admin event's.
  defp audit_grant(%Account{} = account, action, opts, metadata) do
    Audit.record(%{
      user_id: account.user_id,
      action: action,
      resource_type: "chatgpt_grant",
      resource_id: account.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: metadata
    })
  end

  defp connected_metadata(account, opts) do
    %{
      "name" => account.name,
      "generation" => account.generation,
      "method" => Keyword.get(opts, :method, "device_code"),
      "plan" => account.plan_type
    }
  end

  # Every writer of a user's rows holds that user's source key, the trigger
  # included, so this answers before the `(user_id, account_id)` index can:
  # the index is the backstop, and its refusal is a changeset error.
  defp account_unlinked(user_id, account_id, except_id) do
    holder =
      from(a in Account,
        where: a.user_id == ^user_id and a.account_id == ^account_id,
        select: %{grant_id: a.id, name: a.name}
      )
      |> Repo.all()
      |> Enum.reject(&(&1.grant_id == except_id))

    case holder do
      [] -> :ok
      [linked | _] -> {:error, {:account_already_linked, linked}}
    end
  end

  defp expected_generation(_current, nil), do: :ok
  defp expected_generation(%Account{generation: generation}, generation), do: :ok
  defp expected_generation(%Account{}, _other), do: {:error, :stale_grant}

  defp under_ceiling(user_id) do
    count = Repo.aggregate(from(a in Account, where: a.user_id == ^user_id), :count)
    limit = grant_ceiling()

    if count < limit,
      do: :ok,
      else: {:error, {:grant_limit_reached, %{count: count, limit: limit}}}
  end

  defp eligible_owner(user_id) do
    eligible =
      from(u in User, as: :owner, where: u.id == ^user_id, where: ^eligible_owner_filter())

    if Repo.exists?(eligible), do: :ok, else: {:error, :ineligible_owner}
  end

  defp locked_user_grant(grant_id, user_id) do
    with {:ok, query} <- owned_query(grant_id, user_id),
         %Account{} = account <- Repo.one(from(a in query, lock: "FOR UPDATE")) do
      {:ok, account}
    else
      _ -> {:error, :not_found}
    end
  end

  # Both halves of the scope, and no join: the metadata reads, a disconnect
  # and a removal stay open to an owner who may no longer link or use a
  # grant. The writes that are not take `eligible_owner/1` first.
  defp owned_query(grant_id, user_id) do
    with {:ok, id} <- Ecto.UUID.cast(grant_id),
         {:ok, owner} <- Ecto.UUID.cast(user_id) do
      {:ok, from(a in Account, where: a.user_id == ^owner and a.id == ^id)}
    end
  end

  defp user_claims(tokens) do
    case Map.get(tokens, :refresh_token) do
      refresh when is_binary(refresh) and refresh != "" ->
        Tokens.claims(Map.get(tokens, :id_token) || "")

      _ ->
        {:error, :no_refresh_token}
    end
  end

  # No `updated_by_user_id`: the owner is `user_id`, the actor is on the audit
  # event, and `Account`'s owned changesets refuse the column anyway.
  defp user_attrs(user_id, grant_id, %{access_token: access} = tokens, claims) do
    case Cipher.encrypt_user_tokens(user_id, grant_id, %{
           access_token: access,
           refresh_token: tokens.refresh_token
         }) do
      {:ok, encrypted} ->
        {:ok,
         Map.merge(encrypted, %{
           kind: "chatgpt",
           id_claims: Map.drop(claims, ["email"]),
           account_id: claims["account_id"],
           account_email: claims["email"],
           plan_type: claims["plan_type"],
           access_expires_at: Tokens.expires_at(access),
           last_refreshed_at: now()
         })}

      # Not the key's own reason: `:not_found` here would read as "no such grant".
      {:error, _} ->
        {:error, :tenant_key_unavailable}
    end
  end

  # The columns a view is made of, and whether a refresh token is there
  # without fetching it: no ciphertext leaves the database for a metadata read.
  defp select_view(query) do
    from(a in query,
      select: %{
        id: a.id,
        name: a.name,
        generation: a.generation,
        lock_version: a.lock_version,
        status: a.status,
        kind: a.kind,
        refreshable: not is_nil(a.refresh_token_ciphertext),
        account_id: a.account_id,
        account_email: a.account_email,
        plan_type: a.plan_type,
        access_expires_at: a.access_expires_at,
        last_refreshed_at: a.last_refreshed_at,
        revoked_reason: a.revoked_reason,
        usage_exhausted_until: a.usage_exhausted_until,
        inserted_at: a.inserted_at,
        updated_at: a.updated_at
      }
    )
  end

  defp view(%Account{} = account, now) do
    account
    |> Map.from_struct()
    |> Map.put(:refreshable, is_binary(account.refresh_token_ciphertext))
    |> view(now)
  end

  defp view(%{} = row, now) do
    %{
      grant_id: row.id,
      name: row.name,
      generation: row.generation,
      lock_version: row.lock_version,
      status: row.status,
      kind: row.kind,
      refreshable: row.refreshable,
      account_id: row.account_id,
      account_email: row.account_email,
      plan_type: row.plan_type,
      access_expires_at: row.access_expires_at,
      last_refreshed_at: row.last_refreshed_at,
      revoked_reason: safe_reason(row.revoked_reason),
      exhausted_until: exhausted_until(row, now),
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end

  # Only a code `OAuth` itself names can reach a tenant: a reason that is not
  # one of those did not come from the paths that write this column, and the
  # tenant page is the wrong place to find out what it was. Allowlisted
  # against `OAuth.terminal_codes/0` rather than a second copy of the list,
  # which would drift from it.
  defp safe_reason(nil), do: nil

  defp safe_reason(reason) do
    if reason in OAuth.terminal_codes(), do: reason, else: "provider_error"
  end

  @doc """
  Internal server credential read for an explicitly selected user grant.

  The owner and the grant id scope the first query. The returned bearer and
  provider metadata come from one row version. A near-expiry grant renews
  through the bounded user coordinator, then the caller reads that same
  generation again. With `refresh: false`, near-expiry grants return
  `:refresh_required`. Neither path falls back to a different grant, to the
  platform grant or to paid inference. Only verified, claimed, non-suspended
  owners can obtain or renew a credential. A grant or owner id that is not a
  UUID is `:not_connected`, like one that names nothing.
  """
  @spec credential_for_user(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), keyword()) ::
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
  @spec refresh_for_user(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def refresh_for_user(grant_id, user_id, generation)
      when is_binary(grant_id) and is_binary(user_id) and is_binary(generation) do
    with {:ok, account} <- pinned_user_grant(grant_id, user_id, generation),
         :ok <- user_account_state(account) do
      # The row's ids, not the caller's spelling of them: they key the
      # coordinator's job and, in the worker, the refresh lock.
      RefreshCoordinator.run(account.id, account.user_id, account.generation)
    end
  end

  @doc false
  def refresh_serialized_for_user(grant_id, user_id, generation)
      when is_binary(grant_id) and is_binary(user_id) and is_binary(generation) do
    with {:ok, observed} <- pinned_user_grant(grant_id, user_id, generation),
         :ok <- user_account_state(observed) do
      observed.id
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
  defp user_account_state(%Account{status: "disconnected"}), do: {:error, :disconnected}

  defp user_account_state(%Account{
         status: "active",
         kind: "chatgpt",
         account_id: id,
         refresh_token_ciphertext: cipher
       })
       when is_binary(id) and id != "" and is_binary(cipher) and byte_size(cipher) > 0,
       do: :ok

  defp user_account_state(_), do: {:error, :invalid_grant}

  # An id that is not a UUID names no grant and no owner. It is refused
  # here, where every credential read and renewal starts, rather than raised
  # by the query that would have had to cast it.
  defp pinned_user_grant(grant_id, user_id, generation) do
    with {:ok, grant_id} <- Ecto.UUID.cast(grant_id),
         {:ok, user_id} <- Ecto.UUID.cast(user_id),
         %Account{} = account <- Repo.one(user_grant_query(grant_id, user_id)) do
      if account.generation == generation, do: {:ok, account}, else: {:error, :stale_grant}
    else
      _ -> {:error, :not_connected}
    end
  end

  defp user_grant_query(grant_id, user_id) when is_binary(user_id) do
    Account
    |> from(where: [user_id: ^user_id, id: ^grant_id])
    |> with_eligible_owner()
  end

  defp with_eligible_owner(query) do
    from(a in query,
      join: u in User,
      as: :owner,
      on: u.id == a.user_id,
      where: ^eligible_owner_filter()
    )
  end

  # Who may link, read or renew a credential: a verified, claimed,
  # unsuspended account. One predicate for the join and for the link door.
  defp eligible_owner_filter do
    Ecto.Query.dynamic(
      [owner: u],
      not u.principal and not is_nil(u.email_verified_at) and is_nil(u.suspended_at)
    )
  end

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

  # After `RefreshLock.run/2` has returned, so outside its transaction. A
  # tenant event: the grant's id and name, never the provider's account id or
  # response.
  defp finish_refresh({:user_revoked, grant, code}) do
    Audit.record(%{
      user_id: grant.user_id,
      actor: @user_system_actor,
      action: "chatgpt_grant.reconnect_required",
      resource_type: "chatgpt_grant",
      resource_id: grant.grant_id,
      metadata: %{"name" => grant.name, "generation" => grant.generation, "reason" => code}
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
            {:error, _} = unwritten -> unwritten
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

    case with_grant_source_lock(current, fn ->
           current_query(current) |> Repo.update_all(set: sets, inc: [lock_version: 1])
         end) do
      {1, _} -> refreshed_result(current, access)
      {0, _} -> current_result(current)
      {:error, _} when is_binary(current.user_id) -> unwritten(current, "renewed token set")
    end
  end

  # The nested transaction answered `{:error, _}` instead of a count. For a
  # renewal that is after the provider rotated the refresh token, so the log
  # says what was lost, by id, and the caller gets an error it can match.
  # A user's grant only: the platform's writes are as they were.
  defp unwritten(%Account{id: id, user_id: user_id}, what) do
    Logger.error(
      "chatgpt grant #{id} of #{user_id}: the #{what} was not stored; " <>
        "if this repeats the owner must reconnect the account"
    )

    {:error, :refresh_unavailable}
  end

  # The user base joins the eligible owner, so a late refresh for an owner
  # suspended in the meantime writes nothing.
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
          "disconnected" -> {:error, :disconnected}
          other -> {:error, {:unknown_status, other}}
        end

      %Account{} ->
        {:error, :stale_grant}
    end
  end

  # A user refresh never returns a bearer: its caller re-reads the pinned
  # grant, and the coordinator between them holds no token.
  defp current_active_result(%Account{user_id: nil} = account),
    do: Cipher.decrypt_token(account, :access_token)

  defp current_active_result(account), do: user_account_state(account)

  defp refreshed_result(%Account{user_id: nil}, access), do: {:ok, access}
  defp refreshed_result(%Account{}, _access), do: :ok

  defp revoked_result(%Account{user_id: nil} = account, code),
    do: {:revoked, account.account_id, code}

  defp revoked_result(account, code) do
    {:user_revoked,
     %{
       user_id: account.user_id,
       grant_id: account.id,
       name: account.name,
       generation: account.generation
     }, code}
  end

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

  # A refresh that comes back as somebody else is not this grant's: between
  # reconnects the upstream account is pinned.
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
    case with_grant_source_lock(row, fn ->
           current_query(row)
           |> Repo.update_all(
             set: [status: "revoked", revoked_reason: code, updated_at: now()],
             inc: [lock_version: 1]
           )
         end) do
      {1, _} -> :ok
      {:error, _} when is_binary(row.user_id) -> unwritten(row, "revocation")
      _ -> :stale
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
  #
  # Platform only, which the head says: only a static workspace token expires
  # this way, a user's grant is never one, and an owned row must not be able
  # to produce an `admin.*` event.
  defp mark_expired(%Account{user_id: nil} = row) do
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

  # The source lock a fenced write takes follows the row's owner (ADR 0060
  # decision 5), as `fountain_lock_inference_source()` does for the same row:
  # the deployment's grant takes the platform key, a user's takes that user's
  # and never the platform's, so one user's refresh cannot park another
  # user's turn admission.
  defp with_grant_source_lock(%Account{user_id: nil}, fun),
    do: Fountain.InferenceCredentials.with_platform_source_lock(fun)

  defp with_grant_source_lock(%Account{user_id: user_id}, fun) when is_binary(user_id),
    do: Fountain.InferenceCredentials.with_tenant_source_lock(user_id, fun)

  defp exhausted_until(%{usage_exhausted_until: %DateTime{} = until}, now) do
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
