defmodule Fountain.EnvironmentLayers.EconomicsTest do
  use Fountain.DataCase, async: true
  use Mimic
  alias Fountain.EnvironmentLayers.{Economics, EconomicsState, Store}

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id, cache_enabled: true)
    stub(Store, :identity, fn -> {:ok, "private-store"} end)
    %{user: user, env: env}
  end

  defp decision(c, opts \\ []),
    do: Economics.start(c.user.id, c.env, :sprites, :same_inputs, opts)

  defp state(c), do: Repo.get_by!(EconomicsState, environment_id: c.env.id, user_id: c.user.id)

  defp sample(mode, ms, extra \\ %{}),
    do: Map.merge(%{mode: mode, total_ms: ms, success: true, build_ms: 500_000}, extra)

  defp train(c, mode, ms, count) do
    for _ <- 1..count do
      d = decision(c)
      assert d.attempt == (mode != "cold")
      Economics.finish(d, sample(mode, ms))
    end
  end

  test "three bypassed cold controls precede bounded trials; cheap cache is suppressed", c do
    train(c, "cold", 6_000, 3)
    train(c, "warm", 59_000, 3)

    assert %{
             attempt: false,
             reason: "not_economical",
             evidence: %{cold_ms: 6_000, cache_ms: 59_000}
           } = decision(c)

    assert state(c).mode == "suppressed"
  end

  test "beneficial cache stays enabled across fifty launches and retained cold controls", c do
    train(c, "cold", 300_000, 3)
    train(c, "warm", 170_000, 3)
    assert state(c).mode == "enabled"

    for _ <- 1..50 do
      d = decision(c)

      Economics.finish(
        d,
        if(d.attempt, do: sample("warm", 170_000), else: sample("cold", 300_000))
      )

      assert state(c).mode == "enabled"
    end

    assert length(state(c).samples) <= 24
    control = decision(c)
    refute control.attempt
    Economics.finish(control, sample("cold", 300_000))
    a = decision(c)
    b = decision(c)
    assert a.attempt and b.attempt
    assert is_nil(a.trial) and is_nil(b.trial)
  end

  test "one slow transfer does not oscillate; sustained losses suppress", c do
    train(c, "cold", 300_000, 3)
    train(c, "warm", 170_000, 3)
    d = decision(c)
    Economics.finish(d, sample("cold", 300_000))
    d = decision(c)
    Economics.finish(d, sample("warm", 500_000))
    assert state(c).mode == "enabled"

    for _ <- 1..2 do
      d = decision(c)
      Economics.finish(d, sample("warm", 500_000))
    end

    assert state(c).mode == "suppressed"
  end

  test "miss is not a baseline and fast failures never establish savings", c do
    train(c, "cold", 300_000, 3)

    for _ <- 1..6 do
      d = decision(c)
      assert d.attempt
      Economics.finish(d, sample("fallback", 1, %{success: false, build_ms: 0}))
    end

    assert state(c).mode == "suppressed"
    assert decision(c).evidence.failed_samples == 6
    assert decision(c).evidence.cold_samples == 3
  end

  test "failed cold controls have bounded acquisition and remain evidence", c do
    for _ <- 1..6, do: Economics.finish(decision(c), sample("cold", 1_000, %{success: false}))
    assert state(c).mode == "suppressed"
    assert decision(c).evidence.failed_samples == 6
  end

  test "one exploratory lease, abandoned launch clears it, killed launch expires", c do
    train(c, "cold", 300_000, 3)
    first = decision(c)
    assert first.attempt
    assert %{attempt: false, reason: "trial_in_progress"} = decision(c)
    Economics.observe(first, {:ok, :claimed_elsewhere}, 1)
    next = decision(c)
    assert next.attempt
    later = DateTime.add(DateTime.utc_now(), 1801)
    newest = decision(c, now: later)
    assert newest.attempt
    assert newest.evidence.failed_samples == 1
    Economics.finish(next, sample("warm", 1))
    refute Enum.any?(state(c).samples, &(&1["id"] == next.observation))
  end

  test "cohort/platform changes and explicit disable fence stale completions", c do
    old = decision(c)
    current = Economics.start(c.user.id, c.env, :sprites, :other_inputs, platform: "next")
    Economics.finish(old, sample("cold", 300_000))
    assert state(c).samples == []
    Economics.finish(current, sample("cold", 300_000))
    assert length(state(c).samples) == 1
    updated = c.env |> Ecto.Changeset.change(cache_enabled: false) |> Repo.update!()
    Economics.finish(current, sample("warm", 1))
    refute Economics.start(c.user.id, updated, :sprites, :other_inputs).attempt
    assert length(state(c).samples) == 1
  end

  test "owner isolation and unavailable storage do not train or attempt", c do
    refute Economics.start(Ecto.UUID.generate(), c.env, :sprites, :same_inputs).attempt
    refute Repo.get_by(EconomicsState, environment_id: c.env.id)
    stub(Store, :identity, fn -> {:error, :unconfigured} end)
    refute decision(c).attempt
    refute Repo.get_by(EconomicsState, environment_id: c.env.id)
  end

  test "suppression expires after bounded launches or elapsed time", c do
    train(c, "cold", 6_000, 3)
    train(c, "warm", 59_000, 3)
    for _ <- 1..20, do: assert(decision(c).reason == "not_economical")
    assert decision(c).reason == "cold_control"
    assert state(c).samples == []
    Economics.finish(decision(c), sample("cold", 6_000))
    assert decision(c, now: DateTime.add(DateTime.utc_now(), 86_401)).reason == "cold_control"
    assert state(c).samples == []
  end

  test "observation only stores bounded typed measurements, never supplied reason/output", c do
    d = decision(c)

    Economics.finish(d, %{
      mode: %{secret: "never"},
      success: "yes",
      total_ms: -1,
      bytes: String.duplicate("secret", 100),
      reason: "https://signed-secret",
      output: "private"
    })

    [saved] = state(c).samples
    assert saved["mode"] == "fallback"
    assert saved["success"] == false
    assert saved["total_ms"] == 1_800_000
    refute Map.has_key?(saved, "bytes")
    refute inspect(saved) =~ "secret"
    refute inspect(saved) =~ "private"
  end

  test "disabled preparation does not read cohort inputs" do
    # Deliberately no user, conversation or agent: computing inputs would fail.
    assert %{attempt: false, reason: "disabled_or_unavailable"} =
             Economics.prepare(%{
               env: %{cache_enabled: false},
               sandbox: %{provider: "sprites"}
             })

    assert %{attempt: false, reason: "disabled_or_unavailable"} =
             Economics.prepare(%{
               env: nil,
               sandbox: %{provider: "sprites"}
             })
  end

  test "queued builds bypass probing without exhausting exploration budget", c do
    train(c, "cold", 300_000, 3)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Fountain.EnvironmentLayers.Build{
      user_id: c.user.id,
      environment_id: c.env.id,
      owner_ref: c.user.id,
      environment_ref: c.env.id,
      generation: c.env.build_generation,
      policy_revision: c.env.build_policy_revision,
      state: "queued",
      fingerprint: "test",
      store_ref: "private-store",
      binding: %{},
      revisions: [],
      deadline_at: DateTime.add(now, 900),
      expires_at: DateTime.add(now, 86_400),
      cleanup_after: DateTime.add(now, 1800)
    })

    for _ <- 1..8 do
      d = decision(c)
      assert %{attempt: false, reason: "build_in_progress"} = d
      Economics.finish(d, sample("cold", 300_000))
    end

    assert state(c).mode == "learning"
    assert decision(c).evidence.cache_samples == 0
  end

  test "new artifact fingerprint resets epoch and rejects concurrent older completions", c do
    train(c, "cold", 300_000, 3)

    for _ <- 1..3 do
      Economics.finish(
        decision(c),
        sample("warm", 170_000, %{fingerprint: String.duplicate("a", 64)})
      )
    end

    control = decision(c)
    Economics.finish(control, sample("cold", 300_000))
    a = decision(c)
    b = decision(c)
    Economics.finish(a, sample("warm", 170_000, %{fingerprint: String.duplicate("b", 64)}))
    assert state(c).epoch != a.epoch
    assert state(c).samples == []
    Economics.finish(b, sample("warm", 170_000, %{fingerprint: String.duplicate("a", 64)}))
    assert state(c).samples == []
    assert decision(c).reason == "cold_control"
  end

  test "full fallback elapsed and build costs are charged without double-counting phases", c do
    train(c, "cold", 300_000, 3)
    d = decision(c)
    id = Ecto.UUID.generate()

    expect(Fountain.EnvironmentLayers.Diagnostics, :costs, fn uid, ^id ->
      assert uid == c.user.id
      [%{"status" => "failed", "elapsed_ms" => 200}, %{"status" => "ok", "elapsed_ms" => 800}]
    end)

    Economics.observe(
      d,
      {:ok, :provisioned,
       %{
         cache_observation: %{
           mode: "fallback",
           restore_ms: 400,
           reusable_ms: 500,
           boot_ms: 100,
           build_id: id
         }
       }},
      1200
    )

    [saved | _] = state(c).samples
    assert saved["total_ms"] == 1200
    assert saved["build_ms"] == 1000
    assert saved["remaining_ms"] == 200
    assert saved["mode"] == "fallback"
    assert decision(c).evidence.cold_samples == 3
  end

  test "provider failures are recorded and release exploration immediately", c do
    train(c, "cold", 300_000, 3)
    d = decision(c)
    Economics.observe(d, {:error, :create_failed}, 50)
    assert state(c).trial == nil
    [sample | _] = state(c).samples
    assert sample["success"] == false
    assert sample["mode"] == "fallback"
    assert sample["total_ms"] == 50
    assert decision(c).attempt
  end

  test "build amortization and hysteresis use explicit margins" do
    cold = List.duplicate(%{"mode" => "cold", "total_ms" => 300_000, "success" => true}, 3)

    warm =
      List.duplicate(
        %{"mode" => "warm", "total_ms" => 200_000, "success" => true, "build_ms" => 500_000},
        3
      )

    assert Economics.classify(warm ++ cold, "learning") == "suppressed"
    assert Economics.classify(warm ++ cold, "enabled") == "enabled"
    unknown = Enum.map(warm, &Map.delete(&1, "build_ms"))
    refute Economics.classify(unknown ++ cold, "learning") == "enabled"
  end
end
