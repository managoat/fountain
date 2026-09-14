defmodule Fountain.Conversations.CodexTransport do
  @moduledoc false

  # codex-acp 1.10 passes CODEX_CONFIG to thread/start and thread/resume.
  # Codex's default WebSocket dialer rejects HTTPS proxy URLs. Its explicit
  # proxy route supports TLS to the broker, but is opt-in in Codex 0.153.3.
  # Keep this process-local: persistent sandboxes are shared by conversations.

  # Rejecting the proxy URL is not the expensive part — waiting to find out
  # is. `responses_websocket` dials `wss://api.openai.com/v1/responses`, sits
  # on the connect timeout, reports `Proxy URL scheme not supported` and only
  # then falls back to HTTP. Measured on Sprites (#1674), that was 303, 292
  # and 306 seconds on three consecutive turns whose actual work took about a
  # second each.
  #
  # `supports_websockets` is a provider field, and the built-in `openai`
  # provider cannot be overridden — `model_providers contains reserved
  # built-in provider IDs` is a hard configuration error, from the file and
  # from here alike (openai/codex#13103). A provider id of our own is not
  # reserved, so declare the same endpoint with the websocket transport off
  # and select it.
  #
  # Endpoint and authentication need special handling in the substitution:
  #
  #   * **The endpoint.** The built-in reads `OPENAI_BASE_URL`, which is how
  #     an environment points codex at a gateway. `base_url/1` reads the same
  #     variable out of the spawn env, so hard-coding OpenAI's URL here does
  #     not silently redirect a conversation that had been going elsewhere.
  #   * **The credential.** A custom provider does not read `~/.codex/auth.json`,
  #     which is where `codex login --with-api-key` puts the key at provision
  #     time (ADR 0019 gate 3) and where a sandbox shared by several
  #     conversations still holds one. So the substitution happens only when
  #     `OPENAI_API_KEY` is in this spawn's env for `env_key` to name. Without
  #     it the conversation keeps the built-in provider and pays the stall —
  #     the wrong provider would cost it the turn instead.
  #
  # Brokered, `OPENAI_API_KEY` holds the placeholder the broker substitutes
  # for the real key on the way out (`Fountain.Broker.split_inference/2`), so
  # nothing about which key pays changes.
  #
  # **Scope.** This reads the CODEX_CONFIG overlay and nothing else. A
  # `model_provider` an environment's setup script wrote into
  # `~/.codex/config.toml` is invisible here, and the overlay outranks the
  # file, so such a conversation is moved onto this provider. Fountain writes
  # no `model_provider` of its own into that file; `env_vars` is the supported
  # way to point codex somewhere else, and `OPENAI_BASE_URL` set there is
  # carried across.
  #
  # **The ChatGPT grant** (ADR 0047 decision 4) is the second shape. When the
  # spawn carries `CODEX_CHATGPT_ACCESS_TOKEN` and no `OPENAI_API_KEY`, the
  # sandbox's `auth.json` is in `chatgptAuthTokens` mode with the placeholder
  # as its access token, and the provider must *read* it: `requires_openai_auth`
  # with no `env_key` resolves the ambient auth (bearer plus
  # `chatgpt-account-id`) whatever the provider's id
  # (`codex-rs/model-provider/src/auth.rs`, `resolve_provider_auth`). The
  # endpoint is the Codex backend, not the API, and `OPENAI_BASE_URL` is not
  # consulted: it points at OpenAI-compatible gateways, which this is not.
  # What the id costs is the built-in-only routes (guardian, remote
  # compaction, the token budget), none of which a turn depends on.
  @provider_id "fountain_openai_http"
  @openai_base_url "https://api.openai.com/v1"
  @chatgpt_base_url "https://chatgpt.com/backend-api/codex"
  @chatgpt_key "CODEX_CHATGPT_ACCESS_TOKEN"

  # The names this module reads and acts on. `CODEX_CONFIG` is already
  # collapsed by the rewrite, which rejects every entry and appends one.
  @resolved_names ["OPENAI_API_KEY", "OPENAI_BASE_URL", @chatgpt_key]

  def spawn_opts(%{broker: broker}, "codex", opts) when not is_nil(broker) do
    env = Keyword.get(opts, :env, [])

    # `SpriteEnv.build/4` concatenates its pieces without merging, so a name
    # can appear more than once. Nothing states which duplicate the sandbox
    # process then reads — `SpriteEnv`'s moduledoc is about `merge_secrets/3`,
    # which runs before the list is built, and `Managoat.Sandbox.spawn/4` is a
    # dependency. So this does not rely on the answer: it resolves last entry
    # wins, and `collapse/2` leaves exactly that entry in the env it emits, so
    # Fountain and codex cannot disagree whichever rule the adapter follows.
    resolved = Map.new(env)
    raw = Map.get(resolved, "CODEX_CONFIG", "{}")

    with {:ok, config} when is_map(config) <- Jason.decode(raw),
         features when is_map(features) <- Map.get(config, "features", %{}),
         # Type-checked here so a non-map is `:invalid_codex_config` rather
         # than a crash; `select_http_provider/2` reads it from `config`.
         providers when is_map(providers) <- Map.get(config, "model_providers", %{}) do
      _ = providers

      config =
        config
        |> Map.put("features", Map.put(features, "respect_system_proxy", true))
        |> Map.delete("features.respect_system_proxy")
        |> select_http_provider(resolved)

      env =
        Enum.reject(env, &match?({"CODEX_CONFIG", _}, &1)) ++
          [{"CODEX_CONFIG", Jason.encode!(config)}]

      {:ok, Keyword.put(opts, :env, collapse(env, @resolved_names))}
    else
      # Do not include the config: it may contain provider credentials.
      _ -> {:error, :invalid_codex_config}
    end
  end

  def spawn_opts(_state, _runtime, opts), do: {:ok, opts}

  # Repoint the conversation at an equivalent provider with the websocket
  # transport off. Only the one that would otherwise dial OpenAI directly: an
  # agent already pointed at a gateway keeps the provider it names, because
  # that provider decides its own transport and its endpoint is not ours to
  # replace.
  #
  # Selecting and declaring have to agree. A config that *selects* this id
  # chose the declaration beside it, so both are left alone. A config that
  # merely *declares* it without selecting it has chosen nothing, and writing
  # the selection over someone else's definition would hand the turn an
  # endpoint nothing picked — possibly with `supports_websockets` unset, which
  # is the stall this exists to remove. There, the definition is ours too.
  defp select_http_provider(config, env) do
    providers = Map.get(config, "model_providers", %{})

    cond do
      Map.get(config, "model_provider") == @provider_id ->
        config

      substitute?(config, env) ->
        config
        |> Map.put("model_provider", @provider_id)
        |> Map.put("model_providers", Map.put(providers, @provider_id, provider(env)))

      chatgpt?(config, env) ->
        config
        |> Map.put("model_provider", @provider_id)
        |> Map.put("model_providers", Map.put(providers, @provider_id, chatgpt_provider()))

      true ->
        config
    end
  end

  defp substitute?(config, env) do
    Map.get(config, "model_provider", "openai") == "openai" and present?(env, "OPENAI_API_KEY")
  end

  # The grant shape: the built-in would be selected, the spawn carries the
  # grant and no API key. A key beside the grant is the tenant's own or the
  # platform's, and the resolver never hands both out — but if both were
  # present the key would win above, as it does everywhere else.
  defp chatgpt?(config, env) do
    Map.get(config, "model_provider", "openai") == "openai" and present?(env, @chatgpt_key) and
      not present?(env, "OPENAI_API_KEY")
  end

  defp present?(env, name) do
    match?(value when is_binary(value) and value != "", Map.get(env, name))
  end

  # Audited against the same lib.rs as `provider/1`: with a ChatGPT auth mode
  # the built-in's base URL is the Codex backend and its auth is the ambient
  # `auth.json`. `requires_openai_auth` without `env_key` is what selects
  # that auth on a custom id; `supports_websockets` is deliberately false.
  # No `env_http_headers`: the organization and project headers belong to
  # the API, and the backend ignores them.
  defp chatgpt_provider do
    %{
      "name" => "OpenAI",
      "base_url" => @chatgpt_base_url,
      "wire_api" => "responses",
      "requires_openai_auth" => true,
      "supports_websockets" => false
    }
  end

  # Field audit: Codex rust-v0.147.0 (installed in the review image) and
  # rust-v0.153.3, codex-rs/model-provider-info/src/lib.rs,
  # built_in_model_providers -> create_openai_provider:
  # https://github.com/openai/codex/blob/rust-v0.147.0/codex-rs/model-provider-info/src/lib.rs
  # Both set name, base_url, wire_api, env_http_headers, http_headers,
  # requires_openai_auth, supports_websockets and supports_standalone_web_search.
  # Preserve organization/project mappings and standalone search. Their sole
  # provider http_header is the compiled CLI version; deliberately omit it:
  # Fountain does not know the conversation sandbox's CLI version, and using
  # the review image's version would misidentify an unpinned installation.
  # Neither version declares OpenAI-Beta or originator as provider headers.
  # env_key replaces requires_openai_auth only with a spawn credential;
  # supports_websockets is deliberately false. env_key_instructions,
  # experimental_bearer_token, auth, aws and query_params are all unset.
  # request_max_retries, stream_max_retries, stream_idle_timeout_ms and
  # websocket_connect_timeout_ms are also unset, using the same global
  # defaults for built-in and custom providers; keep them unset here.
  defp provider(env) do
    %{
      "name" => "OpenAI",
      "base_url" => base_url(env),
      "wire_api" => "responses",
      "env_key" => "OPENAI_API_KEY",
      "supports_websockets" => false,
      "supports_standalone_web_search" => true,
      "env_http_headers" => %{
        "OpenAI-Organization" => "OPENAI_ORGANIZATION",
        "OpenAI-Project" => "OPENAI_PROJECT"
      }
    }
  end

  # Leave one entry per name — the one `resolved` acted on. Reading a
  # duplicate one way and handing codex a list it may read the other way is
  # how the endpoint and the credential could disagree. Untouched when the
  # name appears once, which is every ordinary conversation.
  defp collapse(env, names) do
    Enum.reduce(names, env, fn name, acc ->
      case Enum.filter(acc, &match?({^name, _}, &1)) do
        [_, _ | _] = duplicated ->
          Enum.reject(acc, &match?({^name, _}, &1)) ++ [List.last(duplicated)]

        _ ->
          acc
      end
    end)
  end

  defp base_url(env) do
    case Map.get(env, "OPENAI_BASE_URL") do
      url when is_binary(url) and url != "" -> url
      _ -> @openai_base_url
    end
  end
end
