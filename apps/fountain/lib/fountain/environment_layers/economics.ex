defmodule Fountain.EnvironmentLayers.Economics do
  @moduledoc """
  Bounded, owner-scoped evidence for deciding before a filesystem probe.

  Three cold controls and three cache outcomes are required. A cache miss is
  never a cold control. Failures remain observations, including the entire cold
  retry after a failed restore. Thresholds are conservative policy choices, not
  estimates of a workload's future reuse or latency percentiles.
  """
  import Ecto.Query
  alias Fountain.{Audit, Crypto, Environments, Repo}
  alias Fountain.Environments.Environment
  alias Fountain.EnvironmentLayers.{EconomicsState, Store}

  @horizon 10
  @day 86_400
  @lease 1_800
  @actor [actor: "system:environment_layer_economics"]

  @doc false
  def prepare(ctx) do
    provider = Fountain.Conversations.sandbox_provider_atom(ctx.sandbox)

    if ctx.env && ctx.env.cache_enabled && provider == :sprites &&
         match?({:ok, _}, Store.identity()) do
      start(ctx.state.user_id, ctx.env, provider, inputs(ctx))
    else
      %{attempt: false, reason: "disabled_or_unavailable", evidence: %{}}
    end
  rescue
    _ -> %{attempt: false, reason: "policy_unavailable", evidence: %{}}
  end

  @doc false
  def inputs(ctx) do
    agent = ctx.agent && Fountain.Agents.get_agent(ctx.agent.id, ctx.state.user_id)
    vault = ctx.conv.vault_id && Fountain.Vaults.get_vault(ctx.conv.vault_id, ctx.state.user_id)

    revisions =
      if vault do
        Repo.all(
          from s in Fountain.Vaults.VaultSecret,
            where: s.vault_id == ^vault.id,
            order_by: s.id,
            select: {s.id, s.inference_revision}
        )
      else
        []
      end

    # Only persisted configuration and tenant secret revisions. No per-launch
    # broker vault, callback key, runtime session or credential material.
    {agent &&
       Map.take(agent, [
         :id,
         :updated_at,
         :skills,
         :mcp_servers,
         :runtime,
         :runtime_config,
         :model,
         :instructions
       ]), ctx.runtime, vault && vault.id, revisions}
  end

  @doc false
  def observe(decision, result, elapsed) do
    case result do
      {:ok, :provisioned, reached} ->
        observation(decision, reached, elapsed, true)

      {:error, reason, reached}
      when reason not in [:configuration_changed, :sandbox_reset_pending] ->
        observation(decision, reached, elapsed, false)

      {:error, reason} when reason not in [:configuration_changed, :sandbox_reset_pending] ->
        observation(decision, %{}, elapsed, false)

      _ ->
        abandon(decision)
    end
  rescue
    _ -> :ok
  end

  defp abandon(%{trial: trial} = decision) when not is_nil(trial) do
    Repo.update_all(
      from(s in EconomicsState,
        where:
          s.environment_id == ^decision.environment_id and s.user_id == ^decision.user_id and
            s.epoch == ^decision.epoch and s.trial == ^trial
      ),
      set: [trial: nil, trial_until: nil]
    )

    :ok
  end

  defp abandon(_), do: :ok

  defp observation(decision, reached, elapsed, success) do
    phases =
      Map.get(reached, :cache_observation, %{
        mode: if(decision.attempt, do: "fallback", else: "cold")
      })

    {_refs, restore} = Map.get(reached, :cache_restore) || {[], %{}}
    build_ms = build_cost(decision, restore[:build_id] || phases[:build_id])

    sample =
      Map.merge(
        phases,
        Map.take(restore, [
          :bytes,
          :probe_ms,
          :fetch_ms,
          :authenticate_extract_ms,
          :restore_ms,
          :fingerprint
        ])
      )

    sample =
      Map.merge(sample, %{
        success: success,
        total_ms: elapsed,
        build_ms: build_ms,
        remaining_ms:
          max(
            0,
            elapsed - (phases[:reusable_ms] || 0) - (phases[:boot_ms] || 0) -
              (sample[:restore_ms] || 0)
          )
      })

    finish(decision, sample)
  end

  defp build_cost(%{user_id: uid}, id) when is_binary(id) do
    # Diagnostics records all completed attempts; failed builder costs also count.
    costs = Fountain.EnvironmentLayers.Diagnostics.costs(uid, id)

    if costs != [] and Enum.all?(costs, &is_integer(&1["elapsed_ms"])),
      do: Enum.sum(Enum.map(costs, & &1["elapsed_ms"]))
  end

  defp build_cost(_, _), do: nil

  @doc "Start one launch observation. Unsupported/disabled caches never acquire a trial."
  def start(user_id, env, provider, inputs, opts \\ []) do
    with %Environment{cache_enabled: true} <- env,
         true <- provider == :sprites,
         {:ok, store} <- Store.identity(),
         %Environment{} = current <- Environments.get_environment(env.id, user_id),
         true <-
           current.cache_enabled and current.build_generation == env.build_generation and
             current.build_policy_revision == env.build_policy_revision,
         {:ok, key} <- Crypto.load_tenant_key(user_id) do
      platform = Keyword.get(opts, :platform, to_string(Application.spec(:fountain, :vsn)))

      cohort =
        digest(
          key,
          {current.build_generation, current.build_policy_revision, store, platform, provider,
           current.setup_script, inputs}
        )

      now = Keyword.get(opts, :now, DateTime.utc_now())
      reserve(current, cohort, now)
    else
      _ -> %{attempt: false, reason: "disabled_or_unavailable", evidence: %{}}
    end
  rescue
    _ -> %{attempt: false, reason: "policy_unavailable", evidence: %{}}
  end

  defp digest(key, value),
    do:
      :crypto.mac(:hmac, :sha256, key, :erlang.term_to_binary(value))
      |> Base.encode16(case: :lower)

  defp reserve(env, cohort, now) do
    {:ok, decision} =
      Repo.transaction(fn ->
        # The environment lock serializes both first-row insertion and trial admission.
        current =
          Repo.one!(
            from e in Environment,
              where: e.id == ^env.id and e.user_id == ^env.user_id,
              lock: "FOR NO KEY UPDATE"
          )

        if current.build_generation != env.build_generation or
             current.build_policy_revision != env.build_policy_revision or
             not current.cache_enabled,
           do: Repo.rollback(:obsolete)

        state =
          Repo.one(
            from s in EconomicsState,
              where: s.environment_id == ^env.id and s.user_id == ^env.user_id,
              lock: "FOR UPDATE"
          )

        state = reset_if_needed(state, env, cohort, now)

        {attempt, reason} =
          if building?(env) do
            {false, "build_in_progress"}
          else
            choose(state, now)
          end

        trial = if attempt and state.mode != "enabled", do: Ecto.UUID.generate()
        changes = [launches: state.launches + 1]

        changes =
          if trial,
            do: changes ++ [trial: trial, trial_until: DateTime.add(now, @lease)],
            else: changes

        state = state |> Ecto.Changeset.change(changes) |> Repo.update!()

        %{
          attempt: attempt,
          reason: reason,
          evidence: evidence(state),
          user_id: env.user_id,
          environment_id: env.id,
          generation: env.build_generation,
          policy_revision: env.build_policy_revision,
          cohort: cohort,
          epoch: state.epoch,
          trial: trial,
          observation: Ecto.UUID.generate()
        }
      end)

    Audit.record(%{
      user_id: env.user_id,
      action: "environment_layer.cache_decided",
      resource_type: "environment",
      resource_id: env.id,
      actor: Keyword.fetch!(@actor, :actor),
      metadata:
        Map.merge(decision.evidence, %{attempt: decision.attempt, reason: decision.reason})
    })

    decision
  end

  defp building?(env) do
    Repo.exists?(
      from b in Fountain.EnvironmentLayers.Build,
        where:
          b.user_id == ^env.user_id and b.environment_id == ^env.id and
            b.generation == ^env.build_generation and b.state in ["queued", "building"] and
            b.deadline_at > ^DateTime.utc_now()
    )
  end

  defp reset_if_needed(state, env, cohort, now) do
    reset =
      is_nil(state) or state.cohort != cohort or
        DateTime.diff(now, state.evaluated_at) >= @day or
        (state.mode == "suppressed" and state.launches >= 20)

    if reset do
      attrs = %{
        cohort: cohort,
        epoch: Ecto.UUID.generate(),
        samples: [],
        mode: "learning",
        launches: 0,
        trial: nil,
        trial_until: nil,
        evaluated_at: now
      }

      (state || %EconomicsState{environment_id: env.id, user_id: env.user_id})
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert_or_update!()
    else
      expire_trial(state, now)
    end
  end

  defp expire_trial(%{trial: trial, trial_until: until} = state, now) when not is_nil(trial) do
    if DateTime.compare(until, now) != :gt do
      sample = %{
        "id" => trial,
        "mode" => "fallback",
        "success" => false,
        "total_ms" => @lease * 1000,
        "reason" => "interrupted_trial"
      }

      persist_sample(state, sample, now)
    else
      state
    end
  end

  defp expire_trial(state, _), do: state

  defp choose(state, _now) do
    cold = controls(state.samples)

    cond do
      state.mode == "suppressed" -> {false, "not_economical"}
      length(cold) < 3 -> {false, "cold_control"}
      state.trial != nil -> {false, "trial_in_progress"}
      state.mode == "enabled" and rem(state.launches, 10) == 0 -> {false, "cold_control"}
      state.mode == "enabled" -> {true, "measured_savings"}
      true -> {true, "bounded_trial"}
    end
  end

  @doc "Persist a finalized launch; stale epochs and duplicate observations cannot train the policy."
  def finish(decision, sample, opts \\ [])

  def finish(%{environment_id: id, user_id: uid} = decision, sample, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    result =
      Repo.transaction(fn ->
        state =
          Repo.one(
            from s in EconomicsState,
              where: s.environment_id == ^id and s.user_id == ^uid,
              lock: "FOR UPDATE"
          )

        env = Environments.get_environment(id, uid)

        cond do
          is_nil(env) or not env.cache_enabled or env.build_generation != decision.generation or
              env.build_policy_revision != decision.policy_revision ->
            :obsolete

          is_nil(state) or state.epoch != decision.epoch or state.cohort != decision.cohort ->
            :obsolete

          Enum.any?(state.samples, &(&1["id"] == decision.observation)) ->
            :duplicate

          decision.trial != nil and state.trial != decision.trial ->
            :obsolete

          true ->
            sample = sanitize(sample) |> Map.put("id", decision.observation)
            state = persist_sample(state, sample, now, decision.trial != nil)
            {state.mode, evidence(state)}
        end
      end)

    case result do
      {:ok, {mode, evidence}} ->
        Audit.record(%{
          user_id: uid,
          action: "environment_layer.observed",
          resource_type: "environment",
          resource_id: id,
          actor: Keyword.fetch!(@actor, :actor),
          metadata: Map.put(evidence, :mode, mode)
        })

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  def finish(_, _, _), do: :ok

  defp sanitize(sample) do
    numeric = [
      :total_ms,
      :probe_ms,
      :fetch_ms,
      :authenticate_extract_ms,
      :restore_ms,
      :reusable_ms,
      :boot_ms,
      :remaining_ms,
      :bytes,
      :build_ms
    ]

    values =
      for key <- numeric,
          value = sample[key],
          is_integer(value) and value >= 0,
          into: %{},
          do: {to_string(key), min(value, 86_400_000_000)}

    mode =
      if sample[:mode] in ["cold", "warm", "miss", "fallback"],
        do: sample[:mode],
        else: "fallback"

    fingerprint = sample[:fingerprint]

    values =
      if is_binary(fingerprint) and Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint),
        do: Map.put(values, "fingerprint", fingerprint),
        else: values

    values
    |> Map.put("mode", mode)
    |> Map.put("success", sample[:success] == true)
    |> Map.put_new("total_ms", @lease * 1000)
  end

  defp persist_sample(state, sample, now, clear_trial \\ true) do
    samples = retain([sample | state.samples])

    changed =
      sample["fingerprint"] &&
        Enum.any?(state.samples, fn old ->
          old["fingerprint"] && old["fingerprint"] != sample["fingerprint"]
        end)

    samples = if changed, do: [], else: samples

    mode =
      if state.mode == "suppressed" and not changed,
        do: "suppressed",
        else: classify(samples, state.mode)

    changes = [samples: samples, mode: mode]

    changes =
      if changed,
        do: changes ++ [epoch: Ecto.UUID.generate(), trial: nil, trial_until: nil],
        else: changes

    changes = if clear_trial, do: changes ++ [trial: nil, trial_until: nil], else: changes

    changes =
      if mode != state.mode, do: changes ++ [launches: 0, evaluated_at: now], else: changes

    state |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  # Independent bounds preserve three cold controls during frequent warm reuse.
  defp retain(samples) do
    {kept, _} =
      Enum.reduce(samples, {[], %{}}, fn sample, {kept, counts} ->
        group =
          case sample["mode"] do
            "cold" -> :cold
            "miss" -> :miss
            _ -> :cache
          end

        count = Map.get(counts, group, 0)
        limit = if group == :cache, do: 12, else: 6

        if count < limit,
          do: {[sample | kept], Map.put(counts, group, count + 1)},
          else: {kept, counts}
      end)

    Enum.reverse(kept)
  end

  @doc false
  def classify(samples, previous) do
    cold = controls(samples)
    warm = cache_outcomes(samples)

    proven =
      Enum.count(warm, &(&1["mode"] == "warm" and &1["success"] and is_integer(&1["build_ms"])))

    cond do
      length(cold) < 3 ->
        if(length(samples) >= 6, do: "suppressed", else: "learning")

      proven < 3 ->
        if(Enum.count(samples, &(&1["mode"] != "cold")) >= 6, do: "suppressed", else: "learning")

      true ->
        baseline = median(cold)

        costs =
          Enum.map(warm, fn sample ->
            elapsed =
              if sample["mode"] == "fallback" or not sample["success"],
                do: max(sample["total_ms"], baseline),
                else: sample["total_ms"]

            elapsed + (sample["build_ms"] || @lease * 1000) / @horizon
          end)

        margin = if previous == "enabled", do: 0.10, else: 0.20

        if baseline - median(costs) >= max(5_000, baseline * margin),
          do: "enabled",
          else: "suppressed"
    end
  end

  defp controls(samples),
    do:
      samples
      |> Enum.filter(&(&1["mode"] == "cold" and &1["success"]))
      |> Enum.take(5)
      |> Enum.map(& &1["total_ms"])

  defp cache_outcomes(samples),
    do: samples |> Enum.filter(&(&1["mode"] in ["warm", "fallback"])) |> Enum.take(5)

  defp median(values), do: values |> Enum.sort() |> Enum.at(div(length(values), 2))

  defp median_or_nil([]), do: nil
  defp median_or_nil(values), do: median(values)

  defp evidence(state) do
    cold = controls(state.samples)
    warm = cache_outcomes(state.samples)

    %{
      cold_samples: length(cold),
      cache_samples: length(warm),
      failed_samples: Enum.count(state.samples, &(&1["success"] == false)),
      cold_ms: if(cold != [], do: median(cold)),
      cache_ms: if(warm != [], do: median(Enum.map(warm, & &1["total_ms"]))),
      build_ms:
        median_or_nil(for sample <- warm, is_integer(sample["build_ms"]), do: sample["build_ms"]),
      missing_build_cost: Enum.count(warm, &(not is_integer(&1["build_ms"]))),
      entry_margin_percent: 20,
      retention_margin_percent: 10,
      minimum_saving_ms: 5_000,
      amortization_hits: @horizon,
      observations: length(state.samples)
    }
  end
end
