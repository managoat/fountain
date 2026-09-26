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

  ## A home per grant and generation

  Every grant has one, the deployment's and a user's alike
  (`managed_grant/2`). Everything comes from the resolved source, by owner,
  grant id and generation, and nothing from a deployment-wide lookup:

    * the file is `<home>/auth.json` under a `CODEX_HOME` of the grant's own,
      `/home/sprite/.codex-grants/<grant id>.<generation>` (`home/1`), and
      `env/3` exports that `CODEX_HOME` to the process and to nothing on the
      disk (`Fountain.Conversations.Identity`). Two conversations of one
      agent on one persistent sandbox, on two of a user's subscriptions,
      therefore read two files and cannot overwrite each other's account
      (ADR 0052 decision 5). A conversation is pinned to one grant and
      generation for life, so its home never moves; a reconnect is a new
      generation, a new home and a new conversation.
    * what `~/.codex` holds **when the home is prepared** is shared, through
      symbolic links: `config.toml` as Fountain wrote it, `AGENTS.md`,
      `skills/`, and `sessions/`, so `thread/resume` finds a rollout
      wherever the conversation that wrote it ran. `auth.json` is never
      linked. Same unix user, so this prevents overwrite and
      mis-attribution, not reads: a peer that reads another grant's file
      gets a placeholder and an account id, and its own broker session still
      sends only its own grant's bearer and account.
    * **the sharing is order-dependent, and nothing else is promised.** The
      script links the entries that exist when it runs and skips a name the
      home already has. Whatever codex first creates under its own
      `CODEX_HOME` (its sqlite state, `history.jsonl`, a `config.toml` it
      rewrites by atomic rename) is a real file private to that home and
      shadows the shared name from then on. Two grant conversations on a
      fresh machine get separate sqlite state; on a machine whose `~/.codex`
      already holds it they share it through the link. For #1910 (codex's
      sqlite state is not isolated per conversation on a shared sandbox)
      that is neither reliably better nor worse: a home is per grant and
      generation, not per conversation, and `CODEX_SQLITE_HOME`, which
      #1910 prefers, is not set here.
    * the placeholder is the grant's own (`Reserved.placeholder/1`).

  **Not measured against a real client, and the deployment's grant is on
  this path too.** `managoat_runtimes` fixes codex's config root
  (`Managoat.Runtimes.Layout`) and neither it nor `managoat_acp` reads
  `CODEX_HOME`; the symlinked home is Fountain's way round that without a
  library release. That codex-acp and the codex CLI honour `CODEX_HOME`,
  resume a session through a linked `sessions/`, and find skills through a
  linked `skills/` is asserted from their source, not observed. The
  deployment's grant has run production turns since 2026-09-08 (ADR 0047),
  so for it this is a gate on the merge and not only on a later stage: ADR
  0060, "The platform move is gated on a measurement", says what to run and
  what a failure looks like. The same has to be measured before a user can
  link a subscription.

  An API-key source keeps the shared `~/.codex/auth.json`, which the
  library's `codex login` writes; no grant writes there any more.
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

  A user's subscription (`scope: :grant`) and the deployment's grant (the
  `:platform` source of kind `:codex_chatgpt_access_token`) both are: ADR
  0052 decision 6 covers "both user and platform grants".
  """
  @spec managed_grant(Source.t() | nil, String.t() | nil) :: ChatGPTAccounts.grant_ref() | nil
  def managed_grant(%Source{} = source, user_id) do
    case Source.grant_ref(source) do
      {:user, grant_id, generation} when is_binary(user_id) ->
        %{owner: {:user, user_id}, grant_id: grant_id, generation: generation}

      {:platform, grant_id, generation} ->
        %{owner: :platform, grant_id: grant_id, generation: generation}

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

      # The deployment's grant, as it has always been renewed before a turn
      # (ADR 0047 decision 5), less the token: a renewal that fails, or a
      # grant gone revoked, does not stop the turn here. The proxy refuses
      # it with the reason, and the next turn's validation sees the source
      # change. There is one platform grant, so there is no id to pass; the
      # generation is checked where it matters, on every request.
      %{owner: :platform} ->
        _ = ChatGPTAccounts.platform_ensure_fresh()
        :ok

      nil ->
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
      until: detail[:until],
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
  defp fenced(%{owner: {:user, user_id}, generation: generation} = ref, source) do
    case ChatGPTAccounts.get_for_user(ref.grant_id, user_id) do
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

  # The deployment's grant has no sentence of stage 2's, so the caller
  # reports the fence as it reports any other reason. The next turn's
  # validation sees the source change.
  defp fenced(%{owner: :platform}, _source), do: :platform_chatgpt_not_connected

  @doc "Whether a source's codex peer keeps its `auth.json` in a home of its own."
  @spec own_home?(Source.t() | nil) :: boolean()
  def own_home?(source), do: Source.grant_ref(source) != nil

  @doc """
  Whether a source is outside the machine's one-source Codex binding
  (`Fountain.Machines.Binding.bind_inference/2`): a user's subscription.

  The deployment's grant has a home of its own too and could be, but is
  deliberately left under the binding. What a persistent home does when the
  platform account hits its usage limit and when that resets is published
  behaviour (ADR 0047 decision 6 as amended by #2362,
  `docs/configuration.md`): the home keeps the source it started on.
  Lifting the binding for it would change that, and is a decision of its
  own.
  """
  @spec outside_machine_binding?(Source.t() | nil) :: boolean()
  def outside_machine_binding?(source), do: match?({:user, _, _}, Source.grant_ref(source))

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

  On a grant (`managed_grant/2`): `CODEX_CHATGPT_ACCESS_TOKEN`, the grant's
  own placeholder, and `CODEX_HOME`. Both come from the source, whatever the
  credentials map holds. On any other source, nothing.

  A `:grant` source that names no grant and generation, or names ones that
  make no path, exports nothing too, and `prepare_sandbox/5` refuses the
  spawn rather than leave it to the library's `codex login`.
  """
  @spec env(module() | nil, map(), Source.t() | nil) :: [{String.t(), String.t()}]
  def env(Managoat.Runtimes.Codex, credentials, source) when is_map(credentials) do
    with {_owner, grant_id, generation} <- Source.grant_ref(source),
         {:ok, home} <- home(%{grant_id: grant_id, generation: generation}) do
      [{@env_key, Reserved.placeholder(grant_id)}, {@home_key, home}]
    else
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

  For a grant (`managed_grant/2`): prepare its home, link the shared
  configuration into it, and write its `auth.json` from a read of the grant
  pinned by owner, id and generation (`ChatGPTAccounts.sandbox_auth/1`). A
  user's grant that is no longer at that generation is
  `{:error, :inference_source_changed}` when it is active at another (it was
  reconnected; `ensure_fresh/2` says the same) and
  `{:error, {:chatgpt_grant_unusable, _}}` otherwise; the deployment's is
  `{:error, :platform_chatgpt_not_connected}`. Never another grant's
  account. An `OPENAI_API_KEY` beside a grant is
  `{:error, :codex_grant_key_conflict}`. `SpriteEnv.build/4` strips one for
  a user's source, and a key that got through would be the silent switch ADR
  0060 decision 4 forbids. Beside the deployment's grant the key used to win
  and the answer was `:skip`. It cannot any more: by then `env/3` has
  exported a `CODEX_HOME` that a skip would never create, and the broker
  session is the grant's HTTP-only one (`Egress.session_opts/1`), so the
  library's `codex login` would run against a home that is not there. The
  resolver is believed never to hand out both, and if it does the provision
  says so rather than half-running on each.

  A `:grant` source with no owner, grant id or generation to pin is
  `{:error, :invalid_codex_home}`; it is never treated as any other source.

  `:skip` for every other source and runtime: the library's
  `prepare_sandbox/3` then runs as today.
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
      # without its grant id or generation. Refused here, because `:skip`
      # hands the spawn to the library's `codex login`, and a user's source
      # must never reach a credential it did not name.
      {nil, %Source{scope: :grant}} -> {:error, :invalid_codex_home}
      {nil, _} -> :skip
      {ref, _} -> prepare_home(handle, sprite_env, ref)
    end
  end

  def prepare_sandbox(_handle, _runtime, _sprite_env, _source, _user_id), do: :skip

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
  #
  # Last, a home with no `config.toml` (neither its own nor a link to the
  # shared one) gets one that turns Codex's analytics off (#2503). Codex
  # builds its analytics client once per app-server from this file; the
  # per-thread `CODEX_CONFIG` overlay does not reach it. The broker lets the
  # posts through, and this only stops them from being sent at all. A file
  # already there, whoever wrote it, is left alone, and so is its analytics
  # setting. The write uses noclobber (`O_EXCL`), so it creates the file
  # and never follows a link planted since the check.
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
  if [ ! -e "$home/config.toml" ] && [ ! -L "$home/config.toml" ]; then
    (set -C; printf '[analytics]\nenabled = false\n' > "$home/config.toml") 2>/dev/null || true
  fi
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
  #
  # The deployment's grant has one answer, the one it has always had.
  defp gone(%{owner: :platform}), do: :platform_chatgpt_not_connected

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
end
