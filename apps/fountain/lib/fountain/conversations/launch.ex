defmodule Fountain.Conversations.Launch do
  @moduledoc """
  The channel door of a conversation launch: `start_or_resume_conversation/2`,
  the resume of a conversation already bound to a channel, the channel
  rotation it can be asked for, and the lookup a channel resolves to.

  Stage 7a of #2175 (one owner per conversation lifecycle verb) gave this
  module the channel door. Stage 7b added the fresh `start_conversation/2`
  family — the reservation, the admission inference resolve and the one
  Horde `child_spec/3` builder every launch path now shares. `attach_conversation`
  stays in `Fountain.Conversations` until stage 7c; `Conversations` keeps a
  delegate for every public name here, so no caller moves.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Agents
  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.InferenceResolution

  alias Fountain.Conversations.{
    Conversation,
    ConversationServer,
    ExecutionAllowance,
    InferenceBinding,
    Sandbox
  }

  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Repo

  # Advisory-lock namespace for per-sandbox machine operations — must match
  # `Fountain.Conversations`' own `@sandbox_lock_namespace` (4316); every
  # module that takes this lock hardcodes the same integer rather than
  # sharing the attribute, since module attributes do not cross a module
  # boundary (`conversations/execution_guard.ex`, `conversations/sandbox_identity.ex`
  # do the same).
  @sandbox_lock_namespace 4316

  @doc """
  Create a new sandbox + conversation pair, start a ConversationServer
  to drive it, optionally seed with the first prompt. Returns the
  persisted Conversation (preloaded).

  ## Required attrs
    - `agent_id`              — agent to run
    - `prompt`                — optional first prompt (sends turn 1 immediately)
    - `sprite_name`           — optional suffix for the sandbox name, which is always
                                "fountain-<short-user-id>-<suffix>"; defaults to a random
                                suffix. Refused with `sandbox_api_access: "none"`, and on
                                the runner provider, whose names carry placement (#1632)
    - `vault_id`              — optional vault whose secrets override the env's
    - `environment_id`        — optional environment to provision from instead of the
                                agent's own (#783); subject to `agent.allowed_environment_ids`
    - `permission_policy`     — optional per-tool permission override (#939); may only
                                narrow the agent's own policy, never widen it
    - `sandbox_api_access`    — "owner" (default) or "none"; none requires a fresh ephemeral sandbox
    - `source`                — optional; one of "ui", "api", "agent" (default "api")
    - `parent_conversation_id` — optional; UUID of the conversation that spawned this one
    - `title`                 — optional display title (the team page names a teammate with it)
    - `labels`                — optional `key => value` strings (#1637); see `Conversations.Labels`
  """
  def start_conversation(attrs, opts \\ [])

  # `sandbox_id`: attach to a machine the caller already has instead of
  # provisioning one (ADR 0023 gate 3). Everything about the launch is
  # resolved the same way; only the sandbox step differs.
  def start_conversation(%{"sandbox_id" => sandbox_id} = attrs, opts)
      when is_binary(sandbox_id) and sandbox_id != "" do
    Conversations.attach_conversation(sandbox_id, attrs, opts)
  end

  def start_conversation(%{"agent_id" => agent_id, "user_id" => user_id} = attrs, opts)
      when is_binary(user_id) do
    with :ok <- Conversations.require_provider_commit_boundary(),
         :ok <- Fountain.Conversations.PromptInput.validate_initial(attrs),
         %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         :ok <- Conversations.check_execution_limits(user_id, attrs["execution_limits"]),
         {:ok, runtime_module} <- Fountain.RuntimeDispatch.for_agent(agent),
         {:ok, vault_id} <- Conversations.resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <-
           Conversations.resolve_environment_id(attrs["environment_id"], user_id, agent),
         {:ok, cred_set_id} <-
           Conversations.resolve_inference_credential_id(
             attrs["inference_credential_id"],
             user_id,
             agent
           ),
         {:ok, mode} <- Conversations.resolve_sandbox_mode(attrs["sandbox_mode"], agent),
         {:ok, api_access} <-
           Conversations.resolve_sandbox_api_access(attrs["sandbox_api_access"], mode),
         :ok <- Conversations.check_sandbox_api_name(api_access, attrs["sprite_name"]),
         {:ok, perm_policy} <-
           Conversations.resolve_permission_policy(attrs["permission_policy"], agent),
         {:ok, parent_id} <-
           Conversations.resolve_parent_id(attrs["parent_conversation_id"], user_id),
         :ok <- Fountain.Accounts.check_not_suspended(user_id),
         :ok <- Fountain.Billing.check_spend(user_id),
         {:ok, inference_source} <-
           resolve_admission_inference(user_id, agent, env_id, vault_id, cred_set_id),
         # A persistent launch lands on the identity's home when there is one
         # (ADR 0023 gate 6): `{:home, sandbox}` leaves the `with` and attaches
         # below. Only when there is none does a machine get provisioned, and
         # it is stamped as the home.
         :new <- home_or_new(mode, user_id, agent, env_id || agent.environment_id, vault_id),
         {:ok, provider} <- Conversations.resolve_sandbox_provider(agent),
         {:ok, machine_name} <-
           Conversations.mint_machine_name(provider, user_id, attrs["sprite_name"]),
         {:ok, {sandbox, conv, allowance}} <-
           reserve_initial_conversation(
             %{
               environment_id: env_id || agent.environment_id,
               # The identity the disk is built from (ADR 0023); an attach
               # later must name the same three.
               agent_id: agent.id,
               vault_id: vault_id,
               mode: mode,
               machine_name: machine_name,
               status: "pending",
               provider: Atom.to_string(provider),
               user_id: user_id
             },
             %{
               agent_id: agent.id,
               # Ownership: agent came from the scoped get_agent above.
               agent_version_id: Agents._unsafe_current_version_id(agent.id),
               vault_id: vault_id,
               environment_id: env_id,
               inference_credential_id: inference_source.set_id,
               inference_source: Source.dump(inference_source),
               user_id: user_id,
               runtime: agent.runtime,
               status: "pending",
               source: attrs["source"] || "api",
               parent_conversation_id: parent_id,
               channel_id: attrs["channel_id"],
               title: attrs["title"],
               sandbox_api_access: api_access,
               permission_policy: perm_policy,
               caller_tools: attrs["caller_tools"] || [],
               labels: attrs["labels"] || %{}
             },
             attrs["execution_limits"],
             opts
           ) do
      Conversations.after_conversation_created(conv)
      Conversations.record_execution_allowance_created(allowance, user_id, opts)

      # Recorded here rather than in either branch below: both of them return
      # {:ok, conv}. The row exists and the sandbox reservation is spent even
      # when the server fails to start, so "a conversation was created" is
      # true either way, and a trail that only logged the happy path would
      # under-report exactly the runs someone is trying to explain.
      #
      # The prompt is described, never quoted — see `send_prompt/4`.
      Audit.record(%{
        user_id: user_id,
        action: "conversation.created",
        resource_type: "conversation",
        resource_id: conv.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{
          "agent_id" => agent.id,
          "agent_name" => agent.name,
          "source" => conv.source,
          "with_prompt" => is_binary(attrs["prompt"]) and attrs["prompt"] != "",
          "parent_conversation_id" => parent_id
        }
      })

      start_result =
        Horde.DynamicSupervisor.start_child(
          Fountain.ConversationSupervisor,
          child_spec(conv.id, sandbox.id, runtime_module)
        )

      case start_result do
        {:ok, pid} ->
          if is_binary(attrs["prompt"]) and attrs["prompt"] != "" do
            ConversationServer.queue_initial_prompt(
              pid,
              attrs["prompt"],
              attrs["images"] || []
            )
          end

          # ownership: conv is the row reserve_initial_conversation just
          # created above, in this same launch.
          result = Conversations._unsafe_get_conversation!(conv.id)

          if result.parent_conversation_id do
            root_id = Conversations.get_root_conversation_id(result.id)
            Conversations.broadcast_graph_update(root_id)
          end

          Conversations.broadcast_sidebar_update(user_id)
          {:ok, result}

        {:error, reason} ->
          # The conversation row was created successfully; mark it and its
          # sandbox failed so the status is visible on the conversation page,
          # then return it so callers (UI + API) navigate there rather than
          # leaving the user stuck on the new-conversation form.
          Logger.error(
            "ConversationServer failed to start for conv #{conv.id}: #{inspect(reason)}"
          )

          if fail_initial_start(conv, sandbox) == :failed,
            do: restore_rotated_channel(conv, opts)

          case Conversations.get_conversation(conv.id, user_id) do
            nil ->
              {:error, :not_found}

            result ->
              Conversations.broadcast_sidebar_update(user_id)
              {:ok, result}
          end
      end
    else
      nil ->
        {:error, :not_found}

      # The identity already has a home: this launch is a conversation on it.
      {:home, %Sandbox{} = home} ->
        Conversations.attach_conversation(home.id, attrs, opts)

      # Two persistent launches of one identity raced to create its home and
      # this one lost at the unique index. The winner's row is the home now;
      # land on it rather than fail a request that asked for nothing unusual.
      {:error, %Ecto.Changeset{errors: errors}} = err ->
        if Keyword.has_key?(errors, :home) do
          with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id),
               {:ok, vault_id} <-
                 Conversations.resolve_vault_id(attrs["vault_id"], user_id, agent),
               {:ok, env_id} <-
                 Conversations.resolve_environment_id(attrs["environment_id"], user_id, agent),
               # ownership: agent above came from the scoped get_agent.
               %Sandbox{} = home <-
                 Conversations._unsafe_find_home(
                   user_id,
                   agent.id,
                   env_id || agent.environment_id,
                   vault_id
                 ) do
            Conversations.attach_conversation(home.id, attrs, opts)
          else
            _ -> err
          end
        else
          err
        end

      {:error, _} = err ->
        err
    end
  end

  # Tenant row waits happen here, before the fleet lock, and the reservation
  # runs inside them. `with_sandbox_reservation/3` holds
  # `pg_advisory_xact_lock(@fleet_lock_key)` — one lock shared by every tenant —
  # so anything that can wait on another transaction must be settled before it
  # is taken, or one account stalls provisioning for all of them.
  #
  # A delayed start error owns only its original, still-pending binding.
  # Match turn admission's machine -> parent -> sandbox lock order. Status
  # changes commit together; metering follows commit and provider I/O is absent.
  defp fail_initial_start(conv, sandbox) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          @sandbox_lock_namespace,
          :erlang.phash2(sandbox.id)
        ])

        parent = Repo.one(from c in Conversation, where: c.id == ^conv.id, lock: "FOR UPDATE")
        machine = Repo.one(from s in Sandbox, where: s.id == ^sandbox.id, lock: "FOR UPDATE")

        # ownership: sandbox/conv are the pair fail_initial_start was called
        # for; machine above re-reads sandbox.id FOR UPDATE in this same
        # transaction.
        if pending_initial_binding?(parent, machine, conv, sandbox) and
             Conversations._unsafe_running_turns_elsewhere(sandbox.id, nil) == 0 do
          parent |> Conversation.changeset(%{status: "failed"}) |> Repo.update!()

          machine
          |> Sandbox.changeset(%{status: "failed"})
          |> Conversations.stamp_terminated_at()
          |> Repo.update!()
        else
          :stale
        end
      end)

    case result do
      %Sandbox{} = failed ->
        Conversations.record_sandbox_usage("pending", failed)
        :failed

      :stale ->
        :stale
    end
  end

  defp pending_initial_binding?(%Conversation{} = parent, %Sandbox{} = machine, conv, sandbox) do
    Map.take(parent, [:user_id, :sandbox_id, :status]) ==
      %{user_id: conv.user_id, sandbox_id: sandbox.id, status: "pending"} and
      Map.take(machine, [:user_id, :provider, :machine_name, :status]) ==
        %{
          user_id: conv.user_id,
          provider: sandbox.provider,
          machine_name: sandbox.machine_name,
          status: "pending"
        }
  end

  defp pending_initial_binding?(_, _, _, _), do: false

  # An unlocked read was not enough: `create_sandbox/1` and the conversation
  # insert take `KEY SHARE` on `users` through their foreign keys, and
  # `Credits.insert_and_move/3` holds that row `FOR UPDATE` across a ledger
  # insert, lot consumption and the balance move. Taking `FOR SHARE` out here
  # both settles the wait outside the fleet lock and satisfies those foreign
  # keys, so the inserts below cannot block on it. The rotation unbind is the
  # same category of wait and joins them.
  #
  # This is one transaction: the nested `Repo.transaction` inside
  # `with_sandbox_reservation/3` joins it rather than opening another, so the
  # sandbox, conversation and allowance still commit or roll back together.
  # That is also why the `case` below re-raises the inner rollback with its
  # reason: a nested rollback the outer transaction does not re-raise reaches
  # the caller as `{:error, :rollback}`, which would turn every credits, quota
  # and fleet refusal into a 500 instead of a 402, 422 or 503.
  #
  # The wait does not disappear, it changes hands. This transaction holds
  # `users FOR SHARE` for its whole life, the fleet-lock wait included, and
  # `FOR SHARE` conflicts with `FOR UPDATE` — so this tenant's credit postings
  # now queue behind its own in-flight launch, which may itself be queued
  # behind every other tenant's. Turn burns, purchases, grants, expiry and
  # refund clawbacks all post through `Credits.insert_and_move/3`. A
  # tenant-scoped wait beats a fleet-wide one, which is why it is the right
  # trade, but a slow credit posting starts here.
  defp reserve_initial_conversation(sandbox_attrs, conversation_attrs, request, opts) do
    Repo.transaction(fn ->
      # Set/secret mutations take this same tenant lock. Take it before the
      # fleet reservation so a source edit cannot stall every tenant's launch.
      :ok = InferenceCredentials.lock_source(conversation_attrs.user_id)

      Repo.one(
        from u in Fountain.Accounts.User,
          where: u.id == ^conversation_attrs.user_id,
          select: u.id,
          lock: "FOR SHARE"
      ) || Repo.rollback(:not_found)

      Repo.one(
        from a in Agents.Agent,
          where:
            a.id == ^conversation_attrs.agent_id and a.user_id == ^conversation_attrs.user_id,
          select: a.id,
          lock: "FOR SHARE"
      ) || Repo.rollback(:not_found)

      case unbind_rotated_channel(conversation_attrs, opts) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      result =
        Fountain.Quotas.with_sandbox_reservation(conversation_attrs.user_id, fn ->
          with {:ok, limits} <-
                 Conversations.resolve_admission_limits(conversation_attrs.user_id, request),
               {:ok, sandbox} <- Conversations.create_sandbox(sandbox_attrs),
               {:ok, conv} <-
                 Conversations.insert_conversation_row(
                   Map.put(conversation_attrs, :sandbox_id, sandbox.id)
                 ),
               :ok <- Conversations.reserve_inference(conv),
               {:ok, allowance} <-
                 conv.id |> ExecutionAllowance.new_changeset(limits) |> Repo.insert() do
            {:ok, {sandbox, conv, allowance}}
          end
        end)

      case result do
        {:ok, reserved} -> reserved
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # `:new` when a machine has to be provisioned; `{:home, sandbox}` when the
  # identity already has one to land on. A home still provisioning from its
  # first launch cannot take a second conversation yet — its prompt would be
  # handed to the wrong server — so it reads as `:provisioning`, the same
  # retry-shortly answer a mid-provision conversation gives.
  defp home_or_new("ephemeral", _user_id, _agent, _env_id, _vault_id), do: :new

  defp home_or_new("persistent", user_id, %Agents.Agent{id: agent_id}, env_id, vault_id) do
    # ownership: user_id/agent_id come from the scoped get_agent that ran
    # before home_or_new is reached.
    case Conversations._unsafe_find_home(user_id, agent_id, env_id, vault_id) do
      nil -> :new
      %Sandbox{status: s} when s in ["pending", "starting"] -> {:error, :provisioning}
      %Sandbox{} = home -> {:home, home}
    end
  end

  @doc """
  What admission resolves the launch's inference to: the requested or
  default credential set, gated by platform inference. Public for
  `Fountain.Conversations.attach_conversation/3`, which resolves the same way
  (stage 7b of #2175); not a request-facing entry point.
  """
  def resolve_admission_inference(user_id, agent, env_id, vault_id, set_id) do
    with {:ok, source, _credentials} <-
           InferenceResolution.select(user_id, agent,
             credential_set_id: set_id,
             environment_id: env_id,
             vault_id: vault_id
           ),
         :ok <- Fountain.PlatformInference.gate_source(source) do
      {:ok, source}
    end
  end

  @doc """
  The Horde child spec for a `ConversationServer`. Built once here because
  the literal was written three times — `start_conversation/2`'s fresh
  clause above, `Wake.start_conversation_server/4` and the rehydrator's boot
  sweep (`Conversations.Rehydrator`) — and the three varied on exactly these
  three keys: `conversation_id`, `sandbox_id` and `runtime_module`. No
  prompt ever belongs here: `Horde.DynamicSupervisor` replays a child's
  *stored* spec on every redistribution (every deploy), so a prompt baked in
  would resend the user's last message on every rebalance
  (`prompt_replay_test.exs`). `extra` exists only for the rehydrator, which
  keeps its own explicit `initial_prompt: nil` — a note-to-self that the
  field was considered and deliberately left out, not an omission.
  """
  def child_spec(conversation_id, sandbox_id, runtime_module, extra \\ []) do
    {ConversationServer,
     [
       conversation_id: conversation_id,
       sandbox_id: sandbox_id,
       runtime_module: runtime_module
     ] ++ extra}
  end

  @doc """
  Like `start_conversation/2`, but a conversation already bound to
  `attrs["channel_id"]` is resumed instead of a new one being opened.

  The channel key is opaque and client-supplied — a Buzz channel id from ACP
  `session/new` `_meta.channelId` (#774). A client that forgets its sessions
  (a restarted `buzz-acp`) then lands back on the same conversation, and so
  the same sandbox and workspace, rather than opening a fresh one per restart.

  Resumes the **latest live** conversation for the same user + agent + vault
  + environment override + channel — `terminated` and `failed` ones are past
  resuming, so a new one is opened and becomes the binding. So is one whose
  *sandbox* is `terminated` or `failed` (#779): the machine is gone, and the
  workspace with it, so the channel gets a new conversation on a working one
  rather than a continuous-looking transcript on a blank disk. A `suspended`
  sandbox is parked, not gone, and still resumes. Returns `{:ok, conv,
  :resumed}` or `{:ok, conv, :created}`; without a `channel_id` it always
  creates.

  `attrs["fresh"]` (`true`) skips the resume this once: the conversation
  currently bound to the channel is unbound (its `channel_id` cleared — it
  keeps running, and the sandbox reaper retires it like any other idle one)
  and a new one is opened as the binding. It is how a chat harness relays its
  owner's `!rotate` — ACP `session/new` `_meta.freshSession` — through a
  binding that would otherwise hand the old conversation straight back.
  Unbinding, rather than relying on "newest wins", keeps the outcome
  independent of `inserted_at`'s one-second precision. Admission commits the
  old unbinding and the replacement together. A refused replacement preserves
  the old binding; a later startup/prompt failure restores it unless another
  rotation has already moved the binding. Concurrent rotations of the same
  binding return a channel validation error to the loser.

  Two concurrent first calls for one channel can both create; the next call
  resumes whichever is newer. Nothing is audited on the resume path unless
  `attrs["labels"]` actually changes something: it is the same conversation,
  so labels merge into the row it hands back (#1637) and that write records
  `conversation.labels_set` like any other.
  """
  def start_or_resume_conversation(attrs, opts \\ [])

  def start_or_resume_conversation(
        %{"channel_id" => channel_id, "agent_id" => agent_id, "user_id" => user_id} = attrs,
        opts
      )
      when is_binary(channel_id) and channel_id != "" do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         :ok <- Conversations.check_execution_limits(user_id, attrs["execution_limits"]),
         {:ok, vault_id} <- Conversations.resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <-
           Conversations.resolve_environment_id(attrs["environment_id"], user_id, agent),
         {:ok, set_id} <-
           Conversations.resolve_inference_credential_id(
             attrs["inference_credential_id"],
             user_id,
             agent
           ) do
      case find_channel_conversation(user_id, agent.id, vault_id, env_id, channel_id, set_id) do
        %Conversation{} = conv ->
          if fresh_requested?(attrs) do
            with {:ok, fresh} <-
                   Conversations.start_conversation(
                     attrs,
                     Keyword.put(opts, :rotate_from, conv.id)
                   ),
                 do: {:ok, fresh, :created}
          else
            with {:ok, conv} <- resume_channel(conv, agent, attrs, opts),
                 do: {:ok, conv, :resumed}
          end

        nil ->
          with {:ok, conv} <- Conversations.start_conversation(attrs, opts),
               do: {:ok, conv, :created}
      end
    end
  end

  def start_or_resume_conversation(attrs, opts) do
    with {:ok, conv} <- Conversations.start_conversation(attrs, opts), do: {:ok, conv, :created}
  end

  defp resume_channel(conv, agent, attrs, opts) do
    result =
      InferenceCredentials.with_source_lock(conv.user_id, fn ->
        Conversations.with_sandbox_lock(conv.sandbox_id, fn ->
          # Match turn admission and teardown: sandbox advisory lock, then
          # conversation row, then allowance. Taking the allowance first lets
          # narrowing hold the conversation while waiting on our allowance,
          # deadlocking the later label/source write. Codex reservation takes
          # the sandbox row only after this conversation lock too.
          current =
            Repo.one(
              from c in Conversation,
                where: c.id == ^conv.id and c.user_id == ^conv.user_id,
                lock: "FOR UPDATE",
                preload: [:sandbox, :agent, :vault, :agent_version]
            )

          # Ownership: `current` is the tenant-scoped `FOR UPDATE` read above.
          with %Conversation{} = current <- current || {:error, :not_found},
               :ok <-
                 if(current.sandbox_id == conv.sandbox_id,
                   do: :ok,
                   else: {:error, :provisioning}
                 ),
               :ok <- Conversations._unsafe_check_saved_execution_allowance(current.id),
               :ok <- check_sandbox_api_resume(current, attrs["sandbox_api_access"]),
               {:ok, source} <- Conversations.resolve_saved_inference(current, agent),
               {:ok, current, audit} <-
                 Conversations.resume_labels(current, attrs["labels"], opts),
               :ok <- InferenceBinding.reserve(current, source) do
            {:ok, {Repo.reload!(current), audit}}
          end
        end)
      end)

    with {:ok, {conv, audit}} <- result do
      Conversations.audit_labels(conv, audit, opts)
      {:ok, conv}
    end
  end

  defp check_sandbox_api_resume(_conv, nil), do: :ok
  defp check_sandbox_api_resume(%Conversation{sandbox_api_access: access}, access), do: :ok
  defp check_sandbox_api_resume(_conv, _access), do: {:error, :invalid_sandbox_api_access}

  # `true` or `"true"` — the ACP adapter sends a JSON boolean, a hand-built
  # request may send a string. Anything else is not a request.
  defp fresh_requested?(%{"fresh" => fresh}), do: fresh in [true, "true"]
  defp fresh_requested?(_attrs), do: false

  # The rotated-away conversation stops being the channel's binding. Nothing
  # else about it changes: if it is mid-turn it finishes, and it stays in the
  # user's list under its own id.
  defp unbind_channel(%Conversation{} = conv) do
    conv
    |> Ecto.Changeset.change(channel_id: nil)
    |> Repo.update()
  end

  # Inside admission's transaction, before the attachment's sandbox row lock.
  # Keep the selected conversation stable while replacing its binding; reject
  # a competing rotation that has already moved it.
  # Public for `Fountain.Conversations`, whose admission and
  # `fail_initial_start` call it until stages 7b/7c of #2175 move them here.
  def unbind_rotated_channel(attrs, opts) do
    case Keyword.get(opts, :rotate_from) do
      nil ->
        :ok

      id ->
        case lock_rotation_conversation(id, attrs) do
          %Conversation{channel_id: channel} = conv when channel == attrs.channel_id ->
            with {:ok, _} <- unbind_channel(conv), do: :ok

          :busy ->
            {:error, rotation_conflict("the previous conversation is busy; retry the rotation")}

          _ ->
            {:error, rotation_conflict("binding changed; retry the rotation")}
        end
    end
  end

  # Worker startup and attachment prompt delivery run after admission commits.
  # Restore only while this replacement still owns the binding; a later
  # rotation must win over this failure. Keep the old -> new row lock order.
  # Public for `Fountain.Conversations`, whose admission and
  # `fail_initial_start` call it until stages 7b/7c of #2175 move them here.
  def restore_rotated_channel(conv, opts) do
    case Keyword.get(opts, :rotate_from) do
      nil -> :ok
      id -> report_restore(conv, id, attempt_restore(conv, id))
    end
  end

  defp attempt_restore(conv, id) do
    Repo.transaction(fn ->
      with %Conversation{channel_id: nil} = previous <- lock_rotation_conversation(id, conv),
           %Conversation{channel_id: channel} = replacement
           when channel == conv.channel_id <- lock_rotation_conversation(conv.id, conv) do
        replacement |> Ecto.Changeset.change(channel_id: nil) |> Repo.update!()
        previous |> Ecto.Changeset.change(channel_id: channel) |> Repo.update!()
        :restored
      else
        # Contention on a row this compensation cannot wait for.
        :busy -> Repo.rollback(:busy)
        # A newer rotation already owns the binding, or the rows moved. That
        # rotation must win over this failure, so leaving them alone is right.
        _ -> :superseded
      end
    end)
  rescue
    e -> {:error, e}
  end

  defp report_restore(_conv, _id, {:ok, _outcome}), do: :ok

  # A compensation, not a rollback: nothing retries it and no caller can act on
  # it. Failing silently leaves a channel bound to nothing, which is the bug
  # this path exists to prevent wearing a different hat, so say so.
  defp report_restore(conv, id, other) do
    Logger.warning(
      "conv #{conv.id}: could not restore channel #{inspect(conv.channel_id)} to conv #{id} " <>
        "after a failed rotation: #{inspect(other)}"
    )

    :ok
  end

  defp rotation_conflict(message) do
    %Conversation{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:channel_id, message)
  end

  # How long a rotation may wait for the row it is replacing. On the fresh path
  # this runs inside `with_sandbox_reservation/3`, which holds the global fleet
  # advisory lock, and the row it wants is the one `_unsafe_create_turn_on_sandbox/3`
  # takes `FOR UPDATE` — so an unbounded wait would let one busy channel stall
  # provisioning for every tenant. Turn admission holds that row for a handful
  # of local queries, so this is orders of magnitude more than it ever
  # legitimately needs, and exceeding it means contention worth reporting
  # rather than waiting out.
  @rotation_lock_timeout_ms 250

  defp lock_rotation_conversation(id, attrs) do
    # Channel/ownership writes must serialize, but FK references may proceed.
    #
    # The bound is scoped to this read and handed straight back: `SET LOCAL`
    # lasts for the whole transaction, and admission goes on to insert rows
    # whose foreign keys take `KEY SHARE` on `users` — which a credit posting's
    # `FOR UPDATE` conflicts with. Leaving 250ms in force over those would turn
    # a slow billing write into an unrescued error on a path that has none.
    Repo.query!("SET LOCAL lock_timeout = '#{@rotation_lock_timeout_ms}ms'")

    conversation =
      from(c in Conversation,
        where: c.id == ^id and c.user_id == ^attrs.user_id and c.agent_id == ^attrs.agent_id,
        lock: "FOR NO KEY UPDATE"
      )
      |> where_vault(attrs.vault_id)
      |> where_environment(attrs.environment_id)
      |> Repo.one()

    Repo.query!("SET LOCAL lock_timeout = DEFAULT")
    conversation
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] == :lock_not_available do
        :busy
      else
        reraise(e, __STACKTRACE__)
      end
  end

  # The newest conversation still worth resuming for this binding. `vault_id`
  # is part of the key: two entries on one agent with different vaults are
  # different identities (#727) and must not share a conversation. So is the
  # environment override (#783): an identity that switches environments must
  # not resume a conversation provisioned from the old one.
  #
  # The sandbox is part of it too (#779): the 24 hour ceiling destroys a
  # sandbox while its conversation stays `idle`, and resuming that row wakes
  # onto a *fresh* machine with the workspace gone (#778 makes the turn work;
  # #936 is the memory it loses) inside a transcript that reads as continuous.
  # A channel is better served by a new conversation on a working machine, so
  # the binding follows the machine, not just the conversation row.
  # `suspended` is not in the list: that sandbox is parked, not gone, and its
  # disk wakes back up with the workspace on it.
  @doc """
  The conversation a channel binding resumes, resolved exactly as
  `start_or_resume_conversation/2` resolves it (same vault/environment/set selection),
  without opening one when there is none. For a request that must land on an
  existing conversation or fail — a tool answer on the bridge (#1202) — where
  opening a sandbox for a thread that has no parked call would be the wrong
  side effect. Tenant-scoped through `attrs["user_id"]`.
  """
  @spec channel_conversation(map()) :: Conversation.t() | nil
  def channel_conversation(
        %{"channel_id" => channel_id, "agent_id" => agent_id, "user_id" => user_id} = attrs
      )
      when is_binary(channel_id) and channel_id != "" do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id),
         {:ok, vault_id} <- Conversations.resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <-
           Conversations.resolve_environment_id(attrs["environment_id"], user_id, agent),
         {:ok, set_id} <-
           Conversations.resolve_inference_credential_id(
             attrs["inference_credential_id"],
             user_id,
             agent
           ) do
      find_channel_conversation(user_id, agent.id, vault_id, env_id, channel_id, set_id)
    else
      _ -> nil
    end
  end

  def channel_conversation(_attrs), do: nil

  defp find_channel_conversation(user_id, agent_id, vault_id, env_id, channel_id, set_id) do
    from(c in Conversation,
      join: s in assoc(c, :sandbox),
      where:
        c.user_id == ^user_id and c.agent_id == ^agent_id and c.channel_id == ^channel_id and
          c.status not in ["terminated", "failed"] and
          s.status not in ["terminated", "failed"],
      order_by: [desc: c.inserted_at],
      limit: 1
    )
    |> where_vault(vault_id)
    |> where_environment(env_id)
    |> where_credential_set(set_id)
    |> Repo.one()
  end

  # An explicit set is part of a channel selection. An omitted set resumes
  # the channel's durable source, even after the account's default changes.
  defp where_credential_set(query, nil), do: query

  defp where_credential_set(query, id),
    do: from(c in query, where: c.inference_credential_id == ^id)

  defp where_vault(query, nil), do: from(c in query, where: is_nil(c.vault_id))
  defp where_vault(query, vault_id), do: from(c in query, where: c.vault_id == ^vault_id)

  defp where_environment(query, nil), do: from(c in query, where: is_nil(c.environment_id))
  defp where_environment(query, id), do: from(c in query, where: c.environment_id == ^id)
end
