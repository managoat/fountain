defmodule Fountain.Manifest do
  @moduledoc """
  Bulk apply for compiled IaC manifests (`fountain apply`).

  Takes the full list of resources the CLI compiled from a `fountain.yml`
  and reconciles them against the tenant's records in one pass, in a fixed
  order: environments, vaults, agents, teammates, schedules, webhooks. The
  order is what lets a document reference another by name regardless of
  where it sits in the file. An Agent's `environment`, a Teammate's `agent`,
  `environment` and `vault`, and a Schedule's `teammate` all resolve against
  the documents applied earlier in this manifest first, then against the
  tenant's existing records.

  Each kind has its own upsert key:

  | Kind | Key | Reconciled through |
  |---|---|---|
  | `Environment` | `name` | `Fountain.Environments` |
  | `Vault` | `name` | `Fountain.Vaults` |
  | `Agent` | `name` | `Fountain.Agents` |
  | `Teammate` | `name`, which names the agent's membership | `Fountain.Team` |
  | `Schedule` | `name`, under its `teammate` | `Fountain.Team.Schedules` |
  | `Webhook` | `spec.url` | `Fountain.Webhooks` |

  A teammate is one agent's membership of the team, so the document's `name`
  is what the teammate is called and the resolved `agent` is what it
  reconciles against. Re-applying a Teammate with a different `name` renames
  it rather than adding a second membership for the same agent, and two
  documents naming one agent are refused past the first: they describe one
  record, so without the refusal each pass would rename the other's
  conversation and no apply would ever be `unchanged`.

  A Teammate document is also the only one read as a whole declaration. On
  the other five an absent `spec` key leaves that column alone; on a Teammate
  an absent `environment` or `vault` clears the binding, back to the agent's
  own environment and no vault. Moving either id moves the teammate's
  computer, which `Fountain.Team.update_teammate/4` retires and refuses
  mid-turn (#1084).

  Application is best-effort per resource: a document that fails validation,
  that a context refuses, or that raises is reported in its own result entry
  and does not stop the rest of the manifest.

  Apply is additive. A document removed from the manifest leaves its record
  in place; there is no prune. A `Webhook` whose `spec.url` changes is a new
  endpoint for that reason, and the one the old URL named keeps delivering.
  """

  require Logger

  alias Fountain.{Agents, Crypto, Environments, Team, Vaults, Webhooks}
  alias Fountain.Team.Schedules

  @unexpected "apply failed unexpectedly; see the server log"

  @kinds ~w(Environment Vault Agent Teammate Schedule Webhook)

  def kinds, do: @kinds

  # Ownership/identity fields are never taken from a manifest spec; secrets
  # are split out and written through the envelope-encryption path instead.
  @stripped_keys ~w(id user_id created_by secrets)

  @doc """
  Apply `resources` (maps with `"kind"`, `"name"`, and `"spec"`) for `user_id`.

  Returns `{:ok, results}` with one result map per resource in apply order
  (the six kinds in the order above, then any malformed entries). Each result
  holds `:kind`, `:name`, an `:action` of `:created` / `:updated` /
  `:unchanged` / `:error`, changeset-style `:errors` when the action is
  `:error`, a `:secrets` list with the per-key upsert outcome, the
  reconciled record's `:id` (nil for errors), and `:secret`, which carries a
  webhook endpoint's signing secret on the apply that created it and is nil
  everywhere else.

  `:unchanged` means the record already matched the document, so nothing was
  written to it. Inline `spec.secrets` are re-encrypted on every apply and
  keep reporting `:upserted` in `:secrets`, whatever the row's own verdict
  says: the stored ciphertext cannot be compared with the plaintext given.
  """
  def apply_manifest(user_id, resources, opts \\ [])
      when is_binary(user_id) and is_list(resources) do
    {valid, invalid} = Enum.split_with(resources, &valid_resource?/1)
    groups = Enum.group_by(valid, & &1["kind"])
    envs = Map.get(groups, "Environment", [])
    vaults = Map.get(groups, "Vault", [])
    agents = Map.get(groups, "Agent", [])
    teammates = Map.get(groups, "Teammate", [])
    schedules = Map.get(groups, "Schedule", [])
    webhooks = Map.get(groups, "Webhook", [])

    dek = if Enum.any?(envs ++ vaults, &has_secrets?/1), do: load_dek!(user_id)

    {env_results, env_ids} =
      reconcile("Environment", envs, fn res, _claimed ->
        apply_environment(user_id, res, dek, opts)
      end)

    {vault_results, vault_ids} =
      reconcile("Vault", vaults, fn res, _claimed -> apply_vault(user_id, res, dek, opts) end)

    {agent_results, agent_ids} =
      reconcile("Agent", agents, fn res, _claimed -> apply_agent(user_id, res, env_ids, opts) end)

    refs = %{agents: agent_ids, environments: env_ids, vaults: vault_ids}

    {teammate_results, teammate_ids} =
      reconcile("Teammate", teammates, fn res, claimed ->
        apply_teammate(user_id, res, refs, claimed, opts)
      end)

    known_teammates = teammate_refs(user_id, schedules, teammate_ids)

    {schedule_results, _} =
      reconcile("Schedule", schedules, fn res, _claimed ->
        apply_schedule(user_id, res, known_teammates, opts)
      end)

    {webhook_results, _} =
      reconcile("Webhook", webhooks, fn res, _claimed -> apply_webhook(user_id, res, opts) end)

    results =
      env_results ++
        vault_results ++
        agent_results ++
        teammate_results ++
        schedule_results ++
        webhook_results ++
        Enum.map(invalid, &invalid_result/1)

    {:ok, results}
  end

  # One pass over one kind. Every `apply_*` returns `{result, id}`, so the
  # pass leaves behind the name → id map the next pass resolves against, and
  # hands each document the map built so far (which is how a second Teammate
  # naming an agent already claimed is caught).
  defp reconcile(kind, resources, fun) do
    Enum.map_reduce(resources, %{}, fn res, acc ->
      case guarded(kind, res["name"], fn -> fun.(res, acc) end) do
        {result, nil} -> {result, acc}
        {result, id} -> {result, Map.put(acc, res["name"], id)}
      end
    end)
  end

  # Best-effort per resource means per resource. The Teammate pass reaches
  # Horde, the sandbox quota lock, the credit gate and the sandbox provider,
  # and a raise or an exit there would abandon a call that has already
  # committed the environments, vaults and agents above it, leaving the caller
  # a 500 and no rows at all. Reported as this document's error instead, and
  # logged, because a crash in a context is still a defect worth a stacktrace.
  # The row says only that the pass failed. The exception text goes to the log
  # above and no further: this module promises that secret values are never
  # echoed back, and the environment and vault passes hold plaintext inside
  # this rescue, where Elixir's own MatchError, CaseClauseError, BadMapError
  # and ArgumentError messages embed the value they choked on. A caller who
  # needs the detail has an operator who can read the log.
  defp guarded(kind, name, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "apply: #{kind} #{inspect(name)} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {result(kind, str(name), :error, %{"base" => [@unexpected]}, []), nil}
  catch
    thrown, reason ->
      Logger.error("apply: #{kind} #{inspect(name)} #{thrown}: #{inspect(reason)}")

      {result(kind, str(name), :error, %{"base" => [@unexpected]}, []), nil}
  end

  # Keeps the `via: apply` marker the ApplyController used to attach when it
  # audited these itself. It is the one thing distinguishing a secret written
  # by `fountain apply` from the same key written through a form, and worth
  # keeping now that the context emits the event (#593).
  defp secret_opts(opts) do
    Keyword.update(opts, :metadata, %{"via" => "apply"}, &Map.put(&1, "via", "apply"))
  end

  # ── per-kind reconciliation ───────────────────────────────────────────────

  defp apply_environment(user_id, %{"name" => name} = res, dek, opts) do
    with :ok <- validate_spec(res, Environments.Environment, ~w(secrets)) do
      {attrs, secrets} = split_spec(res, name)
      existing = Environments.get_environment_by_name(name, user_id)

      outcome =
        if existing,
          do: Environments.update_environment(existing, attrs, opts),
          else: Environments.create_environment(Map.put(attrs, "user_id", user_id), opts)

      case outcome do
        {:ok, env} ->
          secret_results =
            upsert_secrets(secrets, &Environments.upsert_secret(env, &1, dek, secret_opts(opts)))

          {result("Environment", name, verdict(existing, env), nil, secret_results, env.id),
           env.id}

        {:error, changeset} ->
          {result("Environment", name, :error, changeset_errors(changeset), []), nil}
      end
    else
      {:error, errors} -> {result("Environment", name, :error, errors, []), nil}
    end
  end

  defp apply_vault(user_id, %{"name" => name} = res, dek, opts) do
    with :ok <- validate_spec(res, Vaults.Vault, ~w(secrets)) do
      {attrs, secrets} = split_spec(res, name)
      existing = Vaults.get_vault_by_name(name, user_id)

      outcome =
        if existing,
          do: Vaults.update_vault(existing, attrs, opts),
          else: Vaults.create_vault(Map.put(attrs, "user_id", user_id), opts)

      case outcome do
        {:ok, vault} ->
          secret_results =
            upsert_secrets(secrets, &Vaults.upsert_secret(vault, &1, dek, secret_opts(opts)))

          {result("Vault", name, verdict(existing, vault), nil, secret_results, vault.id),
           vault.id}

        {:error, changeset} ->
          {result("Vault", name, :error, changeset_errors(changeset), []), nil}
      end
    else
      {:error, errors} -> {result("Vault", name, :error, errors, []), nil}
    end
  end

  defp apply_agent(user_id, %{"name" => name} = res, env_ids, opts) do
    with :ok <- validate_spec(res, Agents.Agent, ~w(environment)),
         {attrs, _secrets} = split_spec(res, name),
         {env_ref, attrs} = Map.pop(attrs, "environment"),
         {:ok, env_id} <- resolve_ref("environment", user_id, env_ref, env_ids) do
      attrs = if env_id, do: Map.put(attrs, "environment_id", env_id), else: attrs
      existing = Agents.get_agent_by_name(name, user_id)

      outcome =
        if existing,
          do: Agents.update_agent(existing, attrs, opts),
          else: Agents.create_agent(Map.put(attrs, "user_id", user_id), opts)

      case outcome do
        {:ok, agent} ->
          {result("Agent", name, verdict(existing, agent), nil, [], agent.id), agent.id}

        # Moving the agent's environment rebuilds its machine, which a
        # running turn blocks (#1084). Reported against the field that
        # caused it so `fountain apply` says what to do about it.
        {:error, :sandbox_mid_turn} ->
          errors = %{
            "environment" => [
              "the agent is running a turn on its own machine; changing its " <>
                "environment rebuilds that machine — retry once the turn ends"
            ]
          }

          {result("Agent", name, :error, errors, []), nil}

        {:error, cs} ->
          {result("Agent", name, :error, changeset_errors(cs), []), nil}
      end
    else
      {:error, errors} -> {result("Agent", name, :error, errors, []), nil}
    end
  end

  # A Teammate is an agent on the team, so the agent reference is the record
  # this reconciles against and the document's name is what it is called.
  # Adding one opens the teammate's conversation, which provisions its
  # computer; re-applying only moves the name, environment and vault the next
  # computer is built from, and never provisions a second one.
  defp apply_teammate(user_id, %{"name" => name} = res, refs, claimed, opts) do
    spec = spec_of(res)

    with :ok <- validate_keys(res, ~w(name agent environment vault)),
         {:ok, agent_id} <- require_ref("agent", user_id, spec["agent"], refs.agents),
         :ok <- unclaimed(name, agent_id, claimed),
         {:ok, env_id} <-
           resolve_ref("environment", user_id, spec["environment"], refs.environments),
         {:ok, vault_id} <- resolve_ref("vault", user_id, spec["vault"], refs.vaults) do
      attrs = %{"name" => name, "environment_id" => env_id, "vault_id" => vault_id}
      reconcile_teammate(user_id, name, agent_id, attrs, opts)
    else
      {:error, errors} -> {result("Teammate", name, :error, errors, []), nil}
    end
  end

  # A teammate is one agent's membership of the team, so two documents naming
  # the same agent describe one record: without this the second renames the
  # first's conversation on every pass and the manifest is never idempotent.
  # Two documents sharing a name are refused for the same reason — a Schedule
  # naming that teammate could not say which one it meant.
  defp unclaimed(name, agent_id, claimed) do
    cond do
      Map.has_key?(claimed, name) ->
        {:error, %{"name" => ["is already used by another Teammate document"]}}

      agent_id in Map.values(claimed) ->
        {:error, %{"agent" => ["is already claimed by another Teammate document"]}}

      true ->
        :ok
    end
  end

  defp reconcile_teammate(user_id, name, agent_id, attrs, opts) do
    opts = Keyword.put_new(opts, :source, "api")

    case Team.get_teammate(user_id, agent_id) do
      nil ->
        case Team.add_teammate(user_id, agent_id, attrs, opts) do
          {:ok, conv} -> {result("Teammate", name, :created, nil, [], conv.id), agent_id}
          {:error, reason} -> {result("Teammate", name, :error, context_errors(reason), []), nil}
        end

      teammate ->
        # The teammate map is handed on rather than the agent id: listing the
        # roster is several queries and this call site has just done it.
        case Team.update_teammate(user_id, teammate, attrs, opts) do
          {:ok, conv, action} ->
            {result("Teammate", name, action, nil, [], conv.id), agent_id}

          {:error, reason} ->
            {result("Teammate", name, :error, context_errors(reason), []), nil}
        end
    end
  end

  defp apply_schedule(user_id, %{"name" => name} = res, known_teammates, opts) do
    spec = spec_of(res)

    with :ok <- validate_keys(res, ~w(name teammate cron prompt one_off enabled)),
         {:ok, agent_id} <- require_ref("teammate", user_id, spec["teammate"], known_teammates) do
      attrs =
        spec
        |> Map.drop(~w(teammate))
        |> Map.merge(%{"name" => name, "agent_id" => agent_id})

      reconcile_schedule(user_id, name, agent_id, attrs, opts)
    else
      {:error, errors} -> {result("Schedule", name, :error, errors, []), nil}
    end
  end

  defp reconcile_schedule(user_id, name, agent_id, attrs, opts) do
    existing =
      user_id |> Schedules.list_schedules(agent_id) |> Enum.find(&(&1.name == name))

    outcome =
      if existing,
        do: Schedules.update_schedule(existing, attrs, opts),
        else: Schedules.create_schedule(user_id, attrs, opts)

    case outcome do
      {:ok, schedule} ->
        {result("Schedule", name, verdict(existing, schedule), nil, [], schedule.id), nil}

      {:error, reason} ->
        {result("Schedule", name, :error, context_errors(reason), []), nil}
    end
  end

  # Keyed by `spec.url`: the endpoint the tenant already has for that URL is
  # the one this document describes. The document's name is a label, carried
  # into the result row so `fountain apply` prints something a reader picked.
  defp apply_webhook(user_id, %{"name" => name} = res, opts) do
    with :ok <- validate_keys(res, ~w(url description event_types)) do
      attrs = spec_of(res)
      existing = Enum.find(Webhooks.list_endpoints(user_id), &(&1.url == attrs["url"]))

      case reconcile_webhook(user_id, existing, attrs, opts) do
        {:ok, endpoint, secret} ->
          row =
            %{
              result("Webhook", name, verdict(existing, endpoint), nil, [], endpoint.id)
              | secret: secret
            }

          {row, nil}

        {:error, reason} ->
          {result("Webhook", name, :error, context_errors(reason), []), nil}
      end
    else
      {:error, errors} -> {result("Webhook", name, :error, errors, []), nil}
    end
  end

  # The signing secret comes back on creation only, exactly as
  # `POST /api/webhooks` gives it: an update has none to return.
  defp reconcile_webhook(user_id, nil, attrs, opts) do
    with {:ok, {endpoint, secret}} <- Webhooks.create_endpoint(user_id, attrs, opts),
         do: {:ok, endpoint, secret}
  end

  defp reconcile_webhook(_user_id, endpoint, attrs, opts) do
    with {:ok, updated} <- Webhooks.update_endpoint(endpoint, attrs, opts),
         do: {:ok, updated, nil}
  end

  # ── references ────────────────────────────────────────────────────────────

  # Resolve a `<field>: <name>` reference: documents applied earlier in this
  # manifest win, then the tenant's own records. A blank reference is no
  # reference, which is how an Agent with no environment or a Teammate with
  # no vault reads.
  defp resolve_ref(_field, _user_id, ref, _ids) when ref in [nil, ""], do: {:ok, nil}

  defp resolve_ref(field, user_id, ref, ids) when is_binary(ref) do
    case ids[ref] || tenant_ref(field, user_id, ref) do
      nil -> {:error, %{field => ["#{field} not found: #{ref}"]}}
      # Two teammates answer to this name, so the document does not say which
      # record it means. Guessing would bind a schedule to the wrong agent.
      :ambiguous -> {:error, %{field => ["#{field} name is not unique: #{ref}"]}}
      id -> {:ok, id}
    end
  end

  defp resolve_ref(field, _user_id, ref, _ids),
    do: {:error, %{field => ["#{field} not found: #{inspect(ref)}"]}}

  # The same, for a reference the document cannot do without.
  defp require_ref(field, _user_id, ref, _ids) when ref in [nil, ""],
    do: {:error, %{field => ["can't be blank"]}}

  defp require_ref(field, user_id, ref, ids), do: resolve_ref(field, user_id, ref, ids)

  defp tenant_ref("environment", user_id, name),
    do: id_of(Environments.get_environment_by_name(name, user_id))

  defp tenant_ref("vault", user_id, name), do: id_of(Vaults.get_vault_by_name(name, user_id))
  defp tenant_ref("agent", user_id, name), do: id_of(Agents.get_agent_by_name(name, user_id))
  defp tenant_ref("teammate", _user_id, _name), do: nil

  defp id_of(nil), do: nil
  defp id_of(record), do: record.id

  # The teammates a Schedule may name: the ones this manifest just reconciled,
  # over the ones the tenant already has. Skipped entirely when the manifest
  # holds no schedules, because listing the team is several queries.
  #
  # A teammate's name is its conversation's title, or its agent's name, and
  # neither is unique. A name two of the tenant's teammates answer to maps to
  # `:ambiguous` and fails the Schedule row that uses it; a name this manifest
  # reconciled is unique among the documents (`unclaimed/3`) and wins.
  defp teammate_refs(_user_id, [], teammate_ids), do: teammate_ids

  defp teammate_refs(user_id, _schedules, teammate_ids) do
    user_id
    |> Team.list_teammates()
    |> Enum.group_by(& &1.name, & &1.agent.id)
    |> Map.new(fn
      {name, [agent_id]} -> {name, agent_id}
      {name, _several} -> {name, :ambiguous}
    end)
    |> Map.merge(teammate_ids)
  end

  # ── secrets ───────────────────────────────────────────────────────────────

  defp upsert_secrets(secrets, upsert_fun) do
    secrets
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} ->
      case normalize_secret_value(value) do
        {:ok, plain} ->
          case upsert_fun.(%{"key" => key, "value" => plain}) do
            {:ok, _secret} -> %{key: key, action: :upserted, errors: nil}
            {:error, cs} -> %{key: key, action: :error, errors: changeset_errors(cs)}
          end

        :error ->
          %{key: key, action: :error, errors: %{"value" => ["must be a string"]}}
      end
    end)
  end

  defp normalize_secret_value(value) when is_binary(value), do: {:ok, value}

  defp normalize_secret_value(value) when is_number(value) or is_boolean(value),
    do: {:ok, to_string(value)}

  defp normalize_secret_value(_value), do: :error

  defp has_secrets?(%{"spec" => %{"secrets" => secrets}}) when is_map(secrets),
    do: map_size(secrets) > 0

  defp has_secrets?(_res), do: false

  defp load_dek!(user_id) do
    {:ok, dek} = Crypto.load_tenant_key(user_id)
    dek
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp valid_resource?(%{"kind" => kind, "name" => name} = res)
       when kind in @kinds and is_binary(name) and name != "" do
    case Map.get(res, "spec") do
      nil -> true
      spec when is_map(spec) -> true
      _other -> false
    end
  end

  defp valid_resource?(_res), do: false

  # Use the changeset's cast fields, not every database field: timestamps,
  # virtual counts and other read-only state must not look configurable.
  defp validate_spec(res, schema, extra_keys) do
    validate_keys(res, Enum.map(schema.cast_fields(), &Atom.to_string/1) ++ extra_keys)
  end

  # The kinds with no Ecto schema of their own behind the manifest document
  # (a Teammate is a conversation, a Webhook an endpoint) name their keys
  # here, so an unsupported key still fails before anything is written.
  defp validate_keys(res, allowed) do
    allowed = allowed ++ ~w(id user_id created_by)

    case Map.keys(res["spec"] || %{}) -- allowed do
      [] -> :ok
      keys -> {:error, Map.new(keys, &{&1, ["is not a supported spec key"]})}
    end
  end

  # The top-level resource name is authoritative — it is the upsert key, so
  # it overrides any `name` a spec happens to carry.
  defp split_spec(res, name) do
    spec = spec_of(res)

    secrets =
      case Map.get(res["spec"] || %{}, "secrets") do
        m when is_map(m) -> m
        _other -> %{}
      end

    {Map.put(spec, "name", name), secrets}
  end

  defp spec_of(%{"spec" => spec}) when is_map(spec), do: Map.drop(spec, @stripped_keys)
  defp spec_of(_res), do: %{}

  # The third verdict. A record the manifest did not move reads `unchanged`,
  # so a second apply of the same file says plainly that it wrote nothing.
  # Compared over the schema's own columns with the timestamps left out: an
  # Ecto update with no changes moves neither.
  defp verdict(nil, _updated), do: :created

  defp verdict(%mod{} = before, %mod{} = updated) do
    fields = mod.__schema__(:fields) -- [:inserted_at, :updated_at]

    if Map.take(before, fields) == Map.take(updated, fields), do: :unchanged, else: :updated
  end

  # `id` is the reconciled record's id when there is one. It is not serialized
  # in the API response; callers use it to attribute the secret writes this
  # manifest performed to a concrete resource in the audit trail (#530).
  # `secret` is a webhook endpoint's signing secret on the apply that minted
  # it, and nil on every other row and every later apply.
  defp result(kind, name, action, errors, secrets, id \\ nil) do
    %{
      kind: kind,
      name: name,
      action: action,
      errors: errors,
      secrets: secrets,
      id: id,
      secret: nil
    }
  end

  defp invalid_result(res) do
    errors = %{
      "resource" => ["must have kind (#{Enum.join(@kinds, " | ")}), name, and a map spec"]
    }

    result(str(res["kind"]), str(res["name"]), :error, errors, [])
  end

  defp str(value) when is_binary(value), do: value
  defp str(_value), do: ""

  # What a context refused with, as the per-field errors an apply row carries.
  # Every reason a Teammate or Schedule document can actually provoke is named
  # here, because `inspect/1` on a bare atom is not a sentence anyone acts on.
  defp context_errors(%Ecto.Changeset{} = changeset), do: changeset_errors(changeset)
  defp context_errors(:not_found), do: %{"agent" => ["is not the caller's"]}

  defp context_errors(:environment_not_found),
    do: %{"environment" => ["environment not found"]}

  defp context_errors(:environment_not_allowed),
    do: %{"environment" => ["is not allowed by the agent"]}

  defp context_errors(:vault_not_found), do: %{"vault" => ["vault not found"]}
  defp context_errors(:vault_not_allowed), do: %{"vault" => ["is not allowed by the agent"]}

  # The same hazard `Agent` reports, from the teammate's side: rebinding moves
  # the computer out from under a turn that is running on it.
  defp context_errors(:sandbox_mid_turn),
    do: %{
      "base" => [
        "the teammate is running a turn on its computer; changing its environment " <>
          "or vault rebuilds that computer, so retry once the turn ends"
      ]
    }

  # One live computer per (agent, environment, vault): the teammate cannot be
  # moved onto an identity that already has one, because its next wake would
  # build a second and the index refuses it. Named so the row says what to do.
  defp context_errors(:destination_home_occupied),
    do: %{
      "base" => [
        "this agent already has a computer on that environment and vault; " <>
          "reset or remove it before binding the teammate to them"
      ]
    }

  defp context_errors(:provisioning), do: %{"base" => ["the computer is still starting"]}
  defp context_errors(:busy), do: %{"base" => ["the teammate is running a turn"]}
  defp context_errors(:runner_offline), do: %{"base" => ["the teammate's machine is offline"]}
  defp context_errors(:fleet_full), do: %{"base" => ["the fleet is at capacity"]}

  defp context_errors({:sandbox_quota_exceeded, %{count: count, limit: limit}}),
    do: %{"base" => ["sandbox quota: #{count}/#{limit}"]}

  defp context_errors({:sandbox_not_attachable, status}),
    do: %{"base" => ["the teammate's computer is #{status}"]}

  defp context_errors({:sandbox_not_resettable, status}),
    do: %{"base" => ["the teammate's computer is #{status}"]}

  defp context_errors(other), do: %{"base" => [inspect(other)]}

  # String keys throughout. `traverse_errors/2` keys by field atom, while the
  # hand-built maps above key by string, and a caller reading a result row
  # should not have to know which branch produced it. The wire shape does not
  # change: JSON stringifies either one.
  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.new(fn {field, messages} -> {to_string(field), messages} end)
  end
end
