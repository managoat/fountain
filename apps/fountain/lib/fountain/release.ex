defmodule Fountain.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :fountain

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          &Ecto.Migrator.run(&1, :up, all: true)
        )
    end
  end

  @doc """
  The boot-time half of `migrate/0`: migrates unless `MIGRATE_ON_BOOT=false`.

  This is what the image's `CMD` runs, and the only migration path the switch
  gates. `migrate/0` itself — and `bin/migrate`, which is what a migrations
  Job runs — always migrates, because an explicit request to migrate should
  never be silently skipped by an environment variable meant for pods that
  only serve.

  Skipping is not a no-op boot: the release still starts, and if migrations
  have not in fact been run the app will fail on the first query against a
  missing column. That is the trade a deployment makes when it moves
  migrations into a Job — the Job is what must be ordered before the rollout.
  """
  def migrate_on_boot do
    load_app()

    if migrate_on_boot?() do
      migrate()
    else
      IO.puts("MIGRATE_ON_BOOT=false — skipping migrations at boot.")
      :skipped
    end
  end

  @doc """
  Whether this node should migrate as it boots.

  Read from application env (set by `config/runtime.exs` from
  `MIGRATE_ON_BOOT`) rather than from `System.get_env/1` directly, so the two
  boot paths that migrate — this task and the `Ecto.Migrator` child in
  `Fountain.Application` — decide from one value.
  """
  def migrate_on_boot? do
    Application.get_env(@app, :migrate_on_boot, true)
  end

  def rollback(repo, version) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(
        repo,
        &Ecto.Migrator.run(&1, :down, to: version)
      )
  end

  @doc """
  Mark an account's email verified, without sending anything.

  The escape hatch for an instance whose mail provider is misconfigured or
  broken. While `email_verified_at` is nil the password still authenticates —
  login is *not* refused, which is the part worth knowing when someone reports
  "I can sign in but nothing works". The session is simply parked on
  `/auth/verify-pending` and reaches nothing else, and the API refuses both to
  mint a key and to accept one, with 403 `email_unverified` (#533). Under
  `EMAIL_DELIVERY=none` this is no longer part of first login: registration
  auto-verifies accounts there (ADR 0011). It remains for accounts created
  before mail broke, or before that mode was set.

  Verification runs the first-admin bootstrap like any other route: with
  `FIRST_USER_ADMIN=true` and no admin yet, the account comes back promoted.

      bin/fountain_server eval 'Fountain.Release.verify_email("you@example.com")'
  """
  def verify_email(email) when is_binary(email) do
    with_repo(fn -> do_verify_email(email) end)
  end

  defp do_verify_email(email) do
    case Fountain.Accounts.get_user_by_email(email) do
      nil ->
        IO.puts(:stderr, "No account found for #{email}")
        {:error, :not_found}

      user ->
        case Fountain.Accounts.verify_email(user, actor: "system:release_task") do
          {:ok, verified} ->
            IO.puts("Verified #{verified.email}. You can now sign in.")
            {:ok, verified}

          {:error, _} = err ->
            IO.puts(:stderr, "Could not verify #{email}")
            err
        end
    end
  end

  @doc """
  Grant an account the admin role, audit-recorded.

  The manual first-admin bootstrap. Both deploy guides used to end with raw
  SQL (`UPDATE users SET role = 'admin' ...`) — the only step in the
  self-deploy path that required editing the production database by hand.
  Since ADR 0011 the recommended path is `FIRST_USER_ADMIN=true`, which
  promotes the first verified account in-app; this task remains for instances
  that keep that switch off, and for lock-out recovery.

  Recorded as `admin.role.granted` with a nil actor (system-originated), so a
  promotion through this task is as visible in the admin audit trail as one
  through the admin panel. Revoking has no release task — that is done from
  the panel, by an admin, on purpose.

      bin/fountain_server eval 'Fountain.Release.promote_admin("you@example.com")'
  """
  def promote_admin(email) when is_binary(email) do
    with_repo(fn -> do_promote_admin(email) end)
  end

  defp do_promote_admin(email) do
    case Fountain.Accounts.get_user_by_email(email) do
      nil ->
        IO.puts(:stderr, "No account found for #{email}")
        {:error, :not_found}

      %{role: "admin"} = user ->
        IO.puts("#{user.email} is already an admin.")
        {:ok, user}

      user ->
        case Fountain.Accounts.update_user_role(user, "admin", actor: "system:release_task") do
          {:ok, promoted} ->
            Fountain.Audit.record_admin(%{
              actor_user_id: nil,
              target_user_id: promoted.id,
              event_type: "admin.role.granted",
              metadata: %{
                "email" => promoted.email,
                "from" => user.role,
                "to" => "admin",
                "via" => "release_task"
              }
            })

            IO.puts("Granted admin to #{promoted.email}.")
            {:ok, promoted}

          {:error, _} = err ->
            IO.puts(:stderr, "Could not grant admin to #{email}")
            err
        end
    end
  end

  @doc """
  Materialise `turns.reply_text` for every ended turn that has none (#826):
  the assistant's text of each, through the same parse the transcript uses,
  so `GET /api/search` covers replies from before the column existed. Turns
  ending after the migration are written as they end. Idempotent; prints a
  count. Runs beside the live server:

      PHX_SERVER=false METRICS_PORT=0 bin/fountain_server eval 'Fountain.Release.backfill_turn_replies()'
  """
  def backfill_turn_replies do
    load_app()

    for repo <- repos() do
      # ownership: a system-level sweep over every tenant's ended turns,
      # run by an operator beside the release — the same footing as migrate/0.
      {:ok, n, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          Fountain.Conversations._unsafe_backfill_reply_texts()
        end)

      IO.puts("backfilled reply_text on #{n} turn(s)")
    end
  end

  @doc """
  Print a read-only inventory of retained sandboxes' recorded build and skill
  metadata. Includes active and sleeping rows; it never contacts a provider or
  inspects a disk, so every disk skill manifest remains explicitly unverified.
  No skill content, provider metadata or credentials are returned.

      bin/fountain_server eval 'Fountain.Release.inventory_sandbox_metadata()'
  """
  def inventory_sandbox_metadata do
    with_repo(fn ->
      # ownership: an operator-authorized release task inventories every tenant
      # as a system sweep, outside user-facing request handling.
      report = Fountain.Conversations.SandboxMetadata._unsafe_inventory()
      IO.puts(Jason.encode!(report, pretty: true))
      report
    end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  # Starts only the repo (and its deps), never the app. Booting the whole app
  # from an eval task cannot work in production: the running server already
  # holds the HTTP and metrics ports, and a task node that started Oban and
  # the Horde registry would compete with the real cluster for jobs and
  # conversation processes.
  defp with_repo(fun) do
    load_app()
    {:ok, result, _started} = Ecto.Migrator.with_repo(Fountain.Repo, fn _repo -> fun.() end)
    result
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
