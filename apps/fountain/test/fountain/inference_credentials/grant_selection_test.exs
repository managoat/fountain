defmodule Fountain.InferenceCredentials.GrantSelectionTest do
  @moduledoc """
  ADR 0060 stage 2: a credential set names a ChatGPT subscription, and a
  codex run on that set resolves to it or to an error that names it.

  The rule under test is decision 4, "nothing switches for you". Every
  refusal here is made with everything the resolver could have fallen back
  to in place and usable: the deployment's own ChatGPT grant, a platform
  OpenAI key, the set's own `openai_api_key`, an `OPENAI_API_KEY` in the
  environment and in the vault, and another active grant of the same user.

  `async: false`: the platform row is connected for every test, and the
  broker and platform key are application env.
  """

  use Fountain.DataCase, async: false

  import Fountain.ChatGPTFixtures

  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.Reserved
  alias Fountain.Conversations.InferenceResolution
  alias Fountain.Crypto
  alias Fountain.Environments
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.Vaults

  @codex_model "openai/gpt-5.3-codex"

  setup do
    restore =
      for key <- [:broker_listen_port, :broker_proxy_url, :platform_openai_api_key],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- restore do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")

    user = insert_active_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    platform = connect!()
    %{user: user, dek: dek, platform: platform}
  end

  defp set_naming(user, name, grant) do
    {:ok, set} = InferenceCredentials.create_set(user.id, name)
    {:ok, set} = InferenceCredentials.set_grant(set, grant.id)
    set
  end

  defp resolve(user, set, opts \\ []) do
    InferenceCredentials.resolve(
      user.id,
      Keyword.get(opts, :model, @codex_model),
      Keyword.get(opts, :runtime, "codex"),
      [credential_set_id: set && set.id] ++ Keyword.take(opts, [:environment_id, :vault_id])
    )
  end

  defp alter(grant, fields),
    do: Repo.update_all(from(a in Account, where: a.id == ^grant.id), set: fields)

  # Everything decision 4 says is not used, in place and usable: the platform
  # grant and key are in `setup`; this adds the set's own key, a second
  # active grant, and a key in an environment and in a vault.
  defp every_fallback(ctx, set) do
    {:ok, _} = InferenceCredentials.put_credential_in(set, ctx.dek, :openai_api_key, "sk-set-own")
    other = user_grant!(ctx.user.id, %{name: "The other subscription"})
    env = insert_env(user_id: ctx.user.id, env_vars: %{"OPENAI_API_KEY" => "sk-env-plain"})
    vault = insert_vault(user_id: ctx.user.id)

    {:ok, _} =
      Vaults.upsert_secret(vault, %{"key" => "OPENAI_API_KEY", "value" => "sk-vault"}, ctx.dek)

    {:ok, _} =
      Environments.upsert_secret(env, %{"key" => "OPENAI_API_KEY", "value" => "sk-env"}, ctx.dek)

    %{other: other, opts: [environment_id: env.id, vault_id: vault.id]}
  end

  describe "two sets of one user" do
    test "an agent on set A and an agent on set B resolve to different grants", ctx do
      work = user_grant!(ctx.user.id, %{name: "Work"})
      personal = user_grant!(ctx.user.id, %{name: "Personal"})
      set_a = set_naming(ctx.user, "A", work)
      set_b = set_naming(ctx.user, "B", personal)

      agent_a =
        insert_agent(user_id: ctx.user.id, runtime: "codex", inference_credential_id: set_a.id)

      agent_b =
        insert_agent(user_id: ctx.user.id, runtime: "codex", inference_credential_id: set_b.id)

      assert {:ok, %Source{} = a, creds_a} = InferenceResolution.select(ctx.user.id, agent_a, [])
      assert {:ok, %Source{} = b, creds_b} = InferenceResolution.select(ctx.user.id, agent_b, [])

      assert %Source{scope: :grant, kind: :codex_chatgpt_access_token, set_id: set_a_id} = a
      assert set_a_id == set_a.id
      assert {a.grant_id, a.generation} == {work.id, work.generation}
      assert {a.identity, a.revision} == {"chatgpt_grant:" <> work.id, work.generation}

      assert b.scope == :grant and b.set_id == set_b.id
      assert {b.grant_id, b.generation} == {personal.id, personal.generation}
      assert {b.identity, b.revision} == {"chatgpt_grant:" <> personal.id, personal.generation}

      refute a.grant_id == b.grant_id
      refute Source.dump(a) == Source.dump(b)

      # The user's own subscription: never the platform's bill or ceiling.
      for source <- [a, b] do
        refute Source.platform?(source)
        assert Source.origin(source) == "own"
        assert Source.dump(source)["origin"] == "own"
        assert :ok = Fountain.PlatformInference.gate_source(source)
      end

      # No bearer travels in the credentials map, and no key beside the grant:
      # what stands there is each grant's own placeholder (stage 3), which is
      # what its `auth.json` names and is not a secret.
      assert creds_a == %{codex_chatgpt_access_token: Reserved.placeholder(work.id)}
      assert creds_b == %{codex_chatgpt_access_token: Reserved.placeholder(personal.id)}
      refute creds_a == creds_b

      assert Source.grant_ref(a) == {:user, work.id, work.generation}
      assert :ok = InferenceCredentials.validate_source(ctx.user.id, a)
      assert :ok = InferenceCredentials.validate_source(ctx.user.id, b)
    end

    test "the account default naming a grant serves an agent that names no set", ctx do
      grant = user_grant!(ctx.user.id)
      default = set_naming(ctx.user, "Default", grant)
      assert default.is_default

      assert {:ok, %Source{scope: :grant, grant_id: id, set_id: set_id}, %{}} =
               resolve(ctx.user, nil)

      assert {id, set_id} == {grant.id, default.id}
    end
  end

  describe "a named grant that cannot serve" do
    test "disconnected: the error names it, and nothing else is used", ctx do
      grant = user_grant!(ctx.user.id, %{name: "Work"})
      set = set_naming(ctx.user, "Work set", grant)
      %{other: other, opts: opts} = every_fallback(ctx, set)
      :ok = ChatGPTAccounts.disconnect_for_user(grant.id, ctx.user.id)

      # The fallbacks are all really there: each serves a set that names no grant.
      {:ok, plain} = InferenceCredentials.create_set(ctx.user.id, "No grant, no key")
      assert {:error, :inference_credential_unusable} = resolve(ctx.user, plain)
      assert {:ok, %Source{scope: :tenant_secret}, _} = resolve(ctx.user, plain, opts)

      assert {:ok, %Source{scope: :grant}, _} =
               resolve(ctx.user, set_naming(ctx.user, "B", other))

      assert {:ok, :codex_chatgpt_access_token, _} =
               Fountain.PlatformInference.credential_for("openai", "codex")

      for resolve_opts <- [[], opts] do
        assert {:error, {:chatgpt_grant_unusable, detail}} = resolve(ctx.user, set, resolve_opts)
        assert detail == %{grant_id: grant.id, name: "Work", reason: :disconnected, until: nil}
      end

      message =
        InferenceCredentials.grant_unusable_message(%{
          grant_id: grant.id,
          name: "Work",
          reason: :disconnected,
          until: nil
        })

      assert message =~ ~s(ChatGPT subscription "Work" is disconnected)
      assert message =~ "does not switch"
    end

    test "the account default set is no different: not :missing, not the platform", ctx do
      grant = user_grant!(ctx.user.id, %{name: "Only"})
      default = set_naming(ctx.user, "Default", grant)
      %{opts: opts} = every_fallback(ctx, default)
      :ok = ChatGPTAccounts.disconnect_for_user(grant.id, ctx.user.id)

      agent = insert_agent(user_id: ctx.user.id, runtime: "codex")

      assert {:error, {:chatgpt_grant_unusable, %{reason: :disconnected, name: "Only"}}} =
               InferenceResolution.select(ctx.user.id, agent, [])

      assert {:error, {:chatgpt_grant_unusable, %{reason: :disconnected}}} =
               InferenceResolution.select(ctx.user.id, agent, opts)
    end

    test "revoked, expired, unrefreshable and exhausted each say so", ctx do
      until = DateTime.utc_now() |> DateTime.add(3_600) |> DateTime.truncate(:second)

      cases = [
        {:revoked, [status: "revoked", revoked_reason: "refresh_token_reused"], nil},
        {:expired, [status: "expired"], nil},
        {:reconnect_required, [refresh_token_ciphertext: nil], nil},
        {:reconnect_required, [account_id: nil], nil},
        {:exhausted, [usage_exhausted_until: until], until}
      ]

      for {{reason, fields, expected_until}, n} <- Enum.with_index(cases) do
        grant = user_grant!(ctx.user.id, %{name: "Grant #{n}"})
        set = set_naming(ctx.user, "Set #{n}", grant)
        {:ok, _} = InferenceCredentials.put_credential_in(set, ctx.dek, :openai_api_key, "sk-own")
        alter(grant, fields)

        assert {:error, {:chatgpt_grant_unusable, detail}} = resolve(ctx.user, set)

        assert detail == %{
                 grant_id: grant.id,
                 name: "Grant #{n}",
                 reason: reason,
                 until: expected_until
               }

        assert InferenceCredentials.grant_unusable_message(detail) =~ ~s("Grant #{n}")
      end

      exhausted =
        InferenceCredentials.grant_unusable_message(%{
          grant_id: "g",
          name: "Work",
          reason: :exhausted,
          until: until
        })

      assert exhausted =~ "until " <> DateTime.to_iso8601(until)
    end

    # A conversation is pinned to the grant and generation it started on, so
    # reconnecting or repointing never revives it (see "a reconnect is a new
    # generation" below). The remedy has to end in a new conversation.
    test "every remedy that changes the source says to start a new conversation" do
      for reason <- [:disconnected, :revoked, :expired, :reconnect_required, :not_found] do
        message =
          InferenceCredentials.grant_unusable_message(%{
            grant_id: "g",
            name: "Work",
            reason: reason,
            until: nil
          })

        assert message =~ "start a new conversation", "#{reason}: #{message}"
        assert message =~ "does not switch"
      end

      # Waiting out an exhaustion keeps the same grant and generation; only
      # the repoint needs a new conversation, and the sentence keeps them apart.
      exhausted =
        InferenceCredentials.grant_unusable_message(%{
          grant_id: "g",
          name: "Work",
          reason: :exhausted,
          until: nil
        })

      assert exhausted =~ "Wait for the reset, or point this credential set at another"
      assert exhausted =~ "start a new conversation"
    end

    # It is called while a refusal is being rendered. A reason a later stage
    # adds before it adds the sentence must not turn a 409 into a 500.
    test "a reason the message does not know still gets a sentence" do
      message =
        InferenceCredentials.grant_unusable_message(%{
          grant_id: "g",
          name: "Work",
          reason: :a_reason_not_taught_yet,
          until: nil
        })

      assert message =~ ~s(ChatGPT subscription "Work" cannot serve this run)
      assert message =~ "does not switch"

      assert InferenceCredentials.grant_unusable_message(%{reason: :something_else}) =~
               "cannot serve this run"
    end

    test "the log gets the grant id and the reason, not the name the tenant chose" do
      detail = %{grant_id: "g-1", name: "jo@example.com's plan", reason: :revoked, until: nil}

      logged = InferenceCredentials.loggable_reason({:chatgpt_grant_unusable, detail})
      assert logged == {:chatgpt_grant_unusable, %{grant_id: "g-1", reason: :revoked, until: nil}}
      refute inspect(logged) =~ "example.com"

      assert InferenceCredentials.loggable_reason(:inference_source_changed) ==
               :inference_source_changed
    end

    test "an exhaustion whose reset has passed no longer refuses", ctx do
      grant = user_grant!(ctx.user.id)
      set = set_naming(ctx.user, "Set", grant)
      alter(grant, usage_exhausted_until: DateTime.add(DateTime.utc_now(), -60))

      assert {:ok, %Source{scope: :grant}, _} = resolve(ctx.user, set)
    end

    test "a token inside its refresh margin still resolves: renewing is not resolution's", ctx do
      grant = user_grant!(ctx.user.id, %{access_token: access_token(-60)})
      set = set_naming(ctx.user, "Set", grant)

      assert {:ok, %Source{scope: :grant, generation: generation}, _} = resolve(ctx.user, set)
      assert generation == grant.generation
    end

    test "with no broker the grant is refused, and the set's key is not used instead", ctx do
      grant = user_grant!(ctx.user.id, %{name: "Work"})
      set = set_naming(ctx.user, "Set", grant)
      {:ok, _} = InferenceCredentials.put_credential_in(set, ctx.dek, :openai_api_key, "sk-own")
      Application.delete_env(:fountain, :broker_listen_port)

      assert {:error, {:chatgpt_grant_unusable, %{reason: :broker_required, name: "Work"}}} =
               resolve(ctx.user, set)
    end

    test "with no broker a disconnected grant still says disconnected", ctx do
      grant = user_grant!(ctx.user.id, %{name: "Work"})
      set = set_naming(ctx.user, "Set", grant)
      :ok = ChatGPTAccounts.disconnect_for_user(grant.id, ctx.user.id)
      Application.delete_env(:fountain, :broker_listen_port)

      assert {:error, {:chatgpt_grant_unusable, %{reason: :disconnected, name: "Work"}}} =
               resolve(ctx.user, set)
    end

    test "a set that names a grant its owner does not hold resolves to an error", ctx do
      # The changeset and the foreign key both refuse this row, so it is
      # written with the key's check off: the resolver's own owner-scoped
      # read is the third refusal, and it does not rest on the other two.
      thief = insert_active_user()
      {:ok, dek} = Crypto.load_tenant_key(thief.id)
      victims = user_grant!(ctx.user.id, %{name: "The victim's"})
      {:ok, set} = InferenceCredentials.create_set(thief.id, "Forged")
      {:ok, _} = InferenceCredentials.put_credential_in(set, dek, :openai_api_key, "sk-thief")

      Repo.query!("SET LOCAL session_replication_role = replica")

      Repo.query!("UPDATE inference_credentials SET chatgpt_grant_id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(victims.id),
        Ecto.UUID.dump!(set.id)
      ])

      Repo.query!("SET LOCAL session_replication_role = DEFAULT")

      assert {:error, {:chatgpt_grant_unusable, detail}} = resolve(thief, set)
      assert detail == %{grant_id: victims.id, name: nil, reason: :not_found, until: nil}
      refute InferenceCredentials.grant_unusable_message(detail) =~ "victim"
    end

    test "the error carries nothing secret", ctx do
      grant = user_grant!(ctx.user.id, %{refresh_token: "rt_super_secret"})
      set = set_naming(ctx.user, "Set", grant)
      alter(grant, status: "revoked")

      assert {:error, reason} = resolve(ctx.user, set)
      printed = inspect(reason, limit: :infinity)
      refute printed =~ "rt_super_secret"
      refute printed =~ "acct-user"
      refute printed =~ "ciphertext"
    end
  end

  describe "a grant beside a key" do
    test "codex takes the grant and is not handed the key; opencode takes the key", ctx do
      grant = user_grant!(ctx.user.id)
      set = set_naming(ctx.user, "Both", grant)
      {:ok, _} = InferenceCredentials.put_credential_in(set, ctx.dek, :openai_api_key, "sk-own")

      {:ok, _} =
        InferenceCredentials.put_credential_in(set, ctx.dek, :anthropic_api_key, "sk-ant")

      assert {:ok, %Source{scope: :grant}, creds} = resolve(ctx.user, set)
      # The competing OpenAI input is gone; unrelated credentials stay, beside
      # the grant's placeholder.
      assert creds == %{
               anthropic_api_key: "sk-ant",
               codex_chatgpt_access_token: Reserved.placeholder(grant.id)
             }

      assert {:ok, %Source{scope: :credential, kind: :openai_api_key} = source,
              %{openai_api_key: "sk-own"}} =
               resolve(ctx.user, set, runtime: "opencode", model: "openai/gpt-5")

      assert is_nil(source.grant_id)
      refute Map.has_key?(Source.dump(source), "grant_id")
    end

    test "an OPENAI_API_KEY in the environment or vault does not outrank the grant", ctx do
      grant = user_grant!(ctx.user.id)
      set = set_naming(ctx.user, "Set", grant)
      %{opts: opts} = every_fallback(ctx, set)

      assert {:ok, %Source{scope: :grant, grant_id: id} = source, creds} =
               resolve(ctx.user, set, opts)

      assert id == grant.id
      refute Map.has_key?(creds, :openai_api_key)
      assert source.environment_id == opts[:environment_id]
      assert source.vault_id == opts[:vault_id]
    end
  end

  # `Agent.changeset/2` refuses a wrong `provider/` prefix and accepts none at
  # all, and `Model.provider("gpt-5")` is nil. Codex reaches OpenAI whatever
  # the model string says, so the grant is keyed on the runtime: keyed on the
  # provider alone, this agent skipped the grant and ran on the set's key.
  describe "a codex model with no provider prefix" do
    @bare [model: "gpt-5", runtime: "codex"]

    test "resolves to the named grant, not to the set's key or an env or vault key", ctx do
      grant = user_grant!(ctx.user.id)
      set = set_naming(ctx.user, "Set", grant)
      %{opts: opts} = every_fallback(ctx, set)

      assert {:ok, %Source{scope: :grant, grant_id: id, model: "gpt-5"} = source, creds} =
               resolve(ctx.user, set, @bare ++ opts)

      assert id == grant.id
      assert source.identity == "chatgpt_grant:" <> grant.id
      refute Map.has_key?(creds, :openai_api_key)

      # The account default set, which this first set is, is no different.
      assert set.is_default
      assert {:ok, %Source{scope: :grant, grant_id: ^id}, _} = resolve(ctx.user, nil, @bare)
    end

    test "with the grant disconnected it is the tagged error, never the key", ctx do
      grant = user_grant!(ctx.user.id, %{name: "Work"})
      set = set_naming(ctx.user, "Set", grant)
      %{opts: opts} = every_fallback(ctx, set)
      :ok = ChatGPTAccounts.disconnect_for_user(grant.id, ctx.user.id)

      for extra <- [[], opts] do
        assert {:error, {:chatgpt_grant_unusable, detail}} =
                 resolve(ctx.user, set, @bare ++ extra)

        assert detail == %{grant_id: grant.id, name: "Work", reason: :disconnected, until: nil}
      end
    end

    test "a set that names no grant resolves as it always did", ctx do
      {:ok, set} = InferenceCredentials.create_set(ctx.user.id, "Plain")
      {:ok, _} = InferenceCredentials.put_credential_in(set, ctx.dek, :openai_api_key, "sk-own")

      assert {:ok, %Source{scope: :none}, %{openai_api_key: "sk-own"}} =
               resolve(ctx.user, set, @bare)
    end

    test "missing_for_model/3 answers for OpenAI when the set names a grant", ctx do
      grant = user_grant!(ctx.user.id)
      set = set_naming(ctx.user, "Set", grant)
      {:ok, plain} = InferenceCredentials.create_set(ctx.user.id, "Plain")

      missing = fn set, runtime ->
        InferenceCredentials.missing_for_model(ctx.user.id, "gpt-5",
          runtime: runtime,
          credential_set_id: set.id
        )
      end

      assert missing.(set, "codex") == nil
      # No prefix, no grant or no codex: a provider that asks for nothing, as before.
      assert missing.(plain, "codex") == nil
      assert missing.(set, "opencode") == nil

      # Unbrokered, the grant cannot serve, and a key would not either: codex
      # on this set is the grant or a refusal (stage 4a, item 2). So no key is
      # asked for, and what is wrong is `named_grant_problem/4`'s to say.
      Application.delete_env(:fountain, :broker_listen_port)
      assert missing.(set, "codex") == nil
      assert missing.(plain, "codex") == nil

      assert %{reason: :broker_required} =
               InferenceCredentials.named_grant_problem(ctx.user.id, "gpt-5", "codex",
                 credential_set_id: set.id
               )
    end

    test "named_grant_problem/4 is resolution's answer, for codex on a set that names a grant",
         ctx do
      grant = user_grant!(ctx.user.id, %{name: "Work"})
      set = set_naming(ctx.user, "Set", grant)
      {:ok, plain} = InferenceCredentials.create_set(ctx.user.id, "Plain")

      problem = fn set_id, runtime ->
        InferenceCredentials.named_grant_problem(ctx.user.id, @codex_model, runtime,
          credential_set_id: set_id
        )
      end

      assert problem.(set.id, "codex") == nil

      :ok = ChatGPTAccounts.disconnect_for_user(grant.id, ctx.user.id)
      grant_id = grant.id

      assert %{reason: :disconnected, name: "Work", grant_id: ^grant_id} =
               detail = problem.(set.id, "codex")

      assert InferenceCredentials.grant_unusable_message(detail) =~ ~s("Work" is disconnected)

      # Not a codex run, not a set that names one, not a set of this account.
      assert problem.(set.id, "opencode") == nil
      assert problem.(set.id, nil) == nil
      assert problem.(plain.id, "codex") == nil
      assert problem.(Ecto.UUID.generate(), "codex") == nil
      assert problem.("nope", "codex") == nil
    end

    test "a set that names a connected subscription has connected a provider", ctx do
      other = insert_active_user()
      grant = user_grant!(ctx.user.id)
      _unnamed = user_grant!(other.id)
      ids = [ctx.user.id, other.id]

      # A subscription no set names serves no run, and does not count.
      refute InferenceCredentials.has_any_credential?(ctx.user.id)
      refute InferenceCredentials.has_any_credential?(other.id)
      assert InferenceCredentials._unsafe_user_ids_with_credential(ids) == MapSet.new()

      set_naming(ctx.user, "Set", grant)
      assert InferenceCredentials.has_any_credential?(ctx.user.id)
      refute InferenceCredentials.has_any_credential?(other.id)

      assert InferenceCredentials._unsafe_user_ids_with_credential(ids) ==
               MapSet.new([ctx.user.id])

      # Disconnected, it holds nothing, and the checklist asks again.
      :ok = ChatGPTAccounts.disconnect_for_user(grant.id, ctx.user.id)
      refute InferenceCredentials.has_any_credential?(ctx.user.id)
      assert InferenceCredentials._unsafe_user_ids_with_credential(ids) == MapSet.new()
    end
  end

  describe "a grant and no key" do
    test "is eligible for codex and missing for every other OpenAI consumer", ctx do
      grant = user_grant!(ctx.user.id)
      default = set_naming(ctx.user, "Default", grant)
      other = [runtime: "opencode", model: "openai/gpt-5"]

      # Never the platform's key, which is configured: the account chose its
      # own OpenAI source for this set.
      assert {:ok, %Source{scope: :missing}, %{}} = resolve(ctx.user, nil, other)
      # Named explicitly, a set that cannot serve is refused, as an empty one is.
      assert {:error, :inference_credential_unusable} = resolve(ctx.user, default, other)

      # And it says so when the set is selected, not at the turn.
      assert InferenceCredentials.missing_for_model(ctx.user.id, @codex_model, runtime: "codex") ==
               nil

      for runtime <- ["opencode", nil] do
        assert InferenceCredentials.missing_for_model(ctx.user.id, "openai/gpt-5",
                 runtime: runtime,
                 credential_set_id: default.id
               ) == {"openai", [:openai_api_key]}
      end

      # Unbrokered, the grant cannot serve codex either, and a key is still
      # not what is missing: resolution would refuse the run with one.
      Application.delete_env(:fountain, :broker_listen_port)

      assert InferenceCredentials.missing_for_model(ctx.user.id, @codex_model, runtime: "codex") ==
               nil

      assert %{reason: :broker_required} =
               InferenceCredentials.named_grant_problem(ctx.user.id, @codex_model, "codex")
    end

    test "a set that names no grant asks for a key on codex as it always did", ctx do
      {:ok, set} = InferenceCredentials.create_set(ctx.user.id, "Default")

      assert InferenceCredentials.missing_for_model(ctx.user.id, @codex_model,
               runtime: "codex",
               credential_set_id: set.id
             ) == {"openai", [:openai_api_key]}
    end
  end

  describe "what the grant does not touch" do
    test "another provider's model on the same set resolves without reading the grant", ctx do
      grant = user_grant!(ctx.user.id)
      set = set_naming(ctx.user, "Set", grant)

      {:ok, _} =
        InferenceCredentials.put_credential_in(set, ctx.dek, :anthropic_api_key, "sk-ant")

      # Unusable, and it does not matter.
      :ok = ChatGPTAccounts.disconnect_for_user(grant.id, ctx.user.id)

      assert {:ok, %Source{scope: :credential, kind: :anthropic_api_key} = source, _} =
               resolve(ctx.user, set, runtime: "claude", model: "anthropic/claude-sonnet-4-6")

      refute Map.has_key?(Source.dump(source), "grant_id")
    end

    test "the platform path resolves and dumps exactly as it did", ctx do
      # No set at all, and a set with nothing in it: both take the
      # deployment's grant.
      assert {:ok, %Source{scope: :platform} = source, creds} = resolve(ctx.user, nil)

      assert Source.dump(source) == %{
               "origin" => "platform",
               "scope" => "platform",
               "kind" => "codex_chatgpt_access_token",
               "identity" => "platform:chatgpt:" <> ctx.platform.id,
               "revision" => ctx.platform.generation,
               "set_id" => nil,
               "runtime" => "codex",
               "model" => @codex_model,
               "environment_id" => nil,
               "vault_id" => nil
             }

      assert %{codex_chatgpt_access_token: token} = creds
      assert is_binary(token)
      assert Source.grant_ref(source) == {:platform, ctx.platform.id, ctx.platform.generation}

      # A user's grants existing, unnamed by any set, change nothing.
      _unnamed = user_grant!(ctx.user.id)
      assert {:ok, ^source, ^creds} = resolve(ctx.user, nil)
    end
  end

  describe "validate_source/2, which runs before every turn" do
    test "a usable grant validates; a disconnected one is the actionable error", ctx do
      grant = user_grant!(ctx.user.id, %{name: "Work"})
      set = set_naming(ctx.user, "Set", grant)
      {:ok, source, _} = resolve(ctx.user, set)

      assert :ok = InferenceCredentials.validate_source(ctx.user.id, source)
      # A rename is not a credential change.
      {:ok, _} = ChatGPTAccounts.rename_for_user(grant.id, ctx.user.id, "Renamed")
      assert :ok = InferenceCredentials.validate_source(ctx.user.id, source)

      :ok = ChatGPTAccounts.disconnect_for_user(grant.id, ctx.user.id)

      assert {:error, {:chatgpt_grant_unusable, %{reason: :disconnected, name: "Renamed"}}} =
               InferenceCredentials.validate_source(ctx.user.id, source)
    end

    test "a reconnect is a new generation, and so a changed source", ctx do
      grant = user_grant!(ctx.user.id, %{account_id: "acct-reconnect"})
      set = set_naming(ctx.user, "Set", grant)
      {:ok, source, _} = resolve(ctx.user, set)

      {:ok, reconnected} =
        ChatGPTAccounts.reconnect_for_user(grant.id, ctx.user.id, %{
          access_token: access_token(),
          refresh_token: "rt_again",
          id_token: id_token(%{account_id: "acct-reconnect"})
        })

      refute reconnected.generation == grant.generation

      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(ctx.user.id, source)

      # A new selection takes the new generation.
      assert {:ok, %Source{generation: generation}, _} = resolve(ctx.user, set)
      assert generation == reconnected.generation
    end

    test "a set repointed or cleared is a changed source, whatever state the new grant is in",
         ctx do
      first = user_grant!(ctx.user.id)
      second = user_grant!(ctx.user.id)
      set = set_naming(ctx.user, "Set", first)
      {:ok, _} = InferenceCredentials.put_credential_in(set, ctx.dek, :openai_api_key, "sk-own")
      {:ok, on_first, _} = resolve(ctx.user, set)

      {:ok, set} = InferenceCredentials.set_grant(set, second.id)

      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(ctx.user.id, on_first)

      # The conversation is pinned to the first grant. That the second is
      # unusable is not what it needs to hear.
      alter(second, status: "revoked")

      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(ctx.user.id, on_first)

      {:ok, set} = InferenceCredentials.set_grant(set, nil)

      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(ctx.user.id, on_first)

      # And the other way: bound to the set's key, then the set names a grant.
      {:ok, on_key, _} = resolve(ctx.user, set)
      assert %Source{scope: :credential, kind: :openai_api_key} = on_key
      {:ok, _} = InferenceCredentials.set_grant(set, second.id)

      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(ctx.user.id, on_key)
    end

    test "a source stored before this stage still validates", ctx do
      {:ok, set} = InferenceCredentials.create_set(ctx.user.id, "Default")
      {:ok, _} = InferenceCredentials.put_credential_in(set, ctx.dek, :openai_api_key, "sk-own")
      {:ok, source, _} = resolve(ctx.user, nil)

      stored = Source.dump(source)

      assert stored |> Map.keys() |> Enum.sort() ==
               ~w(environment_id identity kind model origin revision runtime scope set_id vault_id)

      assert :ok = InferenceCredentials.validate_source(ctx.user.id, Source.load(stored))
    end
  end
end
