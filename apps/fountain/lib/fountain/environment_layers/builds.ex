defmodule Fountain.EnvironmentLayers.Builds do
  @moduledoc """
  Durable admission, single-use claims and publication for disposable builders.

  This is the lifecycle boundary for the trusted build/export pipeline. It never launches a conversation or accepts its credentials. A
  request reserves a normal owned sandbox under the fleet ceiling; `run/4`
  executes a trusted callback under that machine's existing owner protocol.
  The callback must quiesce services, revoke its build-only broker session,
  validate/export and upload before returning artifact metadata. The production callback lives in `Pipeline`; opted-in launches probe compatibility
  and select ready artifacts before conversation configuration is installed.

  Every state mutation is scoped by owner and audited after commit. A claim is
  single-use: a crashed worker is canceled/reaped, never replayed on the same
  filesystem. Cleanup retains durable intent and waits out upload capabilities.
  """
  import Ecto.Query
  alias Fountain.{Audit, Environments, Quotas, Repo}
  alias Fountain.Conversations.{Lifecycle, Sandbox}
  alias Fountain.Environments.Environment
  alias Fountain.EnvironmentLayers.{Build, Envelope, Manifest, Store}
  alias Fountain.Machines.{Machine, Provision}

  @active ~w(queued building ready)
  @actor [actor: "system:environment_layers"]

  def get(user_id, id), do: Repo.get_by(Build, id: id, user_id: user_id)

  @doc "Reserve a disposable builder; the trusted caller supplies immutable compatibility."
  def request(user_id, environment_id, compatibility, opts \\ []) do
    with %Environment{} <- Environments.get_environment(environment_id, user_id),
         {:ok, store_ref} <- Store.identity(Keyword.get(opts, :store, [])) do
      Repo.transaction(fn ->
        env = locked_environment(user_id, environment_id)

        with %Environment{cache_enabled: true} <- env,
             {:ok, binding} <- Manifest.binding(env, compatibility) do
          existing =
            Repo.one(
              from b in Build,
                where:
                  b.environment_id == ^env.id and
                    b.generation == ^env.build_generation and
                    b.fingerprint == ^binding["fingerprint"] and
                    b.state in ^@active and b.store_ref == ^store_ref
            )

          if existing do
            if not DateTime.after?(existing.expires_at, now()) or
                 (existing.state != "ready" and not current?(existing, env)),
               do: Repo.rollback(:build_obsolete)

            {existing, false}
          else
            # Serialize admission under the provider fleet lock; no external I/O.
            case Quotas.with_sandbox_reservation([provider: "sprites"], fn ->
                   reserve(env, binding, compatibility, store_ref)
                 end) do
              {:ok, result} -> result
              {:error, reason} -> Repo.rollback(reason)
            end
          end
        else
          _ -> Repo.rollback(:cache_not_buildable)
        end
      end)
      |> audited("environment_layer.requested", opts)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp reserve(env, binding, compatibility, store_ref) do
    id = Ecto.UUID.generate()

    with {:ok, sandbox} <-
           Provision.reserve(%{
             user_id: env.user_id,
             environment_id: env.id,
             provider: "sprites",
             machine_name: "fountain-#{String.slice(env.user_id, 0, 8)}-#{id}"
           }) do
      time = now()

      build = %Build{
        id: id,
        user_id: env.user_id,
        environment_id: env.id,
        owner_ref: env.user_id,
        environment_ref: env.id,
        sandbox_id: sandbox.id,
        generation: env.build_generation,
        policy_revision: env.build_policy_revision,
        fingerprint: binding["fingerprint"],
        store_ref: store_ref,
        binding: binding,
        revisions: compatibility["revisions"],
        deadline_at: DateTime.add(time, 900),
        expires_at: DateTime.add(time, 86_400),
        cleanup_after: DateTime.add(time, 1800)
      }

      case Repo.insert(build) do
        {:ok, build} -> {:ok, {build, true}}
        error -> error
      end
    end
  end

  @doc "Grant upload only to the current claimed builder, expiring no later than its deadline."
  def upload_grant(user_id, id, claim, opts \\ []) do
    with %Build{state: "building", claim: ^claim} = build <- get(user_id, id),
         {:ok, _} <- inputs(user_id, build),
         {:ok, store_ref} <- Store.identity(Keyword.get(opts, :store, [])),
         true <- build.store_ref == store_ref do
      issued_at = now()
      expires = min(300, DateTime.diff(build.deadline_at, issued_at))

      Store.grant(
        user_id,
        build.environment_id,
        build.id,
        :put,
        Keyword.merge(Keyword.get(opts, :store, []), now: issued_at, expires: expires)
      )
    else
      _ -> {:error, :obsolete_or_claimed}
    end
  end

  @doc "Claim once. The returned claim must accompany publication and failure."
  def claim(user_id, id, opts \\ []) do
    mutate(user_id, id, "environment_layer.started", opts, fn build, env ->
      if build.state == "queued" and current?(build, env) do
        persist(build, state: "building", claim: Ecto.UUID.generate())
      else
        {:error, :obsolete_or_claimed}
      end
    end)
  end

  @doc "Run an environment-only pipeline under the existing machine owner and always clean up."
  def run(user_id, id, pipeline, opts \\ []) when is_function(pipeline, 2) do
    with {:ok, build} <- claim(user_id, id, opts) do
      parent = self()

      try do
        task =
          Task.Supervisor.async_nolink(Fountain.TaskSupervisor, fn ->
            watch_worker(parent, build.deadline_at)

            try do
              Machine.provision(
                build.sandbox_id,
                fn handle, _epoch ->
                  # Keep cleanup in the owner even when the callback fails or raises.
                  outcome =
                    try do
                      with {:ok, input} <- inputs(user_id, build), do: pipeline.(handle, input)
                    rescue
                      _ -> {:error, :build_failed}
                    catch
                      _, _ -> {:error, :build_failed}
                    end

                  {:ok, outcome}
                end,
                actor: Keyword.get(opts, :actor, "system:environment_layers")
              )
            rescue
              _ -> {:error, :build_failed}
            catch
              _, _ -> {:error, :build_failed}
            end
          end)

        result =
          try do
            await_build(task, user_id, build)
          after
            Task.shutdown(task, :brutal_kill)
          end

        case result do
          {:ok, :provisioned, {:ok, artifact}} ->
            # ownership: this build and immutable object address came from the system cleanup sweep.
            with :ok <- destroy_builder(build),
                 {:ok, ready} <- publish(user_id, id, build.claim, artifact, opts) do
              {:ok, ready}
            else
              _ -> failed_run(user_id, id, build.claim, opts)
            end

          _ ->
            failed_run(user_id, id, build.claim, opts)
        end
      rescue
        _ -> failed_run(user_id, id, build.claim, opts)
      after
        _ = destroy_builder(build)
      end
    end
  end

  defp failed_run(user_id, id, claim, opts) do
    case fail(user_id, id, claim, opts) do
      {:ok, _} -> {:error, :build_failed}
      error -> error
    end
  end

  # A caller can die (including a normal request exit) while a provider or
  # script is blocked. The independent supervised watchdog bounds that work even
  # when nobody is left to poll. It carries only process IDs and a deadline.
  defp watch_worker(parent, deadline) do
    worker = self()
    timeout = max(1, DateTime.diff(deadline, DateTime.utc_now(), :millisecond))

    {:ok, _} =
      Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
        worker_ref = Process.monitor(worker)
        parent_ref = Process.monitor(parent)

        receive do
          {:DOWN, ^worker_ref, :process, ^worker, _} -> :ok
          {:DOWN, ^parent_ref, :process, ^parent, _} -> Process.exit(worker, :kill)
        after
          timeout -> Process.exit(worker, :kill)
        end
      end)

    :ok
  end

  defp await_build(task, user_id, build) do
    case Task.yield(task, 250) do
      {:ok, result} ->
        result

      {:exit, _} ->
        {:error, :build_failed}

      nil ->
        current = get(user_id, build.id)

        if current && current.state == "building" && current.claim == build.claim &&
             match?({:ok, _}, inputs(user_id, build)) do
          await_build(task, user_id, build)
        else
          Task.shutdown(task, :brutal_kill)
          {:error, :build_canceled}
        end
    end
  end

  # This input has no agent, vault, conversation, callback or inference material.
  # Secret values are intentionally absent: the trusted pipeline creates a
  # build-only broker session from this environment and revokes it before return.
  defp inputs(user_id, build) do
    env = Environments.get_environment(build.environment_id, user_id)

    if current?(build, env) do
      {:ok,
       %{
         build_id: build.id,
         claim: build.claim,
         environment_id: env.id,
         user_id: user_id,
         binding: build.binding,
         packages: env.packages,
         env_vars: env.env_vars,
         repositories: env.repositories,
         revisions: build.revisions,
         build_script: env.build_script,
         timeout_seconds: env.setup_timeout_seconds,
         networking_type: env.networking_type,
         networking_config: env.networking_config
       }}
    else
      {:error, :obsolete}
    end
  end

  @doc "Publish only the claimed, current build after its disposable machine is gone."
  def publish(user_id, id, claim, artifact, opts \\ []) do
    mutate(user_id, id, "environment_layer.ready", opts, fn build, env ->
      with true <- build.state == "building" and build.claim == claim and current?(build, env),
           true <- terminated?(build.sandbox_id),
           {:ok, attrs} <- artifact_attrs(build, artifact) do
        persist(build, attrs ++ [state: "ready", claim: nil, cleanup_pending: false])
      else
        _ -> {:error, :publication_refused}
      end
    end)
  end

  defp artifact_attrs(build, %{sha256: digest, bytes: bytes, identity: identity})
       when is_binary(digest) and is_integer(bytes) and bytes > 0 and bytes <= 1_073_741_824 do
    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         {:ok, wrapped} <-
           Envelope.wrap(build.user_id, build.environment_id, build.id, build.binding, identity) do
      {:ok, [ciphertext_sha256: digest, ciphertext_bytes: bytes, wrapped_identity: wrapped]}
    else
      _ -> {:error, :invalid_artifact}
    end
  end

  defp artifact_attrs(_, _), do: {:error, :invalid_artifact}

  def fail(user_id, id, claim, opts \\ []) do
    mutate(user_id, id, "environment_layer.failed", opts, fn build, _env ->
      if build.state == "building" and build.claim == claim,
        do: persist(build, terminal("failed")),
        else: {:error, :obsolete_or_claimed}
    end)
  end

  def cancel(user_id, id, opts \\ []) do
    result =
      mutate(user_id, id, "environment_layer.canceled", opts, fn build, _env ->
        if build.state in @active,
          do: persist(build, terminal("canceled")),
          else: {:ok, {build, false}}
      end)

    case result do
      {:ok, build} -> _ = destroy_builder(build)
      _ -> :ok
    end

    result
  end

  @doc "Only a ready, unexpired artifact from the current environment generation is selectable."
  def ready(user_id, environment_id, compatibility, opts \\ []) do
    with %Environment{cache_enabled: true} = env <-
           Environments.get_environment(environment_id, user_id),
         {:ok, store_ref} <- Store.identity(Keyword.get(opts, :store, [])),
         {:ok, binding} <- Manifest.binding(env, compatibility) do
      Repo.one(
        from b in Build,
          join: e in Environment,
          on: e.id == b.environment_id,
          where:
            b.user_id == ^user_id and b.environment_id == ^environment_id and
              b.generation == ^env.build_generation and b.fingerprint == ^binding["fingerprint"] and
              b.state == "ready" and b.store_ref == ^store_ref and b.expires_at > ^now() and
              e.cache_enabled and
              e.build_generation == b.generation
      )
    else
      _ -> nil
    end
  end

  defp mutate(user_id, id, action, opts, fun) do
    case get(user_id, id) do
      nil ->
        {:error, :not_found}

      initial ->
        Repo.transaction(fn ->
          env = locked_environment(user_id, initial.environment_id)

          build =
            Repo.one(
              from b in Build, where: b.id == ^id and b.user_id == ^user_id, lock: "FOR UPDATE"
            )

          case build && fun.(build, env) do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
            nil -> Repo.rollback(:not_found)
          end
        end)
        |> audited(action, opts)
    end
  end

  defp locked_environment(_, nil), do: nil

  # Serialize build inputs without blocking sandbox foreign-key checks under the quota lock.
  defp locked_environment(user_id, id),
    do:
      Repo.one(
        from e in Environment,
          where: e.id == ^id and e.user_id == ^user_id,
          lock: "FOR NO KEY UPDATE"
      )

  defp current?(build, %Environment{} = env),
    do:
      env.cache_enabled and
        env.build_generation == build.generation and
        env.build_policy_revision == build.policy_revision and
        DateTime.after?(build.deadline_at, now())

  defp current?(_, _), do: false

  defp terminated?(nil), do: false

  defp terminated?(id),
    do: Repo.exists?(from s in Sandbox, where: s.id == ^id and s.status == "terminated")

  defp terminal(state),
    do: [state: state, claim: nil, wrapped_identity: nil, cleanup_pending: true]

  defp persist(build, attrs) do
    case build |> Ecto.Changeset.change(attrs) |> Repo.update() do
      {:ok, updated} -> {:ok, {updated, true}}
      error -> error
    end
  end

  defp audited({:ok, {build, changed?}}, action, opts) do
    if changed? and build.user_id do
      Audit.record_resource(action, "environment_layer", build, opts)
    end

    {:ok, build}
  end

  defp audited(other, _, _), do: other

  defp destroy_builder(%Build{sandbox_id: nil} = build),
    do: Fountain.Broker.Native.Sessions.release_build(build.owner_ref, build.id)

  defp destroy_builder(build) do
    :ok = Fountain.Broker.Native.Sessions.release_build(build.owner_ref, build.id)
    # Ownership: build was tenant-scoped, or came from the system cleanup sweep.
    case Repo.get(Sandbox, build.sandbox_id) do
      nil ->
        :ok

      sandbox ->
        with {:ok, _} <- Lifecycle.fence_sandbox_for_teardown(sandbox, @actor),
             {:ok, _} <-
               Machine.destroy(
                 sandbox.id,
                 @actor ++ [reason: :environment_layer_cleanup, terminating_conversation_id: nil]
               ) do
          if Repo.exists?(
               from s in Sandbox,
                 where: s.id == ^sandbox.id and s.status in ["terminated", "failed"]
             ) and builder_gone?(sandbox), do: :ok, else: {:error, :cleanup_pending}
        end
    end
  rescue
    _ -> {:error, :cleanup_pending}
  catch
    :exit, _ -> {:error, :cleanup_pending}
  end

  # The owner retires rows even when provider deletion fails; the reaper retries.
  # Publication needs stronger evidence than that terminal database status.
  defp builder_gone?(sandbox) do
    handle = %Managoat.Sandbox.Handle{provider: :sprites, name: sandbox.machine_name}
    Managoat.Sandbox.get(handle) == {:error, :not_found}
  end

  @doc "System-only bounded sweep: invalidate obsolete builds and reconcile durable cleanup."
  def reap(opts \\ []) do
    Repo.all(
      from b in Build,
        order_by: b.updated_at,
        limit: 50,
        left_join: e in Environment,
        on: e.id == b.environment_id,
        where:
          (b.cleanup_pending and b.state not in ^@active) or
            (b.state in ^@active and
               (is_nil(e.id) or is_nil(b.user_id) or not e.cache_enabled or
                  e.build_generation != b.generation or b.expires_at <= ^now() or
                  (b.state in ["queued", "building"] and
                     (b.deadline_at <= ^now() or e.build_policy_revision != b.policy_revision)))),
        select: b
    )
    |> Enum.each(&reap_one(&1, opts))

    :ok
  end

  defp reap_one(build, opts) do
    env =
      if build.user_id && build.environment_id,
        do: Environments.get_environment(build.environment_id, build.user_id)

    obsolete =
      is_nil(env) or not env.cache_enabled or env.build_generation != build.generation or
        (build.state in ~w(queued building) and env.build_policy_revision != build.policy_revision)

    expired = DateTime.compare(build.expires_at, now()) != :gt

    overdue =
      build.state in ~w(queued building) and DateTime.compare(build.deadline_at, now()) != :gt

    build =
      if build.state in @active and (obsolete or expired or overdue) do
        # System sweep owns this read; CAS preserves a concurrent terminal state.
        state = if expired, do: "expired", else: "canceled"

        {count, _} =
          Repo.update_all(from(b in Build, where: b.id == ^build.id and b.state == ^build.state),
            set: terminal(state) ++ [updated_at: now()]
          )

        if count == 1 and build.user_id,
          do:
            Audit.record_resource(
              "environment_layer.#{state}",
              "environment_layer",
              build,
              @actor
            )

        Repo.get!(Build, build.id)
      else
        build
      end

    if build.state not in @active do
      Repo.update_all(from(b in Build, where: b.id == ^build.id), set: [updated_at: now()])

      # ownership: this build and immutable object address came from the system cleanup sweep.
      with :ok <- destroy_builder(build),
           true <- DateTime.compare(build.cleanup_after, now()) != :gt,
           {:ok, store_ref} <- Store.identity(Keyword.get(opts, :store, [])),
           true <- build.store_ref == store_ref,
           :ok <-
             Store._unsafe_delete_artifact(
               build.owner_ref,
               build.environment_ref,
               build.id,
               Keyword.get(opts, :store, [])
             ) do
        {count, _} =
          Repo.update_all(from(b in Build, where: b.id == ^build.id and b.cleanup_pending),
            set: [cleanup_pending: false, updated_at: now()]
          )

        if count == 1 and build.user_id,
          do:
            Audit.record_resource("environment_layer.cleaned", "environment_layer", build, @actor)
      end
    end
  rescue
    # No provider response, URL, key, or command output enters logs/audit.
    _ -> :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
