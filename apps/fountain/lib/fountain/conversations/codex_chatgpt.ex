defmodule Fountain.Conversations.CodexChatGPT do
  @moduledoc """
  How the deployment's ChatGPT grant reaches a codex sandbox (ADR 0047
  decision 4).

  `Managoat.Runtimes.Codex` knows one credential, `OPENAI_API_KEY`, which
  its `prepare_sandbox/3` pipes into `codex login --with-api-key`. The grant
  is a different shape: an access token codex must not try to refresh, and
  an account id it sends beside the bearer. Rather than teach the library a
  second login (a release and a pin bump), Fountain writes the file itself:

    * `env/2` exports `CODEX_CHATGPT_ACCESS_TOKEN` for a codex spawn whose
      credentials carry the grant. Brokered, that value is the placeholder
      `Fountain.Broker.split_inference/2` put there, and the broker
      substitutes the real token on `chatgpt.com`.
    * `prepare_sandbox/3` writes `~/.codex/auth.json` in `chatgptAuthTokens`
      mode ("externally managed tokens": codex never refreshes and never
      checks `exp`) with that value where the bearer goes, the real account
      id, and an `id_token` synthesised from the stored claims. It runs
      before the library's `prepare_sandbox/3` would, and replaces it.

  The file names the placeholder, so it is worthless off the box. A
  persistent sandbox shared by a conversation on the API-key path and one
  on the grant holds whichever file was written last; the API-key provider
  reads its key from the env and is unaffected, the grant's provider reads
  the file.
  """

  alias Fountain.ChatGPTAccounts
  alias Managoat.Runtimes.Layout

  @env_key "CODEX_CHATGPT_ACCESS_TOKEN"
  @credential :codex_chatgpt_access_token
  @runtime "codex"

  @doc "The env var the grant travels under, and the credential atom it comes from."
  def env_key, do: @env_key
  def credential, do: @credential

  @doc """
  Whether this module can carry a resolved source into a sandbox: `:ok` for
  everything but a `:grant` source, a user's own subscription that their
  credential set names (ADR 0060 decision 2).

  **Temporary, and ADR 0060 stage 3 deletes it.** Selection of a user's
  grant is built and its transport is not. `prepare_sandbox/3` below writes
  the *platform* grant's account id and `id_token` whatever the source is,
  so a user's bearer would travel beside the deployment's account; the
  broker holds one `CODEX_CHATGPT_ACCESS_TOKEN` entry per conversation; and
  `Egress` renews only the platform grant. Until those follow the named
  grant, admission and `InferenceBinding.reserve/2` refuse a `:grant` source
  here, so no conversation is ever bound to one and nothing downstream has
  to handle it. No user can hold a grant before stage 4, so this refuses
  nothing anyone can do today; it keeps each stage safe on its own.
  """
  @spec transport_ready(Fountain.InferenceCredentials.Source.t()) ::
          :ok | {:error, :chatgpt_grant_transport_unavailable}
  def transport_ready(%Fountain.InferenceCredentials.Source{scope: :grant}),
    do: {:error, :chatgpt_grant_transport_unavailable}

  def transport_ready(%Fountain.InferenceCredentials.Source{}), do: :ok

  @doc """
  The spawn env entry for the grant: `[{"CODEX_CHATGPT_ACCESS_TOKEN", value}]`
  for the codex runtime when the credentials carry it, else `[]`.
  """
  @spec env(module() | nil, map()) :: [{String.t(), String.t()}]
  def env(Managoat.Runtimes.Codex, credentials) when is_map(credentials) do
    case Map.get(credentials, @credential) do
      value when is_binary(value) and value != "" -> [{@env_key, value}]
      _ -> []
    end
  end

  def env(_runtime_module, _credentials), do: []

  @doc """
  Which `authenticate` method the ACP peer may use for this spawn
  (`Managoat.ACP.Peer`'s `:auth`). On the grant it is `:none`: codex-acp's
  api-key method runs `accountLogin({type: "apiKey"})` from an env var and
  rewrites the file above, and with no key in the env it fails outright
  (measured 2026-09-08, ADR 0047 G0). Every other spawn keeps the peer's
  default.
  """
  @spec peer_auth(module() | nil, map()) :: :none | :api_key
  def peer_auth(Managoat.Runtimes.Codex, credentials) when is_map(credentials) do
    case Map.get(credentials, @credential) do
      value when is_binary(value) and value != "" -> :none
      _ -> :api_key
    end
  end

  def peer_auth(_runtime_module, _credentials), do: :api_key

  @doc """
  Write the sandbox's `auth.json` when this codex spawn runs on the grant.
  `:skip` when it does not, or when an `OPENAI_API_KEY` sits beside the
  grant (the library's `prepare_sandbox/3` then runs as today); `:ok` or
  `{:error, reason}` when it does.
  """
  @spec prepare_sandbox(Managoat.Sandbox.Handle.t(), String.t(), [{String.t(), String.t()}]) ::
          :skip | :ok | {:error, term()}
  def prepare_sandbox(handle, @runtime, sprite_env) do
    # A key beside the grant wins, as it does in `CodexTransport`: the
    # tenant's environment or vault may name `OPENAI_API_KEY` without
    # holding an inference credential, and that spawn runs on the key
    # through the library's login, not on this file.
    case {List.keyfind(sprite_env, @env_key, 0), List.keyfind(sprite_env, "OPENAI_API_KEY", 0)} do
      {{@env_key, value}, key}
      when is_binary(value) and value != "" and
             (is_nil(key) or elem(key, 1) in [nil, ""]) ->
        case ChatGPTAccounts.platform_sandbox_auth() do
          {:ok, auth} -> write(handle, auth_json(value, auth))
          :none -> {:error, :platform_chatgpt_not_connected}
        end

      _ ->
        :skip
    end
  end

  def prepare_sandbox(_handle, _runtime, _sprite_env), do: :skip

  @doc "The `auth.json` body: `chatgptAuthTokens`, the bearer value, the real account id, the synthesised id_token."
  @spec auth_json(String.t(), %{account_id: String.t(), id_token: String.t()}) :: String.t()
  def auth_json(access_value, %{account_id: account_id, id_token: id_token}) do
    Jason.encode!(%{
      "auth_mode" => "chatgptAuthTokens",
      "tokens" => %{
        "id_token" => id_token,
        "access_token" => access_value,
        "refresh_token" => "",
        "account_id" => account_id
      },
      "last_refresh" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })
  end

  @doc "Where the file goes: `$CODEX_HOME/auth.json`, under the runtime's layout."
  @spec auth_path() :: String.t()
  def auth_path, do: Path.join(Layout.config_root(@runtime), "auth.json")

  defp write(handle, body) do
    dir = Layout.config_root(@runtime)

    with {:ok, _out, 0} <- Managoat.Sandbox.exec(handle, "mkdir", ["-p", dir], []),
         :ok <- Managoat.Sandbox.write_file(handle, auth_path(), body, mode: 0o600) do
      :ok
    else
      {:ok, out, code} -> {:error, {:codex_auth_mkdir, code, out}}
      {:error, reason} -> {:error, {:codex_auth_write, reason}}
    end
  end
end
