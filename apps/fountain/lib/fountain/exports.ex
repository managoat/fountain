defmodule Fountain.Exports do
  @moduledoc """
  Self-serve account data export — the other half of leave-ability (#288).

  The export posture (export-then-delete, secrets excluded, rate limit, TTL)
  is recorded in ADR 0009 (`decisions/0009-account-deletion-and-export.md`).

  Deletion is self-serve (`Fountain.Accounts.Deletion`); this makes the exit
  story export-then-delete rather than delete-and-trust. A user requests an
  export from the account page, `Fountain.Workers.AccountExport` builds one
  JSON document covering everything the account owns, and the account page
  offers a download until the artifact expires.

  ## What is included

  Agents, environments, vaults, conversations with their turns and log output,
  and the account's own audit trail.

  ## What is deliberately excluded

  **Decrypted secret values.** Environment and vault secrets were write-only on
  the way in and stay that way on the way out — the export carries secret
  *names* only, never plaintext values and never ciphertext. This is stated in
  the UI, not just here.

  ## Tenant scoping

  Every query in `build/1` is scoped by `user_id` — either directly or via a
  join through `conversations.user_id`. Nothing in this module calls an
  `_unsafe_` function, and the artifact itself is only readable through
  `get_downloadable_export/2`, which is user-scoped.

  ## Storage

  The artifact is a gzipped JSON blob in Postgres, following the existing
  pattern for generated binaries (`agent_avatars`, `turn_images`): the app has
  no object store and its local disk is ephemeral across deploys. Expiry
  (`@ttl_hours`) plus one-export-per-user keeps the table bounded; expired rows
  are purged by the worker on each run.

  ## Rate limit

  Once per hour per user, enforced against the export rows themselves rather
  than `FountainWeb.Plugs.RateLimit`: that limiter is per-IP, per-node and
  resets on deploy, which is right for anti-runaway request limiting but wrong
  for a durable per-user business rule on an expensive operation. Anchoring on
  the row's `inserted_at` survives restarts and is naturally isolated under the
  SQL sandbox in tests (no `:rate_limit_test_isolation` needed).
  """

  import Ecto.Query

  alias Fountain.Accounts.User
  alias Fountain.Agents
  alias Fountain.Audit
  alias Fountain.Conversations.{Conversation, LogEvent, Turn}
  alias Fountain.Environments
  alias Fountain.Exports.Export
  alias Fountain.Repo
  alias Fountain.Vaults

  @rate_window_seconds 3600
  @ttl_hours 24

  @doc "Seconds a user must wait between export requests."
  def rate_window_seconds, do: @rate_window_seconds

  @doc "Hours a completed export stays downloadable."
  def ttl_hours, do: @ttl_hours

  # ── requesting ─────────────────────────────────────────────────────────────

  @doc """
  Request an export for `user`: rate-check, replace any previous export rows,
  insert a pending row and enqueue the build job.

  Returns `{:ok, export}` or `{:error, {:rate_limited, retry_after_seconds}}`.

  Options:

    * `:actor` — for the audit trail, defaults to `"self"`.
    * `:request_ip` — passed through to the audit event.
  """
  @spec request_export(User.t(), keyword()) ::
          {:ok, Export.t()} | {:error, {:rate_limited, pos_integer()}} | {:error, term()}
  def request_export(%User{id: user_id} = user, opts \\ []) do
    case seconds_until_allowed(user_id) do
      0 ->
        do_request(user, opts)

      retry_after ->
        {:error, {:rate_limited, retry_after}}
    end
  end

  defp do_request(%User{id: user_id} = user, opts) do
    # Replace rather than accumulate: at most one export artifact per user.
    # This runs only after the rate check passed, so the new row becomes the
    # rate-limit anchor for the next hour.
    Repo.delete_all(from e in Export, where: e.user_id == ^user_id)

    with {:ok, export} <-
           %Export{}
           |> Export.changeset(%{status: "pending", user_id: user_id})
           |> Repo.insert(),
         {:ok, _job} <- Fountain.Workers.AccountExport.enqueue(export) do
      Audit.record(%{
        user_id: user_id,
        action: "account.export_requested",
        resource_type: "export",
        resource_id: export.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{"email" => user.email}
      })

      {:ok, export}
    end
  end

  # 0 when a request is allowed now, otherwise seconds until it is.
  defp seconds_until_allowed(user_id) do
    last =
      Repo.one(
        from e in Export,
          where: e.user_id == ^user_id,
          order_by: [desc: e.inserted_at],
          limit: 1,
          select: e.inserted_at
      )

    case last do
      nil ->
        0

      inserted_at ->
        elapsed = DateTime.diff(DateTime.utc_now(), inserted_at, :second)
        max(@rate_window_seconds - elapsed, 0)
    end
  end

  # ── reading ────────────────────────────────────────────────────────────────

  @doc "The user's current export row (any status), or nil."
  @spec latest_export(Ecto.UUID.t()) :: Export.t() | nil
  def latest_export(user_id) when is_binary(user_id) do
    Repo.one(
      from e in Export,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at],
        limit: 1,
        select: %{e | payload: nil}
    )
  end

  @doc "Get an export scoped to its owner. Returns nil on wrong owner or missing id."
  @spec get_export(Ecto.UUID.t(), Ecto.UUID.t()) :: Export.t() | nil
  def get_export(id, user_id) when is_binary(user_id) do
    Repo.get_by(Export, id: id, user_id: user_id)
  end

  @doc """
  Fetch an export for download: owner-scoped, completed, and not expired.

  Returns `{:ok, export}` (with payload) or `{:error, :not_found}` — a wrong
  tenant, a missing row, a pending/failed export and an expired one are all the
  same answer on purpose.
  """
  @spec get_downloadable_export(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Export.t()} | {:error, :not_found}
  def get_downloadable_export(id, user_id) when is_binary(user_id) do
    now = DateTime.utc_now()

    case Repo.get_by(Export, id: id, user_id: user_id) do
      %Export{status: "completed", payload: payload, expires_at: %DateTime{} = expires_at} =
          export
      when is_binary(payload) ->
        if DateTime.compare(expires_at, now) == :gt do
          {:ok, export}
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc "True when `export` is past its expiry (or has none yet)."
  def expired?(%Export{expires_at: nil}), do: true

  def expired?(%Export{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  # ── lifecycle (worker-facing) ──────────────────────────────────────────────

  @doc "Mark `export` completed with the gzipped `payload` (raw size `raw_bytes`)."
  def complete_export(%Export{} = export, payload, raw_bytes) when is_binary(payload) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@ttl_hours * 3600, :second)
      |> DateTime.truncate(:second)

    export
    |> Export.changeset(%{
      status: "completed",
      payload: payload,
      byte_size: raw_bytes,
      expires_at: expires_at
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} ->
        broadcast(updated.user_id)
        record_transition(updated, "account.export_completed", %{"bytes" => raw_bytes})

      _ ->
        :ok
    end)
  end

  @doc "Mark `export` failed."
  def fail_export(%Export{} = export, reason) do
    export
    |> Export.changeset(%{status: "failed", error: String.slice(inspect(reason), 0, 250)})
    |> Repo.update()
    |> tap(fn
      {:ok, updated} ->
        broadcast(updated.user_id)
        # The reason is already truncated to 250 chars on the row itself.
        record_transition(updated, "account.export_failed", %{"error" => updated.error})

      _ ->
        :ok
    end)
  end

  # The request and the download were audited; the outcome in between was not,
  # so a trail could show a user asking for their data and never show whether
  # the export succeeded, failed, or quietly expired before they fetched it
  # (#551). The worker is the actor — nobody asked for these transitions.
  defp record_transition(%Export{} = export, action, metadata) do
    Audit.record(%{
      user_id: export.user_id,
      action: action,
      resource_type: "export",
      resource_id: export.id,
      actor: "system:account_export",
      metadata: metadata
    })
  end

  @doc "Delete exports past their expiry. Returns the number deleted."
  def purge_expired do
    now = DateTime.utc_now()

    # Read the owners before deleting: an expiry is the user's artifact going
    # away, so it belongs in their trail, and after the delete nothing links
    # the rows to anybody.
    expiring =
      Repo.all(
        from e in Export,
          where: not is_nil(e.expires_at) and e.expires_at <= ^now,
          select: {e.id, e.user_id}
      )

    {count, _} =
      Repo.delete_all(from e in Export, where: not is_nil(e.expires_at) and e.expires_at <= ^now)

    Enum.each(expiring, fn {id, user_id} ->
      Audit.record(%{
        user_id: user_id,
        action: "account.export_expired",
        resource_type: "export",
        resource_id: id,
        actor: "system:retention_pruner",
        metadata: %{}
      })
    end)

    count
  end

  @doc "PubSub topic the account page subscribes to for export status changes."
  def topic(user_id), do: "account_exports:#{user_id}"

  defp broadcast(user_id) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(Fountain.PubSub, topic(user_id), {:export_updated, user_id})
  end

  # ── building the document ──────────────────────────────────────────────────

  @doc """
  Build the export document for `user_id` as a plain map, ready for JSON
  encoding. Every query is tenant-scoped; secret **values** never appear —
  only secret names.
  """
  @spec build(Ecto.UUID.t()) :: map()
  def build(user_id) when is_binary(user_id) do
    user = Repo.get!(User, user_id)

    %{
      "format" => "fountain.account-export",
      "version" => 1,
      "generated_at" => DateTime.utc_now(),
      "notes" => %{
        "secrets" =>
          "Secret values are deliberately excluded. They were write-only on " <>
            "the way in and stay that way on the way out; only secret names " <>
            "are listed."
      },
      "account" => account_section(user),
      "agents" => agents_section(user_id),
      "environments" => environments_section(user_id),
      "vaults" => vaults_section(user_id),
      "conversations" => conversations_section(user_id),
      "audit_trail" => audit_section(user_id)
    }
  end

  defp account_section(%User{} = user) do
    %{
      "id" => user.id,
      "email" => user.email,
      "role" => user.role,
      "comped" => user.comped,
      "credit_balance_cents" => user.credit_balance_cents,
      "email_verified_at" => user.email_verified_at,
      "created_at" => user.inserted_at
    }
  end

  defp agents_section(user_id) do
    # One query for every agent's history rather than one per agent (#1051).
    versions_by_agent = Agents.list_agent_versions_by_agent(user_id)

    user_id
    |> Agents.list_agents([])
    |> Enum.map(fn agent ->
      %{
        "id" => agent.id,
        "name" => agent.name,
        "description" => agent.description,
        "system" => agent.system,
        "model" => agent.model,
        "runtime" => agent.runtime,
        "runtime_command" => agent.runtime_command,
        "skills" => agent.skills,
        "mcp_servers" => agent.mcp_servers,
        "metadata" => agent.metadata,
        "allowed_vault_ids" => agent.allowed_vault_ids,
        "allowed_environment_ids" => agent.allowed_environment_ids,
        "environment_id" => agent.environment_id,
        "created_at" => agent.inserted_at,
        "updated_at" => agent.updated_at,
        # Config history is tenant data holding full values (unlike the audit
        # trail), so an export without it would be incomplete.
        "versions" =>
          versions_by_agent
          |> Map.get(agent.id, [])
          |> Enum.map(fn v ->
            %{"version" => v.version, "config" => v.config, "created_at" => v.inserted_at}
          end)
      }
    end)
  end

  defp environments_section(user_id) do
    user_id
    |> Environments.list_environments()
    |> Enum.map(fn env ->
      %{
        "id" => env.id,
        "name" => env.name,
        "packages" => env.packages,
        "env_vars" => env.env_vars,
        "setup_script" => env.setup_script,
        "setup_timeout_seconds" => env.setup_timeout_seconds,
        "networking_type" => env.networking_type,
        "networking_config" => env.networking_config,
        "repositories" => env.repositories,
        "metadata" => env.metadata,
        # Names only — values are write-only by design.
        # Ownership: env comes from the tenant-scoped list_environments above.
        "secret_keys" =>
          env |> Environments._unsafe_list_secrets() |> Enum.map(& &1.key) |> Enum.sort(),
        "created_at" => env.inserted_at,
        "updated_at" => env.updated_at
      }
    end)
  end

  defp vaults_section(user_id) do
    user_id
    |> Vaults.list_vaults()
    |> Enum.map(fn vault ->
      %{
        "id" => vault.id,
        "name" => vault.name,
        "description" => vault.description,
        "metadata" => vault.metadata,
        # Names only — values are write-only by design.
        # Ownership: vault comes from the tenant-scoped list_vaults above.
        "secret_keys" =>
          vault |> Vaults._unsafe_list_secrets() |> Enum.map(& &1.key) |> Enum.sort(),
        "created_at" => vault.inserted_at,
        "updated_at" => vault.updated_at
      }
    end)
  end

  defp conversations_section(user_id) do
    conversations =
      Repo.all(
        from c in Conversation,
          where: c.user_id == ^user_id,
          order_by: [asc: c.inserted_at, asc: c.id]
      )

    turns_by_conv =
      Repo.all(
        from t in Turn,
          join: c in Conversation,
          on: t.conversation_id == c.id,
          where: c.user_id == ^user_id,
          order_by: [asc: t.conversation_id, asc: t.turn_number]
      )
      |> Enum.group_by(& &1.conversation_id)

    logs_by_conv =
      Repo.all(
        from le in LogEvent,
          join: c in Conversation,
          on: le.conversation_id == c.id,
          where: c.user_id == ^user_id,
          order_by: [asc: le.conversation_id, asc: le.id]
      )
      |> Enum.group_by(& &1.conversation_id)

    Enum.map(conversations, fn conv ->
      %{
        "id" => conv.id,
        "title" => conv.title,
        "status" => conv.status,
        "runtime" => conv.runtime,
        "source" => conv.source,
        "agent_id" => conv.agent_id,
        "vault_id" => conv.vault_id,
        "environment_id" => conv.environment_id,
        "parent_conversation_id" => conv.parent_conversation_id,
        "created_at" => conv.inserted_at,
        "updated_at" => conv.updated_at,
        "turns" => Enum.map(Map.get(turns_by_conv, conv.id, []), &turn_entry/1),
        "log_events" => Enum.map(Map.get(logs_by_conv, conv.id, []), &log_entry/1)
      }
    end)
  end

  defp turn_entry(turn) do
    %{
      "turn_number" => turn.turn_number,
      "prompt" => turn.prompt,
      "status" => turn.status,
      "exit_code" => turn.exit_code,
      "started_at" => turn.started_at,
      "ended_at" => turn.ended_at,
      # The API's `inference` object: whose credential served the turn, and
      # which ChatGPT subscription when it was one. Never a fencing value.
      "inference" => inference_entry(turn.inference_source)
    }
  end

  defp inference_entry(stored) do
    case Fountain.InferenceCredentials.Source.summary(stored) do
      nil -> nil
      summary -> Map.new(summary, fn {key, value} -> {Atom.to_string(key), value} end)
    end
  end

  defp log_entry(le) do
    %{
      "kind" => le.kind,
      "stream" => le.stream,
      "data" => le.data,
      "stage" => LogEvent.rendered_stage(le),
      "state" => LogEvent.rendered_state(le),
      "duration_ms" => le.duration_ms,
      "turn_id" => le.turn_id,
      "at" => le.inserted_at
    }
  end

  defp audit_section(user_id) do
    Repo.all(
      from e in Audit.Event,
        where: e.user_id == ^user_id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
    |> Enum.map(fn e ->
      %{
        "action" => e.action,
        "resource_type" => e.resource_type,
        "resource_id" => e.resource_id,
        "actor" => e.actor,
        "request_ip" => e.request_ip,
        "metadata" => e.metadata,
        "at" => e.inserted_at
      }
    end)
  end
end
