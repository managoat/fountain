defmodule Fountain.Conversations.Reapply do
  @moduledoc """
  Re-selecting a conversation's Agent, Environment and Vault (#1565).

  A reapply keeps the conversation, its id, its transcript **and its machine**.
  What it changes is what the machine is configured with, on the machine that
  is already there. The disk survives, so an agent's cloned repositories,
  uncommitted work and build output are still where it left them.

  ## What updates in place, and what does not

  Most of a launch configuration is either process environment or a file, and
  both of those can be rewritten under a running sandbox. The reattach path
  has always done exactly this — `ConversationServer.do_reattach/6` rewrites
  `.mcp.json`, the `.env` file and the instructions on every wake — so this is
  an established mechanism rather than a new one.

  | Change | How it lands | Rebuild |
  |---|---|---|
  | Environment variables, Vault values | Respawn the runtime with fresh env | no |
  | System prompt, skills, MCP servers | Rewrite the files | no |
  | Model, permission policy | Per-turn arguments | no |
  | Runtime (claude to codex, say) | Adapter install | **yes** |
  | Packages, repositories, setup script | Install, clone, run | **yes** |
  | Network policy | Egress rules, written once at provision | **yes** |

  The rebuild rows are not stubbornness. The ACP adapter is an npm install
  that provisioning deliberately does *before* the network policy is applied,
  so installing a different one later fails in a way that reads as a protocol
  bug. `git clone` refuses a checkout that already exists, and a setup script
  that starts services fails on its second run, which is the same reason
  `Provisioning.discard_interrupted_attempt/3` exists.

  The network policy is the cautious one. `Egress.apply_policy/4` runs once,
  at provision, and nothing has ever re-run it against a live machine. Rather
  than assume it is idempotent and find out in production, a networking change
  is refused. Relaxing that is a one-line change to `fingerprint/1`, once
  somebody has shown the re-application is safe.

  One gap is worth naming. A skill whose source is a GitHub repository is a
  clone, and by the time a reapply runs the machine's network policy is
  already in force. Bundled skills are file writes and always land; a remote
  one may not, under a restrictive policy.

  So a reapply that needs either of those is refused, and says which field
  forced it. Start a new conversation for that, or build the machine under
  the conversation again with `DELETE /api/sandboxes/:id` (#1071).

  ## The cotenant rule

  Skills, the instructions file and `.mcp.json` sit at per-sandbox paths
  (`Managoat.Runtimes.Layout`), not per-conversation ones, so rewriting them
  rewrites them for every conversation on that machine. Sharing only happens
  on a persistent home or an explicit `sandbox_id` attach, and
  `Conversations.Launch.check_attachable/4` already pins every conversation on a
  machine to one `(user, agent, environment, vault)`. A conversation that has
  the machine to itself can therefore be reconfigured freely; one that shares
  it may only be reapplied to the selection its cotenants already have, which
  is what a refresh is. The context applies that rule and reports it as the
  `:shared_sandbox` blocker below.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Audit

  alias Fountain.Conversations.{
    Conversation,
    InferenceBinding,
    InferenceResolution,
    Sandbox,
    Turn
  }

  alias Fountain.Environments.Environment
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.{Conversations, Repo}

  @typedoc "Why a selection cannot be applied to the machine that is already there."
  @type blocker ::
          :runtime
          | :packages
          | :repositories
          | :setup_script
          | :networking
          | :environment
          | :missing_build_fingerprint
          | :shared_sandbox

  @doc """
  The digest of the Environment fields that provisioning turns into disk
  state. `nil` for no environment, which is itself a stable value to compare.

  Only the fields that shape the disk or the machine's network go in.
  Variables and the checkpoint are deliberately absent: a variable reaches a
  running machine on its next spawn, and the checkpoint only ever applies to a
  machine being built.
  """
  @spec fingerprint(Environment.t() | nil) :: String.t()
  def fingerprint(nil), do: "none"

  def fingerprint(%Environment{} = env) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {env.packages, env.repositories, env.setup_script, env.networking_type,
         env.networking_config}
      )
    )
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc """
  Whether the machine `sandbox` already is can be reconfigured into the
  requested selection, or the first reason it cannot.

  `:built_with` is the Environment the sandbox records, used to name a changed
  build field after the stored fingerprint proves the inputs differ. It is
  mutable and cannot establish what an older machine was built from. A machine
  with no recorded fingerprint requires an explicit rebuild.

  ## What the refusal can name

  A refusal carries the build field that forced it only when the selection
  moves to a *different* Environment, because naming the field means diffing
  the one the machine was built from against the one being asked for.

  A refresh of the same Environment, edited in place, is the case that cannot.
  Both sides are the same row read fresh, so every field compares equal however
  far the build inputs moved. The stored digest still catches the move — it was
  computed before the edit — but nothing left on the row says *which* input
  changed, so the refusal is the general `:environment`. Recovering the field
  there needs the digest to be per-field rather than one string, which is a
  column change and not worth it for the message alone.
  """
  @spec check(Sandbox.t() | nil, keyword()) :: :ok | {:error, {:rebuild_required, blocker()}}
  def check(nil, _opts), do: :ok

  def check(%Sandbox{} = sandbox, opts) do
    current_runtime = Keyword.fetch!(opts, :current_runtime)
    target_runtime = Keyword.fetch!(opts, :target_runtime)
    target_env = Keyword.fetch!(opts, :target_environment)
    built_with = Keyword.get(opts, :built_with)

    cond do
      target_runtime != current_runtime ->
        {:error, {:rebuild_required, :runtime}}

      is_nil(sandbox.build_fingerprint) ->
        {:error, {:rebuild_required, :missing_build_fingerprint}}

      sandbox.build_fingerprint == fingerprint(target_env) ->
        :ok

      true ->
        {:error, {:rebuild_required, build_field(built_with, target_env)}}
    end
  end

  # Which field to name in the refusal. Falls back to `:environment` in two
  # cases: the machine cannot say what it was built from, and both sides are
  # the same Environment row, which is what a refresh of one edited in place
  # looks like from here. See `check/2`.
  defp build_field(%Environment{} = was, %Environment{} = now) do
    cond do
      was.packages != now.packages -> :packages
      was.repositories != now.repositories -> :repositories
      was.setup_script != now.setup_script -> :setup_script
      was.networking_type != now.networking_type -> :networking
      was.networking_config != now.networking_config -> :networking
      true -> :environment
    end
  end

  defp build_field(_was, _now), do: :environment

  @doc """
  A sentence naming what forced a rebuild, for the API error and the log.
  """
  @spec explain(blocker()) :: String.t()
  def explain(:runtime),
    do:
      "the selected agent runs a different runtime, and the ACP adapter is installed " <>
        "before the network policy that would now block installing another"

  def explain(:packages), do: "the selected environment installs different packages"
  def explain(:repositories), do: "the selected environment clones different repositories"
  def explain(:setup_script), do: "the selected environment runs a different setup script"

  def explain(:networking),
    do:
      "the selected environment applies a different network policy, and the egress rules " <>
        "are written once, when the machine is built"

  def explain(:environment), do: "the selected environment builds the machine differently"

  def explain(:missing_build_fingerprint),
    do:
      "this machine has no recorded build fingerprint, so its original environment build " <>
        "inputs cannot be verified from the current environment"

  def explain(:shared_sandbox),
    do:
      "other conversations share this machine, and its skills, instructions and MCP " <>
        "configuration are per-machine rather than per-conversation"

  @doc """
  Move the machine's binding identity to the selection just committed.

  The identity is what `Conversations.Launch.check_attachable/4` matches a later
  attach against, so it has to follow the conversation rather than stay on
  the machine's original three. A persistent home is unique per identity, so
  a move onto one that already exists comes back as a changeset error on
  `:home` and rolls the whole reapply back: two homes for one identity is
  exactly what the partial index exists to prevent.

  `applied_skills` is carried forward, not replaced. It records what is on
  the disk now, which is what the skills reconciliation compares against; the
  newly selected skills only become the recorded set once they are actually
  installed. Older disks have no record, so the configuration the conversation
  was launched with stands in.
  """
  @spec update_identity(map(), map(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, Ecto.Changeset.t()}
  def update_identity(%{sandbox_id: nil}, _agent, _env_id, _vault_id), do: :ok

  def update_identity(conv, agent, env_id, vault_id) do
    # ownership: conv came from the tenant-scoped API fetch or its own server.
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    previous = sandbox.applied_skills || previous_skills(conv)

    case Conversations.update_sandbox(sandbox, %{
           agent_id: agent.id,
           environment_id: env_id || agent.environment_id,
           vault_id: vault_id,
           applied_skills: previous
         }) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  The skills the conversation's recorded Agent version named.

  The seed for a disk that predates the manifest: it is the selection that
  was installed when the machine was built, so it is the best available
  answer to "which entries under the skills root are ours". Missing history
  returns `nil`, not an empty selection: absence cannot establish ownership.
  """
  @spec previous_skills(map()) :: [map()] | nil
  def previous_skills(%{agent_version_id: nil}), do: nil

  def previous_skills(conv) do
    # The conversation's own version; ownership was checked at the API door.
    case Repo.one(
           from v in Fountain.Agents.AgentVersion,
             where: v.id == ^conv.agent_version_id and v.user_id == ^conv.user_id
         ) do
      nil -> nil
      version -> version.config["skills"] || []
    end
  end

  @doc """
  Reconcile the machine's skills with the conversation's current selection,
  then record what is now on it.

  Run on every wake, not only after a live reapply: a sleeping conversation
  whose selection changed applies it when it next comes up, and a machine
  built before the manifest existed gets one on its first pass. The recorded
  set is only advanced when the reconciliation succeeded, so a failed pass
  leaves the next one the same work rather than a wrong picture of the disk.
  """
  @spec mount_skills(Managoat.Sandbox.Handle.t(), map(), map() | nil) :: :ok | {:error, term()}
  def mount_skills(handle, conv, agent) do
    # ownership: conv came from the tenant-scoped API fetch or its own server.
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    skills = (agent && agent.skills) || []
    runtime = conv.runtime || (agent && agent.runtime) || "claude"

    with :ok <-
           Fountain.SandboxSkills.reconcile(
             handle,
             runtime,
             skills,
             sandbox.applied_skills || previous_skills(conv)
           ),
         {:ok, _} <- Conversations.update_sandbox(sandbox, %{applied_skills: skills}) do
      :ok
    end
  end

  @doc """
  Re-resolve the Agent, Environment and Vault for an existing conversation,
  on the machine it is already running (#1565).

  `conv` must come from `get_conversation/2`; the lookups below are
  tenant-scoped to that owner. An omitted field keeps its current selection,
  and an explicit nil clears the Environment override or the Vault. An empty
  map is therefore a refresh of what is already selected.

  The sandbox is kept. Environment variables, the system prompt, skills and
  MCP servers are what a later link of this stack rewrites under it;
  everything the agent has on disk survives either way.

  A selection that would need the disk built again is refused as
  `{:error, {:rebuild_required, field}}` rather than silently applied or
  silently ignored. `Fountain.Conversations.Reapply` owns that rule and says
  why for each field.

  ## What `{:ok, conv}` promises

  That the selection is committed, and that no turn can open against the
  previous one: `configuration_revision` moved, and turn admission compares it
  with the revision the live server loaded.

  It does not promise the running machine has already been reconfigured. A
  server is told after the commit, and it can be mid-provision or gone by then.
  Neither loses the change — the next wake builds from the row — so neither is
  a failure of this call, and reporting one would hand the caller an error for
  a selection that is already committed. The `configuration` stage event says
  which of the two happened: `done` when a machine is configured now, `failed`
  when it is selected and the machine has yet to catch up.
  """
  @spec reapply_conversation(Conversation.t(), map(), keyword()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def reapply_conversation(%Conversation{} = conv, attrs \\ %{}, opts \\ [])
      when is_map(attrs) do
    with {:ok, {previous, updated}} <-
           InferenceCredentials.with_source_lock(conv.user_id, fn ->
             Conversations.with_sandbox_lock(conv.sandbox_id, fn ->
               # Ownership was established by the caller. Re-read under the lock
               # so concurrent reapplications preserve each other's omitted
               # fields rather than each writing from a stale copy.
               current =
                 Repo.one!(from c in Conversation, where: c.id == ^conv.id, lock: "FOR UPDATE")

               if current.sandbox_id == conv.sandbox_id,
                 do: do_reapply_conversation(current, attrs),
                 else: {:error, :provisioning}
             end)
           end) do
      metadata = reapply_metadata(previous, updated)

      # Outside the transaction: a failed audit insert would abort the
      # enclosing one and take the reapply with it.
      Audit.record(%{
        user_id: updated.user_id,
        action: "conversation.configuration_reapplied",
        resource_type: "conversation",
        resource_id: updated.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: metadata
      })

      Conversations.broadcast_sidebar_update(updated.user_id)
      announce_reapply(updated, metadata)
      {:ok, updated}
    end
  end

  # The selection is committed by the time this runs, so it is not in doubt and
  # the caller is not told otherwise. What is still in doubt is whether a
  # machine has read it, and only `{:ok, :reloaded}` says one has. Everything
  # else — no server, no machine, a server that refused — leaves the selection
  # standing with nothing rewritten anywhere, which is the `failed` sentence
  # rather than a `done` that would claim a machine is configured.
  #
  # Best-effort as a whole: this runs after the commit, so neither the call nor
  # `publish_stage/4`'s own insert may take a reapply that already happened.
  defp announce_reapply(conv, metadata) do
    try do
      common = %{
        event: "reapplied",
        previous: metadata["previous"],
        current: metadata["current"],
        changed_fields: metadata["changed_fields"]
      }

      case Fountain.Conversations.ConversationServer.refresh_configuration(
             conv.id,
             conv.configuration_revision
           ) do
        {:ok, :reloaded} ->
          Conversations.publish_stage(
            conv.id,
            "configuration",
            "done",
            Map.put(
              common,
              :message,
              "The configuration was reapplied on this machine. The transcript and the " <>
                "files on disk are kept; the next prompt starts a new runtime session."
            )
          )

        # Total on purpose. This runs after the commit, so an unexpected shape
        # here must become an event rather than a CaseClauseError that 500s a
        # reapply which already happened.
        other ->
          Conversations.publish_stage(
            conv.id,
            "configuration",
            "failed",
            common
            |> Map.put(:reason, refresh_reason(other))
            |> Map.put(
              :message,
              "The configuration is selected. No machine has read it yet; it is " <>
                "applied when this conversation next wakes, and no turn can run " <>
                "against the previous selection in the meantime."
            )
          )
      end
    rescue
      error ->
        Logger.error(
          "conv #{conv.id}: announcing the reapplied configuration raised: " <>
            Exception.format(:error, error, __STACKTRACE__)
        )
    end

    :ok
  end

  defp refresh_reason({:ok, reason}), do: refresh_reason(reason)
  defp refresh_reason({:error, reason}), do: refresh_reason(reason)
  defp refresh_reason(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp refresh_reason(other), do: inspect(other)

  defp do_reapply_conversation(conv, attrs) do
    agent_id = reapply_value(attrs, "agent_id", conv.agent_id)
    vault_selection = reapply_value(attrs, "vault_id", conv.vault_id)
    environment_selection = reapply_value(attrs, "environment_id", conv.environment_id)

    with :ok <- assert_reapplicable(conv),
         {:ok, agent_id} <- reapply_agent_id(agent_id),
         %Fountain.Agents.Agent{} = agent <-
           Fountain.Agents.get_agent(agent_id, conv.user_id) || {:error, :not_found},
         {:ok, _runtime_module} <- Fountain.RuntimeDispatch.for_agent(agent),
         {:ok, _provider} <- Conversations.resolve_sandbox_provider(agent),
         {:ok, vault_id} <- Conversations.resolve_vault_id(vault_selection, conv.user_id, agent),
         {:ok, environment_id} <-
           Conversations.resolve_environment_id(environment_selection, conv.user_id, agent),
         {:ok, _permission_policy} <-
           Conversations.resolve_permission_policy(conv.permission_policy, agent),
         :ok <- assert_applicable_in_place(conv, agent, environment_id, vault_id),
         {:ok, inference_source} <-
           resolve_reapplied_inference(conv, agent, environment_id, vault_id),
         {:ok, updated} <-
           write_reapplied_configuration(conv,
             agent_id: agent.id,
             # Ownership: `agent` was fetched above by both id and conv.user_id.
             agent_version_id: Fountain.Agents._unsafe_current_version_id(agent.id),
             vault_id: vault_id,
             environment_id: environment_id,
             runtime: agent.runtime,
             inference_source: Source.dump(inference_source),
             configuration_revision: conv.configuration_revision + 1
           ),
         :ok <- update_identity(conv, agent, environment_id, vault_id),
         :ok <- reserve_reapplied_inference(updated, inference_source) do
      {:ok, {conv, updated}}
    end
  end

  # Reapply may change configuration context while retaining the admitted
  # credential. Compare the proposed context with the same pinned source; a
  # different credential still requires a new conversation. Historical turns
  # keep their original source snapshots.
  defp resolve_reapplied_inference(%{inference_source: nil}, _agent, _env_id, _vault_id),
    do: {:ok, nil}

  defp resolve_reapplied_inference(conv, agent, env_id, vault_id) do
    expected =
      Map.merge(conv.inference_source, %{
        "model" => agent.model,
        "runtime" => agent.runtime,
        "environment_id" => env_id || agent.environment_id,
        "vault_id" => vault_id
      })

    with {:ok, source, _credentials} <-
           InferenceResolution.revalidate(conv, agent,
             expected_source: expected,
             runtime: agent.runtime,
             environment_id: env_id || agent.environment_id,
             vault_id: vault_id
           ),
         :ok <- Fountain.PlatformInference.gate_source(source) do
      {:ok, source}
    end
  end

  defp reserve_reapplied_inference(_conv, nil), do: :ok
  defp reserve_reapplied_inference(conv, source), do: InferenceBinding.reserve(conv, source)

  # An omitted key keeps what the row already says; a key present with an
  # explicit nil clears it. Both spellings are accepted because the API hands
  # string keys through and the context's own callers use atoms.
  defp reapply_value(attrs, key, current) do
    atom_key = String.to_existing_atom(key)

    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, atom_key) -> Map.get(attrs, atom_key)
      true -> current
    end
  end

  # `conversations.agent_id` is `nilify_all`, so deleting an agent leaves the
  # conversation naming nothing and an omitted `agent_id` inherits that nil.
  # Ecto refuses to compare nil in a query, so the lookup would raise rather
  # than answer; refuse the way a wake does instead. An id that was supplied
  # and does not resolve is a different answer, and the lookup still gives it.
  defp reapply_agent_id(id) when is_binary(id), do: {:ok, id}
  defp reapply_agent_id(nil), do: {:error, :no_agent}
  defp reapply_agent_id(_other), do: {:error, :not_found}

  # Ownership: `conv` reached here from a tenant-scoped fetch, the sandbox is
  # its own, and the environments are looked up scoped to the same owner.
  defp assert_applicable_in_place(%Conversation{sandbox_id: nil}, _agent, _env_id, _vault_id),
    do: :ok

  defp assert_applicable_in_place(%Conversation{} = conv, agent, environment_id, vault_id) do
    sandbox = Conversations._unsafe_get_sandbox(conv.sandbox_id)
    target_environment_id = environment_id || agent.environment_id
    target_identity = {agent.id, target_environment_id, vault_id}

    with :ok <- assert_not_shared(sandbox, conv, target_identity) do
      check(sandbox,
        current_runtime: conv.runtime,
        target_runtime: agent.runtime,
        target_environment: environment_for(target_environment_id, conv.user_id),
        built_with: sandbox && environment_for(sandbox.environment_id, conv.user_id)
      )
    end
  end

  # Skills, instructions and MCP config live at per-machine paths, so
  # reconfiguring a shared machine reconfigures it for its cotenants too.
  # `Launch.check_attachable/4` pins every conversation on a machine to one identity,
  # so a selection that still matches theirs is the refresh they would want
  # anyway. Anything else is refused rather than imposed on them.
  # Ownership: `conv` is the tenant-scoped row the caller fetched and
  # `sandbox` is its own machine, read above.
  defp assert_not_shared(nil, _conv, _target), do: :ok

  defp assert_not_shared(%Sandbox{} = sandbox, conv, target) do
    if Conversations._unsafe_sandbox_held_by_other?(sandbox.id, conv.id) and
         {sandbox.agent_id, sandbox.environment_id, sandbox.vault_id} != target do
      {:error, {:rebuild_required, :shared_sandbox}}
    else
      :ok
    end
  end

  defp environment_for(nil, _user_id), do: nil
  defp environment_for(id, user_id), do: Fountain.Environments.get_environment(id, user_id)

  # A prompt that arrives between the checks above and this write would wake
  # the conversation and start a turn on the configuration being replaced.
  # One guarded statement: the row moves only while no turn runs, and a caller
  # that lost the race is told it is busy rather than silently overwritten.
  defp write_reapplied_configuration(%Conversation{} = conv, fields) do
    running_turn =
      from(t in Turn,
        where: t.conversation_id == parent_as(:conv).id and t.status == "running",
        select: 1
      )

    fields = Keyword.put(fields, :updated_at, DateTime.utc_now() |> DateTime.truncate(:second))

    {count, _} =
      from(c in Conversation, as: :conv, where: c.id == ^conv.id and not exists(running_turn))
      |> Repo.update_all(set: fields)

    # Ownership: the row just written is `conv`, the caller's scoped fetch.
    if count == 1,
      do: {:ok, Conversations._unsafe_get_conversation!(conv.id)},
      else: {:error, :conversation_busy}
  end

  defp assert_reapplicable(%Conversation{status: "idle", id: id}),
    do: assert_no_running_turn(id)

  defp assert_reapplicable(%Conversation{status: "running"}),
    do: {:error, :conversation_busy}

  # A conversation created without a prompt never leaves `pending`: provision
  # success flips the *sandbox* row, and only a turn ending writes `idle`. So
  # refusing every `pending` row would put "I picked the wrong agent before I
  # sent anything" permanently out of reach, behind a Retry-After that never
  # cleared. A provision genuinely in flight is still a retry.
  defp assert_reapplicable(%Conversation{status: "pending"} = conv) do
    if reapply_provision_in_flight?(conv),
      do: {:error, :provisioning},
      else: assert_no_running_turn(conv.id)
  end

  defp assert_reapplicable(%Conversation{status: status}) when status in ~w(failed terminated),
    do: {:error, :gone}

  # Ownership: `conv` reached here from a tenant-scoped fetch, and the row
  # read below is its own machine.
  defp reapply_provision_in_flight?(%Conversation{sandbox_id: nil}), do: false

  defp reapply_provision_in_flight?(%Conversation{sandbox_id: sandbox_id}) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      %Sandbox{status: status} when status in ["pending", "starting"] -> true
      _ -> false
    end
  end

  defp assert_no_running_turn(conversation_id) do
    if Repo.exists?(
         from t in Turn,
           where: t.conversation_id == ^conversation_id and t.status == "running"
       ) do
      {:error, :conversation_busy}
    else
      :ok
    end
  end

  # Names what moved, never a value: these are the conversation's own
  # references to tenant resources, which is what "which selection" means.
  defp reapply_metadata(previous, current) do
    fields = [:agent_id, :agent_version_id, :environment_id, :vault_id, :runtime]

    changed =
      fields
      |> Enum.filter(fn field -> Map.get(previous, field) != Map.get(current, field) end)
      |> Enum.map(&Atom.to_string/1)

    %{
      "changed_fields" => changed,
      "previous" => reapply_selection(previous),
      "current" => reapply_selection(current),
      "configuration_revision" => current.configuration_revision
    }
  end

  defp reapply_selection(conv) do
    %{
      "agent_id" => conv.agent_id,
      "agent_version_id" => conv.agent_version_id,
      "environment_id" => conv.environment_id,
      "vault_id" => conv.vault_id
    }
  end
end
