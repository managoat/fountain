defmodule Fountain.Credits.ChatGPTInferenceTest do
  # Platform credentials are deployment-wide application config and one DB row.
  use Fountain.DataCase, async: false

  alias Fountain.{Billing, Credits, InferenceCredentials, PlatformInference}
  alias Fountain.Conversations.TurnMachine
  alias Fountain.Credits.InferenceRates
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Workers.CreditPricer

  setup do
    keys = [:platform_anthropic_api_key, :platform_openai_api_key, :platform_gemini_api_key]
    previous = Enum.map(keys, &{&1, Application.get_env(:fountain, &1)})
    Enum.each(keys, &Application.delete_env(:fountain, &1))

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    # The grant is selected only on a brokered deployment.
    broker = [:broker_listen_port, :broker_proxy_url]
    previous_broker = Enum.map(broker, &{&1, Application.get_env(:fountain, &1)})

    on_exit(fn ->
      for {key, value} <- previous_broker do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")

    Fountain.ChatGPTFixtures.connect!()
    refute PlatformInference.enabled?()
    :ok
  end

  test "a grant-only turn is debited once and counted in daily spend; own credentials are not" do
    model = "openai/gpt-6-astra"
    user = insert_empty_user()
    {:ok, source, _} = InferenceCredentials.resolve(user.id, model, "codex", [])

    assert %Source{scope: :platform, kind: :codex_chatgpt_access_token} =
             source

    usage =
      TurnMachine.with_inference(%{"input" => 1_000_000, "output" => 0}, %{
        inference: source,
        model: model
      })

    agent = insert_agent(user_id: user.id, runtime: "codex", model: model)
    conv = insert_conversation(user_id: user.id, agent: agent)
    now = DateTime.utc_now()
    turn = insert_turn(conv, status: "completed", started_at: now, ended_at: now, usage: usage)
    before = Billing.platform_inference_spend_today(now)

    assert %{inference: 1} = CreditPricer.run(since: DateTime.add(now, -60), now: now)
    [entry] = Credits.list_entries(user.id) |> Enum.filter(&(&1.reason == "burn_inference"))
    cost = InferenceRates.cost_cents(usage)
    assert cost > 0
    assert entry.amount_cents == -cost
    assert entry.resource_id == turn.id
    assert entry.metadata["model"] == model
    assert Billing.platform_inference_spend_today(now) == before + cost

    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "tenant-key")

    {:ok, %Source{scope: :credential} = source, _} =
      InferenceCredentials.resolve(user.id, model, "codex", [])

    own_usage =
      TurnMachine.with_inference(%{"input" => 1_000_000}, %{inference: source, model: model})

    assert own_usage == %{"input" => 1_000_000}

    insert_turn(conv,
      turn_number: 2,
      status: "completed",
      started_at: now,
      ended_at: now,
      usage: own_usage
    )

    assert %{inference: 0} = CreditPricer.run(since: DateTime.add(now, -60), now: now)
    assert Billing.platform_inference_spend_today(now) == before + cost
  end

  # ADR 0060 decision 6: a user's own subscription is `"own"` inference. The
  # deployment sells platform inference here, so the stamp is written and the
  # pricer and the ceiling both have something to get wrong.
  @tag :capture_log
  test "a turn on a user's own subscription debits nothing and consumes no ceiling" do
    Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")
    previous_ceiling = Application.get_env(:fountain, :platform_inference_daily_cents)

    on_exit(fn ->
      if is_nil(previous_ceiling),
        do: Application.delete_env(:fountain, :platform_inference_daily_cents),
        else: Application.put_env(:fountain, :platform_inference_daily_cents, previous_ceiling)
    end)

    assert PlatformInference.enabled?()

    model = "openai/gpt-6-astra"
    user = insert_verified_user()
    # Outside its refresh margin: the gate below asks the auth server nothing.
    grant =
      Fountain.ChatGPTFixtures.user_grant!(user.id, %{
        access_token: Fountain.ChatGPTFixtures.access_token()
      })

    {:ok, set} = InferenceCredentials.create_set(user.id, "Subscription")
    {:ok, set} = InferenceCredentials.set_grant(set, grant.id)

    {:ok, %Source{scope: :grant} = source, _} =
      InferenceCredentials.resolve(user.id, model, "codex", credential_set_id: set.id)

    usage =
      TurnMachine.with_inference(%{"input" => 1_000_000, "output" => 1_000_000}, %{
        inference: source,
        model: model
      })

    # No model, which is what the rate card is read by, and no grant id.
    assert usage == %{"input" => 1_000_000, "output" => 1_000_000, "inference" => "own"}

    agent = insert_agent(user_id: user.id, runtime: "codex", model: model)
    conv = insert_conversation(user_id: user.id, agent: agent)
    now = DateTime.utc_now()

    insert_turn(conv,
      status: "completed",
      started_at: now,
      ended_at: now,
      usage: usage,
      inference_source: Source.dump(source)
    )

    balance = Credits.balance(user.id)
    spent = Billing.platform_inference_spend_today(now)

    assert %{inference: 0} = CreditPricer.run(since: DateTime.add(now, -60), now: now)
    assert Enum.filter(Credits.list_entries(user.id), &(&1.reason == "burn_inference")) == []
    assert Credits.balance(user.id) == balance
    assert Billing.platform_inference_spend_today(now) == spent

    # The ceiling spent: platform turns stop, and this one is not asked.
    Application.put_env(:fountain, :platform_inference_daily_cents, 0)

    assert {:error, :platform_inference_unavailable} =
             PlatformInference.gate_source(%{Source.platform() | kind: :openai_api_key})

    assert :ok = PlatformInference.gate_source(source)
    assert :ok = TurnMachine.gate(user.id, source)
  end
end
