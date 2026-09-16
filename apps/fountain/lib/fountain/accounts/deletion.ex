defmodule Fountain.Accounts.Deletion do
  @moduledoc """
  Closing an account and removing the tenant's data.

  The decisions here — ordering, crypto-shred scope and its backup boundary,
  Stripe customer retention, no soft-delete — are recorded in ADR 0009
  (`decisions/0009-account-deletion-and-export.md`). Change them there first.

  There was no deletion path at all — no self-serve, no admin, no context
  function — so a departing user's only options were to stop using the service
  while continuing to be billed, or to ask an operator to edit the database.

  ## Order matters

  1. **Destroy the tenant's sprites.** Before the row deletion, because the
     cascade takes `conversations` with it, and after that nothing links a
     sandbox to the user who was paying for it. Failures here are logged rather
     than fatal: `SandboxReaper` reconciles anything missed on its next run,
     which is exactly the case it exists for. An enclosing transaction is the
     one thing that refuses, and it refuses before any teardown starts
     (`delete_user/2`); a single machine's fence being refused mid-run is
     logged and the run carries on.

  2. **Record the audit event.** Before the delete, and carrying the email and
     user id in `metadata` — `audit_events.user_id` is `SET NULL` on delete, so
     an event that relies on the column alone would survive as an anonymous row
     saying an account was deleted, without saying which.

  3. **Delete the user.** Postgres cascades take agents, api_keys,
     conversations (and their turns and log events), environments, vaults,
     oauth_identities, inference_credentials and user_data_keys.
     `usage_events`, `audit_events` and `sandboxes` nilify instead, keeping
     operational and financial history that no longer names anybody.

  ## Crypto-shred

  Deleting `user_data_keys` destroys the wrapped per-tenant DEK, and every
  environment and vault secret is encrypted with it. So even ciphertext that
  outlives the cascade — a row missed by a future schema change, a stray copy —
  becomes undecryptable rather than merely unreferenced.

  That property is real but bounded: it does not reach **database backups**
  taken before the deletion, which contain both the ciphertext and the wrapped
  key. Backup expiry is what erases those, and it runs on its own retention
  schedule.

  ## Stripe

  Nothing is cancelled, because nothing recurs (ADR 0031): a prepaid balance
  goes with the row and its ledger. The Stripe customer is not deleted.
  Charges and refunds are financial records a business is required to
  retain, and Stripe is the system of record for them.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Accounts.User
  alias Fountain.Conversations.{ConversationServer, Lifecycle, Sandbox, Termination}
  alias Fountain.{Audit, Conversations, Repo}

  # Includes `suspended`: parked sprites are excluded from the concurrency
  # quota but still exist at sprites.dev, and deletion nilifies user_id — a
  # sprite missed here is unfindable afterward, a permanent leak.
  @non_terminal ~w(pending starting ready suspended)

  @doc """
  Delete `user` and everything belonging to them.

  Options:

    * `:actor` — who performed it, for the audit trail. Defaults to `"self"`;
      an admin path should pass something identifying.
    * `:request_ip` — passed through to the audit event.

  Returns `{:ok, summary}` or an error. An enclosing database transaction is
  refused before any teardown: actor and provider calls must run outside its
  locks. There is no subscription to cancel first (ADR 0031), and the Stripe
  customer stays for the refund trail.

  A claimable principal this account owns (ADR 0044) goes with it. The
  ownership row cascades either way, so the alternative is not "keep it" but
  "leave a tenant with resources, no owner, no credential that reaches it and
  no sweep that would ever find it" — a permanent leak of exactly the kind
  `@non_terminal` above exists to prevent.
  """
  @spec delete_user(User.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete_user(%User{} = user, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      do_delete_user(user, opts)
    end
  end

  defp do_delete_user(user, opts) do
    delete_owned_principals(user, opts)

    with sprites when is_integer(sprites) <-
           destroy_sprites(user, Keyword.put_new(opts, :reason, "account_deleted")) do
      delete_user_row(user, sprites, opts)
    end
  end

  defp delete_user_row(user, sprites, opts) do
    Audit.record(%{
      user_id: user.id,
      action: "account.deleted",
      resource_type: "user",
      resource_id: user.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      # Denormalised on purpose: user_id is nilified by the delete below.
      metadata: %{
        "email" => user.email,
        "user_id" => user.id,
        "sprites_destroyed" => sprites
      }
    })

    # Cascading personal ChatGPT grants and nilifying platform-key attribution
    # both invoke platform source triggers. Take exclusive platform before
    # tenant so those triggers never upgrade shared while another reader waits
    # on our tenant lock. Teardown and audit remain outside this transaction.
    result =
      Fountain.InferenceCredentials.with_platform_source_lock(fn ->
        Fountain.InferenceCredentials.lock_source(user.id)

        case Repo.delete(user) do
          {:error, reason} -> Repo.rollback(reason)
          result -> result
        end
      end)

    case result do
      {:ok, _} ->
        Logger.info("account deleted: #{user.id} (#{sprites} sprite(s) destroyed)")

        # Confirmation to the departing user (#450). Gated on verification,
        # which covers the UnverifiedAccountPruner path for free — an
        # address that never proved it was theirs gets no mail from us,
        # whoever triggered the deletion. The job carries the address
        # itself; the row is already gone.
        if user.email_verified_at do
          Fountain.Workers.AccountEmail.enqueue_deleted(user.email)
        end

        {:ok, %{user_id: user.id, sprites_destroyed: sprites}}

      {:error, reason} ->
        Logger.error("account deletion failed at delete for #{user.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── owned principals (ADR 0044) ───────────────────────────────────────────

  # Recursive only in principle: a principal is identity-less, so it can never
  # sign in to claim one of its own, and `Principals.create_claimable/3`
  # refuses it as an application. Each of these is therefore a leaf.
  defp delete_owned_principals(%User{principal: true}, _opts), do: :ok

  defp delete_owned_principals(%User{id: owner_id}, opts) do
    for principal_id <- Fountain.Principals.list_owned(owner_id),
        %User{} = principal <- [Repo.get(User, principal_id)] do
      case delete_user(principal, Keyword.put(opts, :actor, "system:owner_deleted")) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("account deletion: owned principal #{principal_id}: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    e -> Logger.warning("deleting owned principals for #{owner_id} failed: #{inspect(e)}")
  end

  # ── sprites ───────────────────────────────────────────────────────────────

  @doc """
  Stop every sandbox a tenant is running, and return how many sprites were
  destroyed. Refuses an enclosing database transaction before stopping actors
  or calling a provider. Known machines are admission-fenced before actor
  shutdown; machines found afterward are fenced before provider deletion.
  Forced cleanup may interrupt already-admitted turns. Options carry actor,
  request_ip and a reason for the committed teardown request.

  Ask a live ConversationServer to tear itself down where one exists, so the
  sprite goes through the same path as a user-initiated terminate. Otherwise
  destroy the sprite directly.

  Public because deletion is not the only reason to stop a tenant's compute:
  expiring or releasing a claimable principal (ADR 0044) stops it too, and
  keeps the rows. Duplicating this would be duplicating the part that costs
  money when it is wrong.
  """
  @spec destroy_sprites(User.t() | binary(), keyword()) :: non_neg_integer() | {:error, term()}
  def destroy_sprites(user, opts \\ [])
  def destroy_sprites(%User{id: user_id}, opts), do: destroy_sprites(user_id, opts)

  def destroy_sprites(user_id, opts) when is_binary(user_id) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      opts = Keyword.put_new(opts, :reason, "compute_stopped")

      # `audit_events.user_id` and `sandboxes.user_id` are both nilified by the
      # delete that follows, so an event carrying only the column would survive
      # as an anonymous row pointing at an anonymous sandbox. Denormalise the
      # tenant into the metadata, as `account.deleted` already does (step 2).
      opts = Keyword.put_new(opts, :metadata, %{"user_id" => user_id})

      with :ok <- fence_sprites(user_id, opts) do
        do_destroy_sprites(user_id, opts)
      end
    end
  end

  # A refused fence is logged and the run continues. A halt here would leave
  # the rows already fenced `ready` with `teardown_requested_at` set, and their
  # machines running, while the account is still there. The reaper's other
  # passes skip such a row; only `SandboxReaper.sweep_fenced_teardowns/0`
  # finishes it, and only after its grace period (#2329). Until then the row
  # holds a `Quotas.active_sandboxes/0` slot and a fleet slot, and the machine
  # bills. Carrying on tears the rest down now rather than leaving it to that
  # sweep. ADR 0009 decision 2 makes sprite teardown best-effort, and #1767
  # asks that failed cleanup stay recoverable by reconciliation.
  defp fence_sprites(user_id, opts) do
    # ownership: live_sandboxes/1 scopes every row to this caller-owned user_id.
    user_id
    |> live_sandboxes()
    |> Enum.each(fn sandbox ->
      case Lifecycle.fence_sandbox_for_teardown(sandbox, opts) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("account deletion: fencing #{sandbox.id} refused: #{inspect(reason)}")
      end
    end)
  end

  defp do_destroy_sprites(user_id, opts) do
    conv_ids =
      Conversations.list_conversations(user_id)
      |> Enum.filter(&(ConversationServer.whereis(&1.id) != nil))
      |> Enum.map(& &1.id)

    Enum.each(conv_ids, fn id ->
      try do
        # No per-conversation row: `account.deleted` already says everything
        # went away, and the user_id these would carry is nilified moments
        # later anyway — they would be orphans describing a cascade.
        Termination.terminate_conversation(id, audit: false)
      catch
        kind, reason ->
          Logger.warning("account deletion: terminate #{id} failed: #{inspect({kind, reason})}")
      end
    end)

    # Actors may have retired a row or created another machine while stopping.
    # Re-read and fence each remaining row before touching its provider.
    # ownership: live_sandboxes/1 scopes these fresh rows to the same user_id.
    user_id
    |> live_sandboxes()
    |> Enum.reduce_while(0, fn sandbox, count ->
      case Lifecycle.fence_sandbox_for_teardown(sandbox, opts) do
        {:ok, %{status: status} = fenced} when status in @non_terminal ->
          {:cont, count + if(destroy_sprite(fenced), do: 1, else: 0)}

        {:ok, _retired} ->
          {:cont, count}

        {:error, reason} ->
          Logger.warning("account deletion: late fence refused: #{inspect(reason)}")
          {:cont, count}
      end
    end)
  end

  defp live_sandboxes(user_id) do
    Sandbox
    |> where([s], s.user_id == ^user_id and s.status in ^@non_terminal)
    |> Repo.all()
  end

  defp destroy_sprite(%Sandbox{machine_name: name} = sandbox) when is_binary(name) do
    # The row's provider, never the instance default: a sandbox is destroyed
    # on the backend that holds it (ADR 0018), and this path used to hardcode
    # :sprites, which "destroyed" E2B/Daytona/runner sandboxes against the
    # wrong adapter.
    provider = Fountain.Conversations.sandbox_provider_atom(sandbox)
    handle = Managoat.Sandbox.build_handle(provider, name)

    result =
      case Managoat.Sandbox.destroy(handle) do
        :ok ->
          true

        {:error, reason} ->
          # Not fatal. SandboxReaper reconciles terminal rows whose sprite still
          # exists, which is precisely this leftover.
          Logger.warning("account deletion: destroy #{name} failed: #{inspect(reason)}")
          false
      end

    Conversations.update_sandbox(sandbox, %{
      status: "terminated",
      terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    result
  rescue
    e ->
      Logger.warning("account deletion: destroy raised for #{name}: #{inspect(e)}")
      false
  end

  defp destroy_sprite(_), do: false
end
