defmodule Fountain.Conversations.CodexChatGPT do
  @moduledoc """
  How a ChatGPT grant reaches a codex sandbox: the deployment's (ADR 0047
  decision 4) or one of a user's (ADR 0060 decision 6).

  `Managoat.Runtimes.Codex` knows one credential, `OPENAI_API_KEY`, which
  its `prepare_sandbox/3` pipes into `codex login --with-api-key`. A grant
  is a different shape: an access token codex must not try to refresh, and
  an account id it sends beside the bearer. Rather than teach the library a
  second login (a release and a pin bump), Fountain writes the file itself:

    * `env/3` exports `CODEX_CHATGPT_ACCESS_TOKEN` for a codex spawn on a
      grant. Its value is a placeholder, never the token.
    * `prepare_sandbox/5` writes `auth.json` in `chatgptAuthTokens` mode
      ("externally managed tokens": codex never refreshes and never checks
      `exp`) with that value where the bearer goes, the real account id, and
      an `id_token` synthesised from the stored claims. It runs before the
      library's `prepare_sandbox/3` would, and replaces it.

  The file names a placeholder, so it is worthless off the box.

  ## A grant with a home of its own

  `managed_grant/2` says which sources have one. For such a source
  everything comes from the resolved source, by owner, grant id and
  generation, and nothing from a deployment-wide lookup:

    * the file is `<home>/auth.json` under a `CODEX_HOME` of the grant's own,
      `/home/sprite/.codex-grants/<grant id>.<generation>` (`home/1`), and
      `env/3` exports that `CODEX_HOME` to the process and to nothing on the
      disk (`Fountain.Conversations.Identity`). Two conversations of one
      agent on one persistent sandbox, on two of a user's subscriptions,
      therefore read two files and cannot overwrite each other's account
      (ADR 0052 decision 5). A conversation is pinned to one grant and
      generation for life, so its home never moves; a reconnect is a new
      generation, a new home and a new conversation.
    * everything else codex keeps under `~/.codex` stays shared, through
      symbolic links made when the home is prepared: `config.toml`,
      `AGENTS.md`, `skills/`, and `sessions/`, so `thread/resume` finds a
      rollout wherever the conversation that wrote it ran. Only `auth.json`
      is per grant. Same unix user, so this prevents overwrite and
      mis-attribution, not reads: a peer that reads another grant's file
      gets a placeholder and an account id, and its own broker session still
      sends only its own grant's bearer and account.
    * the placeholder is the grant's own (`Reserved.placeholder/1`).

  **Not measured against a real client.** `managoat_runtimes` fixes codex's
  config root (`Managoat.Runtimes.Layout`) and neither it nor `managoat_acp`
  reads `CODEX_HOME`; the symlinked home is Fountain's way round that without
  a library release. That codex-acp and the codex CLI honour `CODEX_HOME`,
  resume a session through a linked `sessions/`, and find skills through a
  linked `skills/` is asserted from their source, not observed. It has to be
  measured in a real sandbox before a user can link a subscription.

  Every other source keeps the shared `~/.codex/auth.json`, the deployment's
  grant included: a persistent sandbox shared by a conversation on the
  API-key path and one on the deployment's grant holds whichever file was
  written last; the API-key provider reads its key from the env and is
  unaffected, the grant's provider reads the file.
  """

  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.Reserved
  alias Fountain.InferenceCredentials.Source
  alias Managoat.Runtimes.Layout

  require Logger

  @env_key "CODEX_CHATGPT_ACCESS_TOKEN"
  @home_key "CODEX_HOME"
  @credential :codex_chatgpt_access_token
  @runtime "codex"

  @doc "The env var the grant travels under, and the credential atom it comes from."
  def env_key, do: @env_key
  def credential, do: @credential

  @doc "The variable that points codex at a grant's own home."
  def home_key, do: @home_key

  @doc """
  The managed grant a resolved source runs on when that grant has a home and
  a broker session of its own, as a `t:Fountain.ChatGPTAccounts.grant_ref/0`;
  `nil` for every other source. `user_id` is the conversation's owner, which
  a `:grant` source does not repeat.

  A user's subscription (`scope: :grant`) always is one. The deployment's
  grant is not yet: it still travels as a substitution rule and writes the
  shared `~/.codex/auth.json`, and this is the one clause that would move it.
  """
  @spec managed_grant(Source.t() | nil, String.t() | nil) :: ChatGPTAccounts.grant_ref() | nil
  def managed_grant(%Source{scope: :grant} = source, user_id) when is_binary(user_id) do
    case Source.grant_ref(source) do
      {:user, grant_id, generation} ->
        %{owner: {:user, user_id}, grant_id: grant_id, generation: generation}

      _ ->
        nil
    end
  end

  def managed_grant(_source, _user_id), do: nil

  @doc """
  Renew the grant a turn is about to run on, if it needs it, **by grant id
  and generation** and never by comparing tokens: a conversation holds no
  token to compare (ADR 0052 decision 4). `:ok` for every source that is not
  a managed grant.

  A fresh grant costs one metadata read. One inside its refresh margin is
  renewed through the owner's coordinator
  (`ChatGPTAccounts.ensure_fresh_for_user/3`); nothing is handed back,
  because rotation reaches the proxy through the grant row, which
  `Sessions.authorize/2` reads on every request. No broker rule is rewritten
  and the sandbox file never changes.

  A grant that cannot serve is `{:error, {:chatgpt_grant_unusable, _}}`, the
  same tagged refusal resolution gives, including every reason only the
  credential read can see: an owner who may no longer use a grant
  (`:owner_ineligible`), a refresh token the auth server has just refused
  (`:revoked`). A grant reconnected since the conversation began is
  `:inference_source_changed`, which is what it is. Never another
  credential. A renewal that failed for a reason that may pass (the
  provider was unreachable, another node holds the refresh) lets the turn
  go ahead on the token it has: if that has lapsed the turn fails at the
  proxy with the provider's own answer (ADR 0047's limitation, kept).

  **Must not be called while holding `InferenceCredentials.lock_source/1`.**
  """
  @spec ensure_fresh(String.t(), Source.t() | nil) ::
          :ok | {:error, {:chatgpt_grant_unusable, map()} | :inference_source_changed}
  def ensure_fresh(user_id, source) do
    case managed_grant(source, user_id) do
      %{owner: {:user, owner}, grant_id: grant_id, generation: generation} = ref ->
        case ChatGPTAccounts.ensure_fresh_for_user(grant_id, owner, generation) do
          :ok -> :ok
          {:error, reason} -> renewal_refusal(ref, reason)
        end

      _ ->
        :ok
    end
  end

  defp renewal_refusal(_ref, :stale_grant), do: {:error, :inference_source_changed}

  defp renewal_refusal(ref, reason) when reason in [:disconnected, :revoked, :expired],
    do: {:error, unusable(ref, reason)}

  defp renewal_refusal(ref, :invalid_grant), do: {:error, unusable(ref, :reconnect_required)}

  # The row is there for its owner's metadata read and not for the credential
  # read: the owner is suspended, unverified or a principal. Gone altogether
  # is `:not_found`.
  defp renewal_refusal(ref, :not_connected), do: {:error, unusable(ref, :owner_ineligible)}

  defp renewal_refusal(%{grant_id: grant_id}, reason) do
    Logger.warning(
      "chatgpt grant #{grant_id}: renewal before a turn did not complete (#{inspect(reason)}); " <>
        "the turn runs on the token the grant has"
    )

    :ok
  end

  @doc """
  What a provision or a wake publishes when the reason it failed is the
  grant's, and `nil` for every other reason, which the caller reports as it
  always has.

  `{:broker, :session, :managed_grant_inactive}` is the issuance fence
  refusing to mint a session (`Sessions.create/1`): since this server
  resolved its source the grant was disconnected, reconnected or removed, or
  its owner may no longer use one. A broker failure is otherwise transient
  and published `retryable: true`; this one never passes on a retry. Which
  of those it was is read from the grant's row, and from `ensure_fresh/2`
  when the row is still what was resolved, so the stream says what the
  turn's refusal says (`TurnMachine`): stage 2's tagged reason and sentence,
  or `inference_source_changed` for a reconnect. The same shape for the
  tagged refusal `prepare_sandbox/5` gives.
  """
  @spec refusal_stage(term(), String.t() | nil, Source.t() | nil) :: map() | nil
  def refusal_stage({:broker, :session, :managed_grant_inactive}, user_id, source) do
    with %{} = ref <- managed_grant(source, user_id) do
      case fenced(ref, source) do
        :inference_source_changed -> %{reason: "inference_source_changed", retryable: false}
        refusal -> refusal_stage(refusal, user_id, source)
      end
    end
  end

  def refusal_stage({:chatgpt_grant_unusable, %{reason: reason} = detail}, _user_id, _source) do
    %{
      reason: "chatgpt_grant_unusable",
      grant_reason: Atom.to_string(reason),
      grant_id: detail[:grant_id],
      message: Fountain.InferenceCredentials.grant_unusable_message(detail),
      retryable: false
    }
  end

  def refusal_stage(_reason, _user_id, _source), do: nil

  # Why the fence refused, from the row first: a disconnect is a new
  # generation too, so asking `ensure_fresh/2` first would call every ended
  # grant a changed source. A row that is still what this conversation
  # resolved was refused for its owner or for naming no account, and the
  # credential read tells those apart.
  defp fenced(%{owner: {:user, user_id}, grant_id: grant_id, generation: generation} = ref, source) do
    case ChatGPTAccounts.get_for_user(grant_id, user_id) do
      {:ok, %{status: "active", generation: ^generation}} ->
        case ensure_fresh(user_id, source) do
          {:error, refusal} -> refusal
          :ok -> unusable(ref, :reconnect_required)
        end

      {:ok, %{status: status}} = found when status in ["revoked", "expired"] ->
        unusable(ref, String.to_existing_atom(status), found)

      found ->
        gone(ref, found)
    end
  end

  @doc "Whether a source's codex peer keeps its `auth.json` in a home of its own."
  @spec own_home?(Source.t() | nil) :: boolean()
  def own_home?(%Source{scope: :grant} = source),
    do: match?({:user, _, _}, Source.grant_ref(source))

  def own_home?(_source), do: false

  @doc """
  The `CODEX_HOME` of one sign-in of one grant:
  `/home/sprite/.codex-grants/<grant id>.<generation>`. Both are UUIDs and
  are checked to be, because they become a path: `:error` otherwise.
  """
  @spec home(%{
          required(:grant_id) => String.t(),
          required(:generation) => String.t(),
          optional(atom()) => term()
        }) :: {:ok, String.t()} | :error
  def home(%{grant_id: grant_id, generation: generation}) do
    with {:ok, grant_id} <- Ecto.UUID.cast(grant_id),
         {:ok, generation} <- Ecto.UUID.cast(generation) do
      {:ok, Path.join(homes_root(), grant_id <> "." <> generation)}
    end
  end

  @doc "Where the per-grant homes live: beside the runtime's own config root."
  @spec homes_root() :: String.t()
  def homes_root,
    do: @runtime |> Layout.config_root() |> Path.dirname() |> Path.join(".codex-grants")

  @doc """
  The spawn env entries for a grant, for the codex runtime only.

  On a source with a home of its own (`managed_grant/2`):
  `CODEX_CHATGPT_ACCESS_TOKEN`, the grant's own placeholder, and `CODEX_HOME`.
  Both come from the source, whatever the credentials map holds. On any other
  source, `CODEX_CHATGPT_ACCESS_TOKEN` when the credentials carry it
  (brokered, the placeholder `Fountain.Broker.split_inference/2` put there).

  A `:grant` source that names no grant and generation, or names ones that
  make no path, exports nothing, and `prepare_sandbox/5` refuses the spawn.
  It never falls through to the other sources' entry: that one is followed
  by the deployment's account file in the shared home.
  """
  @spec env(module() | nil, map(), Source.t() | nil) :: [{String.t(), String.t()}]
  def env(Managoat.Runtimes.Codex, credentials, %Source{scope: :grant} = source)
      when is_map(credentials) do
    with {:user, grant_id, generation} <- Source.grant_ref(source),
         {:ok, home} <- home(%{grant_id: grant_id, generation: generation}) do
      [{@env_key, Reserved.placeholder(grant_id)}, {@home_key, home}]
    else
      _ -> []
    end
  end

  def env(Managoat.Runtimes.Codex, credentials, _source) when is_map(credentials) do
    case Map.get(credentials, @credential) do
      value when is_binary(value) and value != "" -> [{@env_key, value}]
      _ -> []
    end
  end

  def env(_runtime_module, _credentials, _source), do: []

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
  Write the sandbox's `auth.json` when this codex spawn runs on a grant.

  For a source with a home of its own (`managed_grant/2`): prepare that home,
  link the shared configuration into it, and write its `auth.json` from a
  read of the grant pinned by owner, id and generation
  (`ChatGPTAccounts.sandbox_auth/1`). A grant that is no longer at that
  generation is `{:error, :inference_source_changed}` when it is active at
  another (it was reconnected; `ensure_fresh/2` says the same) and
  `{:error, {:chatgpt_grant_unusable, _}}` otherwise, never another grant's
  account and never the deployment's. An `OPENAI_API_KEY` beside it
  is an error too: `SpriteEnv.build/4` strips one for such a source, and a
  key that got through would be the silent switch ADR 0060 decision 4
  forbids.

  A `:grant` source with no owner, grant id or generation to pin is
  `{:error, :invalid_codex_home}`; it is never treated as any other source.

  For any other source: `:skip` when the spawn does not carry the
  deployment's grant, or when an `OPENAI_API_KEY` sits beside it (the
  library's `prepare_sandbox/3` then runs as today); `:ok` or
  `{:error, reason}` when it does.
  """
  @spec prepare_sandbox(
          Managoat.Sandbox.Handle.t(),
          String.t(),
          [{String.t(), String.t()}],
          Source.t() | nil,
          String.t() | nil
        ) :: :skip | :ok | {:error, term()}
  def prepare_sandbox(handle, @runtime, sprite_env, source, user_id) do
    case {managed_grant(source, user_id), source} do
      # A user's source that pins nothing: no owner, or a persisted source
      # without its grant id or generation. Refused here, because the shared
      # path below writes the deployment's account, and a user's source must
      # never reach it.
      {nil, %Source{scope: :grant}} -> {:error, :invalid_codex_home}
      {nil, _} -> prepare_shared(handle, sprite_env)
      {ref, _} -> prepare_home(handle, sprite_env, ref)
    end
  end

  def prepare_sandbox(_handle, _runtime, _sprite_env, _source, _user_id), do: :skip

  defp prepare_shared(handle, sprite_env) do
    # A key beside the grant wins, as it does in `CodexTransport`: the
    # tenant's environment or vault may name `OPENAI_API_KEY` without
    # holding an inference credential, and that spawn runs on the key
    # through the library's login, not on this file.
    case {List.keyfind(sprite_env, @env_key, 0), List.keyfind(sprite_env, "OPENAI_API_KEY", 0)} do
      {{@env_key, value}, key}
      when is_binary(value) and value != "" and
             (is_nil(key) or elem(key, 1) in [nil, ""]) ->
        case ChatGPTAccounts.platform_sandbox_auth() do
          {:ok, auth} -> write(handle, Layout.config_root(@runtime), auth_json(value, auth))
          :none -> {:error, :platform_chatgpt_not_connected}
        end

      _ ->
        :skip
    end
  end

  defp prepare_home(handle, sprite_env, ref) do
    with {:ok, home} <- home(ref),
         :ok <- no_api_key(sprite_env),
         {:ok, auth} <- ChatGPTAccounts.sandbox_auth(ref),
         :ok <- link_home(handle, home) do
      body = auth_json(Reserved.placeholder(ref.grant_id), auth)

      case Managoat.Sandbox.write_file(handle, Path.join(home, "auth.json"), body, mode: 0o600) do
        :ok -> :ok
        {:error, reason} -> {:error, {:codex_auth_write, reason}}
      end
    else
      :error -> {:error, :invalid_codex_home}
      :none -> {:error, gone(ref)}
      {:error, _} = error -> error
    end
  end

  defp no_api_key(sprite_env) do
    case List.keyfind(sprite_env, "OPENAI_API_KEY", 0) do
      {_, value} when is_binary(value) and value != "" -> {:error, :codex_grant_key_conflict}
      _ -> :ok
    end
  end

  # Fixed text, with the two paths as positional arguments and never
  # interpolated. Idempotent: it runs on every provision and every reattach.
  # `sessions`, `skills` and `log` are made in the shared root first so that
  # what gets linked is the shared directory, whoever creates it first.
  #
  # Two conversations on one sign-in share a home and may prepare it at the
  # same moment, so a link that is there by the time `ln` runs is what was
  # wanted and not a failure; an `ln` that failed and left nothing still is.
  #
  # Everything under `/home/sprite` is writable by the agent, so the script
  # does not trust what it finds: a home, or the directory of homes, that is
  # a symbolic link is refused (exit 3) rather than prepared wherever it
  # points, which could be another grant's home; and an `auth.json` that is a
  # link is removed, so the write that follows lands in this home. A regular
  # `auth.json` is left for that write to replace, because a peer on the
  # same sign-in may be reading it. This narrows a same-user race and does
  # not close it: a link planted between this script and the write wins.
  @link_script """
  set -eu
  shared=$1
  home=$2
  if [ -L "$home" ] || [ -L "${home%/*}" ]; then
    echo "refusing a codex home that is a symbolic link"
    exit 3
  fi
  mkdir -p "$shared/sessions" "$shared/skills" "$shared/log" "$home"
  chmod 700 "$home"
  for f in "$shared"/* "$shared"/.[!.]*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    n=${f##*/}
    [ "$n" = auth.json ] && continue
    [ -e "$home/$n" ] || [ -L "$home/$n" ] || ln -s "$f" "$home/$n" 2>/dev/null ||
      [ -e "$home/$n" ] || [ -L "$home/$n" ]
  done
  if [ -L "$home/auth.json" ]; then rm -f "$home/auth.json"; fi
  """

  @doc false
  def link_script, do: @link_script

  defp link_home(handle, home) do
    shared = Layout.config_root(@runtime)

    case Managoat.Sandbox.exec(handle, "sh", ["-c", @link_script, "sh", shared, home], []) do
      {:ok, _out, 0} -> :ok
      {:ok, out, code} -> {:error, {:codex_home_prepare, code, out}}
      {:error, reason} -> {:error, {:codex_home_prepare, reason}}
    end
  end

  # The pinned read found no such sign-in: the grant was reconnected,
  # disconnected or removed since this conversation resolved it. A grant that
  # is active at another generation was reconnected, and that is
  # `:inference_source_changed`, the answer `ensure_fresh/2` gives the same
  # fact: the grant is fine and this conversation's source is not it.
  # Anything else is named, like every other refusal of a user's grant, and
  # never answered with a different account.
  defp gone(%{owner: {:user, user_id}, grant_id: grant_id} = ref),
    do: gone(ref, ChatGPTAccounts.get_for_user(grant_id, user_id))

  defp gone(%{generation: generation} = ref, found) do
    case found do
      {:ok, %{status: "active", generation: current}} when current != generation ->
        :inference_source_changed

      found ->
        unusable(ref, :reconnect_required, found)
    end
  end

  defp unusable(%{owner: {:user, user_id}, grant_id: grant_id} = ref, reason),
    do: unusable(ref, reason, ChatGPTAccounts.get_for_user(grant_id, user_id))

  defp unusable(%{grant_id: grant_id}, reason, found) do
    {name, reason} =
      case found do
        {:ok, %{name: name, status: "disconnected"}} -> {name, :disconnected}
        {:ok, %{name: name}} -> {name, reason}
        {:error, :not_found} -> {nil, :not_found}
      end

    {:chatgpt_grant_unusable, %{grant_id: grant_id, name: name, reason: reason, until: nil}}
  end

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

  @doc "Where the shared file goes: `~/.codex/auth.json`, under the runtime's layout."
  @spec auth_path() :: String.t()
  def auth_path, do: Path.join(Layout.config_root(@runtime), "auth.json")

  defp write(handle, dir, body) do
    with {:ok, _out, 0} <- Managoat.Sandbox.exec(handle, "mkdir", ["-p", dir], []),
         :ok <-
           Managoat.Sandbox.write_file(handle, Path.join(dir, "auth.json"), body, mode: 0o600) do
      :ok
    else
      {:ok, out, code} -> {:error, {:codex_auth_mkdir, code, out}}
      {:error, reason} -> {:error, {:codex_auth_write, reason}}
    end
  end
end
