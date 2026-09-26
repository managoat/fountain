defmodule Fountain.Conversations.CodexTransportTest do
  use ExUnit.Case, async: true

  alias Fountain.Conversations.CodexTransport

  # What a keyed spawn gains beside its own env.
  @added ["CODEX_CONFIG", "MODEL_PROVIDER"]

  test "brokered Codex gets TLS proxy support without changing proxy credentials or spawn options" do
    opts = [
      env: [{"HTTPS_PROXY", "https://token:label@broker.example:443"}],
      dir: "/track",
      stdin: true
    ]

    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", opts)
    assert Keyword.delete(result, :env) == Keyword.delete(opts, :env)
    assert List.keyfind(result[:env], "HTTPS_PROXY", 0) == hd(opts[:env])
    assert config(result)["features"]["respect_system_proxy"] == true
    # Applying the policy again must not duplicate CODEX_CONFIG.
    assert {:ok, ^result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", result)
  end

  # #1674. `responses_websocket` cannot use an https-scheme proxy, but it
  # spends the full connect timeout finding that out — 303, 292 and 306
  # seconds on three consecutive Sprites turns whose work took about a
  # second. `supports_websockets` lives on the provider and the built-in
  # `openai` id is reserved, so declare the same endpoint under an id of our
  # own and select it.
  test "brokered Codex talks to OpenAI over a provider with no websocket transport" do
    assert {:ok, result} =
             CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: [key("sk-x")])

    config = config(result)

    assert config["model_provider"] == "fountain_openai_http"

    # Everything the built-in provider declares, minus the two fields that
    # cannot carry across: `requires_openai_auth` (a custom provider cannot
    # read auth.json, so `env_key` replaces it) and the compiled-in `version`
    # header, which names the CLI build Fountain is not in a position to know.
    # Audited against codex-rs/model-provider-info/src/lib.rs at rust-v0.153.3.
    assert config["model_providers"] == %{
             "fountain_openai_http" => %{
               "name" => "OpenAI",
               "base_url" => "https://api.openai.com/v1",
               "wire_api" => "responses",
               "env_key" => "OPENAI_API_KEY",
               "supports_websockets" => false,
               "supports_standalone_web_search" => true,
               "env_http_headers" => %{
                 "OpenAI-Organization" => "OPENAI_ORGANIZATION",
                 "OpenAI-Project" => "OPENAI_PROJECT"
               }
             }
           }
  end

  # `SpriteEnv.build/4` concatenates the runtime's defaults, the environment's
  # vars and the decrypted secrets without merging, so a vault entry for
  # either variable appears twice. Nothing in this repository states which one
  # the spawned process then reads — `SpriteEnv`'s moduledoc is about
  # `merge_secrets/3`, which runs before the list exists — so the module does
  # not depend on the answer: it resolves last entry wins and emits an env
  # carrying only that entry.
  test "a repeated variable resolves last-entry-wins and only that entry is emitted" do
    env = [
      key("sk-runtime-default"),
      {"OPENAI_BASE_URL", "https://api.openai.com/v1"},
      key(""),
      {"OPENAI_BASE_URL", "https://gw.example/v1"}
    ]

    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)

    # Emptied by the later entry: no credential, so no substitution.
    refute Map.has_key?(config(result), "model_provider")

    env = List.keyreplace(env, "OPENAI_API_KEY", 0, key("sk-x")) ++ [key("sk-vault")]

    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)

    assert config(result)["model_providers"]["fountain_openai_http"]["base_url"] ==
             "https://gw.example/v1"

    # And the duplicates are gone from what codex is handed, so it cannot
    # resolve them the other way and reach a different endpoint or key.
    for name <- ["OPENAI_API_KEY", "OPENAI_BASE_URL"] do
      assert Enum.count(result[:env], &match?({^name, _}, &1)) == 1
    end

    assert {"OPENAI_BASE_URL", "https://gw.example/v1"} in result[:env]
    assert {"OPENAI_API_KEY", "sk-vault"} in result[:env]
  end

  # A name that appears once is left where SpriteEnv put it.
  test "an env with no duplicates is passed through untouched" do
    env = [key("sk-x"), {"OPENAI_BASE_URL", "https://gw.example/v1"}, {"KEEP", "1"}]

    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)

    assert Enum.reject(result[:env], &match?({name, _} when name in @added, &1)) == env
  end

  # #2503. codex-acp 1.10 sends `thread/resume` a typed `modelProvider` taken
  # from its `MODEL_PROVIDER` launch variable, falling back to the config
  # file and then to "openai". The file never sees the overlay, so without the
  # variable every resumed thread went back to the built-in provider and
  # dialled the WebSocket again.
  test "the selected provider is also the launch variable codex-acp resumes with" do
    for env <- [
          [key("sk-x")],
          [{"CODEX_CHATGPT_ACCESS_TOKEN", "__codex_chatgpt_access_token__"}]
        ] do
      assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)

      assert config(result)["model_provider"] == "fountain_openai_http"

      assert Enum.filter(result[:env], &match?({"MODEL_PROVIDER", _}, &1)) ==
               [{"MODEL_PROVIDER", "fountain_openai_http"}]

      # Applying the policy again changes nothing.
      assert {:ok, ^result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", result)
    end

    # Nothing selected, nothing pinned: the built-in resumes as before.
    assert {:ok, bare} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: [])
    refute List.keymember?(bare[:env], "MODEL_PROVIDER", 0)
  end

  # The variable is a selection codex-acp acts on, so it is read as one.
  test "a MODEL_PROVIDER in the env selects a provider like the overlay does" do
    gateway = [key("sk-x"), {"MODEL_PROVIDER", "litellm"}]
    assert {:ok, kept} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: gateway)

    refute Map.has_key?(config(kept), "model_provider")
    assert Enum.reject(kept[:env], &match?({"CODEX_CONFIG", _}, &1)) == gateway

    # Naming the built-in is the built-in: substituted, and the one entry
    # left names the replacement.
    builtin = [{"MODEL_PROVIDER", "openai"}, key("sk-x")]
    assert {:ok, moved} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: builtin)

    assert config(moved)["model_provider"] == "fountain_openai_http"

    assert Enum.filter(moved[:env], &match?({"MODEL_PROVIDER", _}, &1)) ==
             [{"MODEL_PROVIDER", "fountain_openai_http"}]
  end

  # #2503. A grant's session refuses every chatgpt.com route but the
  # protected ones. Analytics and the remote plugin catalog asked for such
  # routes hundreds of times an hour, each refusal costing a tunnel.
  test "a grant spawn turns off analytics and the remote plugin catalog by default" do
    grant = [{"CODEX_CHATGPT_ACCESS_TOKEN", "__codex_chatgpt_access_token__"}]
    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: grant)

    assert config(result)["features"]["remote_plugin"] == false
    assert config(result)["analytics"] == %{"enabled" => false}

    # What the overlay sets itself is kept, in either spelling.
    for overlay <- [
          %{"features" => %{"remote_plugin" => true}, "analytics" => %{"enabled" => true}},
          %{"features.remote_plugin" => true, "analytics.enabled" => true}
        ] do
      env = grant ++ [{"CODEX_CONFIG", Jason.encode!(overlay)}]
      assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)
      config = config(result)

      refute config["features"]["remote_plugin"] == false
      refute get_in(config, ["analytics", "enabled"]) == false
    end

    # Not a grant, nothing refused: codex's own defaults stand.
    for env <- [[key("sk-x")], grant ++ [key("sk-x")], []] do
      assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)
      refute Map.has_key?(config(result)["features"], "remote_plugin")
      refute Map.has_key?(config(result), "analytics")
    end
  end

  # The built-in provider reads OPENAI_BASE_URL, so an environment pointing
  # codex at a gateway through `env_vars` was already working. Hard-coding
  # OpenAI's URL into the replacement would have redirected it silently.
  test "the replacement provider keeps the endpoint OPENAI_BASE_URL names" do
    env = [key("sk-x"), {"OPENAI_BASE_URL", "https://gw.example/v1"}]

    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)

    assert config(result)["model_providers"]["fountain_openai_http"]["base_url"] ==
             "https://gw.example/v1"
  end

  # A custom provider does not read ~/.codex/auth.json, so a conversation
  # with no OPENAI_API_KEY in its spawn env would have nothing to
  # authenticate with. A shared sandbox may still hold the auth.json that
  # `codex login --with-api-key` wrote for whoever provisioned it, and the
  # built-in provider can use it. Paying the stall beats losing the turn.
  test "a spawn with no OPENAI_API_KEY keeps the built-in provider" do
    for env <- [[], [{"OPENAI_API_KEY", ""}]] do
      assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)

      config = config(result)

      refute Map.has_key?(config, "model_provider")
      refute Map.has_key?(config, "model_providers")
      # The proxy half does not depend on the credential.
      assert config["features"]["respect_system_proxy"] == true
    end
  end

  test "an agent already pointed at a gateway keeps the provider it names" do
    original = %{
      "model_provider" => "litellm",
      "model_providers" => %{"litellm" => %{"base_url" => "https://gw.example/v1"}}
    }

    assert {:ok, result} =
             CodexTransport.spawn_opts(%{broker: %{}}, "codex",
               env: [key("sk-x"), {"CODEX_CONFIG", Jason.encode!(original)}]
             )

    config = config(result)

    assert config["model_provider"] == "litellm"
    assert config["model_providers"] == original["model_providers"]
    # The proxy half still applies: that is about the transport, not the host.
    assert config["features"]["respect_system_proxy"] == true
  end

  # `Map.put` for the selection and `Map.put_new` for the declaration
  # disagreed on one shape: a config that declares this id without selecting
  # it. The selection was written over a definition Fountain did not author,
  # so the turn ran on an endpoint nothing picked — possibly with
  # `supports_websockets` unset, which is the stall this module removes.
  test "a declaration of our id that nothing selected does not become the endpoint" do
    stray = %{
      "base_url" => "https://someone-elses.example/v1",
      "wire_api" => "responses"
    }

    for selected <- [nil, "openai"] do
      original =
        %{"model_providers" => %{"fountain_openai_http" => stray}}
        |> then(&if(selected, do: Map.put(&1, "model_provider", selected), else: &1))

      assert {:ok, result} =
               CodexTransport.spawn_opts(%{broker: %{}}, "codex",
                 env: [key("sk-x"), {"CODEX_CONFIG", Jason.encode!(original)}]
               )

      config = config(result)
      provider = config["model_providers"]["fountain_openai_http"]

      assert config["model_provider"] == "fountain_openai_http"
      assert provider["base_url"] == "https://api.openai.com/v1"
      assert provider["supports_websockets"] == false
    end
  end

  test "a provider declaration of our own id is left as the operator wrote it" do
    mine = %{"base_url" => "https://proxy.internal/v1", "supports_websockets" => false}

    original = %{
      "model_provider" => "fountain_openai_http",
      "model_providers" => %{"fountain_openai_http" => mine}
    }

    assert {:ok, result} =
             CodexTransport.spawn_opts(%{broker: %{}}, "codex",
               env: [key("sk-x"), {"CODEX_CONFIG", Jason.encode!(original)}]
             )

    assert config(result)["model_providers"]["fountain_openai_http"] == mine
  end

  test "existing settings survive, including unrelated feature flags" do
    original = %{
      "model" => "gpt-5.3-codex",
      "features" => %{"multi_agent" => false, "respect_system_proxy" => false},
      "features.respect_system_proxy" => false,
      "model_providers" => %{"custom" => %{"base_url" => "https://example.com"}}
    }

    opts = [env: [key("sk-x"), {"CODEX_CONFIG", Jason.encode!(original)}]]
    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", opts)
    updated = config(result)
    assert updated["features"] == %{"multi_agent" => false, "respect_system_proxy" => true}
    refute Map.has_key?(updated, "features.respect_system_proxy")
    assert updated["model"] == original["model"]

    # Exactly one entry added, every neighbour untouched.
    assert Map.keys(updated["model_providers"]) |> Enum.sort() ==
             ["custom", "fountain_openai_http"]

    assert updated["model_providers"]["custom"] == original["model_providers"]["custom"]
  end

  # `List.keystore/4` rewrites the *first* entry. Read under the same
  # last-entry precedence, that would have left a later untouched entry
  # carrying the config, so the whole policy — proxy support and provider
  # selection both — would not have been the one applied. The write half is
  # independent of the question: exactly one entry is emitted, last.
  test "a repeated CODEX_CONFIG is read and rewritten under one precedence" do
    stale = Jason.encode!(%{"model" => "stale"})
    live = Jason.encode!(%{"model" => "live"})

    env = [
      key("sk-x"),
      {"CODEX_CONFIG", stale},
      {"KEEP", "1"},
      {"CODEX_CONFIG", live}
    ]

    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)

    # Read from the effective entry, not the first.
    assert config(result)["model"] == "live"

    # And written as one entry, last, so nothing shadows it.
    assert Enum.count(result[:env], &match?({"CODEX_CONFIG", _}, &1)) == 1
    assert {"CODEX_CONFIG", _} = List.last(result[:env])
    assert {"KEEP", "1"} in result[:env]
  end

  test "unbrokered Codex and other runtimes retain their exact options" do
    opts = [env: [{"CODEX_CONFIG", "unchanged"}]]
    assert {:ok, ^opts} = CodexTransport.spawn_opts(%{broker: nil}, "codex", opts)
    assert {:ok, ^opts} = CodexTransport.spawn_opts(%{}, "codex", opts)

    for runtime <- ["claude", "gemini", "opencode"] do
      assert {:ok, ^opts} = CodexTransport.spawn_opts(%{broker: %{}}, runtime, opts)
    end
  end

  test "invalid configuration fails without leaking its contents" do
    for raw <- [
          "secret-invalid-json",
          "[]",
          "null",
          ~s({"features":false}),
          ~s({"model_providers":"openai"})
        ] do
      assert {:error, :invalid_codex_config} =
               CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: [{"CODEX_CONFIG", raw}])
    end
  end

  # The gate below is only as good as this: `substitute?/2` is false without
  # `OPENAI_API_KEY` in the spawn env, and for a conversation whose OpenAI key
  # is an inference credential the only producer is the runtime module — a hex
  # dependency. If a later `managoat_runtimes` stops exporting it, every
  # brokered Codex turn quietly keeps the built-in provider and the 300-second
  # stall comes back with nothing failing. Pinned the way
  # `conversation_server_broker_test.exs` pins the same fact for Claude.
  test "the runtime module exports the credential this module gates on" do
    assert {"OPENAI_API_KEY", "sk-__openai_api_key__"} in Managoat.Runtimes.Codex.default_env(
             nil,
             %{openai_api_key: "sk-__openai_api_key__"}
           )

    # Membership, not equality: this pins the credential this module gates on,
    # and an unrelated pair added upstream should not fail a test about it.
    for absent <- [%{}, %{openai_api_key: nil}, %{openai_api_key: ""}] do
      refute List.keymember?(
               Managoat.Runtimes.Codex.default_env(nil, absent),
               "OPENAI_API_KEY",
               0
             )
    end
  end

  # ADR 0047 decision 4. On the deployment's ChatGPT grant the sandbox holds
  # `auth.json` in chatgptAuthTokens mode with the placeholder as its access
  # token, and the provider must read it: `requires_openai_auth` with no
  # `env_key` resolves the ambient auth whatever the provider id. The
  # endpoint is the Codex backend, not the API.
  test "a codex spawn on the ChatGPT grant gets the backend provider that reads auth.json" do
    env = [{"CODEX_CHATGPT_ACCESS_TOKEN", "__codex_chatgpt_access_token__"}]
    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)
    config = config(result)

    assert config["model_provider"] == "fountain_openai_http"

    assert config["model_providers"] == %{
             "fountain_openai_http" => %{
               "name" => "OpenAI",
               "base_url" => "https://chatgpt.com/backend-api/codex",
               "wire_api" => "responses",
               "requires_openai_auth" => true,
               "supports_websockets" => false
             }
           }

    assert config["features"]["respect_system_proxy"] == true
    assert List.keyfind(result[:env], "CODEX_CHATGPT_ACCESS_TOKEN", 0) == hd(env)

    # An API key beside the grant takes the key shape, as everywhere else;
    # and a gateway the environment names is left to its own provider.
    assert {:ok, keyed} =
             CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env ++ [key("sk-x")])

    assert config(keyed)["model_providers"]["fountain_openai_http"]["env_key"] == "OPENAI_API_KEY"

    gateway = [{"CODEX_CONFIG", ~s({"model_provider":"gw"})} | env]
    assert {:ok, other} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: gateway)
    assert config(other)["model_provider"] == "gw"
    refute Map.has_key?(config(other), "model_providers")

    # An emptied grant is no grant.
    assert {:ok, none} =
             CodexTransport.spawn_opts(%{broker: %{}}, "codex",
               env: env ++ [{"CODEX_CHATGPT_ACCESS_TOKEN", ""}]
             )

    refute Map.has_key?(config(none), "model_provider")
  end

  defp key(value), do: {"OPENAI_API_KEY", value}

  defp config(opts) do
    {_, raw} = List.keyfind(opts[:env], "CODEX_CONFIG", 0)
    Jason.decode!(raw)
  end
end
