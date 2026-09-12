defmodule Fountain.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Environments.Environment
  alias Fountain.PermissionPolicy
  alias Fountain.RuntimeDispatch
  alias Managoat.Runtimes.Model

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `acp` is the odd one (#1634): not a coding-agent CLI but a command the
  # agent names, launched inside the sandbox and spoken to over the same
  # protocol. It takes a `runtime_command` and needs no model, and the other
  # four are the reverse of both. See `Fountain.RuntimeDispatch`.
  @runtimes ~w(claude codex gemini opencode acp)

  @typedoc "A persisted agent."
  @type t :: %__MODULE__{}

  schema "agents" do
    field :name, :string
    field :description, :string, default: ""
    field :system, :string, default: ""
    field :model, :string
    field :runtime, :string
    # The command the `acp` runtime launches, as a shell line resolved inside
    # the sandbox (#1634). Required for that runtime and refused for every
    # other one, which resolves its own executable from a pinned table.
    field :runtime_command, :string
    # Optional sandbox-backend override; nil inherits the instance default
    # (SANDBOX_PROVIDER) at conversation start.
    field :sandbox_provider, :string
    # Where a conversation of this agent runs by default (ADR 0023):
    # `ephemeral`, a sandbox per conversation, or `persistent`, one sandbox
    # per agent identity that every conversation lands on — the agent's
    # computer. A launch may name the other; this is the default, not a rule.
    field :sandbox_mode, :string, default: "ephemeral"
    # Each entry is one of:
    #   %{"name" => name, "content" => skill_md}     # inline SKILL.md
    #   %{"source" => "owner/repo", "name" => opt}   # github via skills.sh CLI
    field :skills, {:array, :map}, default: []
    field :mcp_servers, :map, default: %{}
    field :metadata, :map, default: %{}
    # Vaults a conversation may attach to this agent. nil = any tenant
    # vault (legacy), [] = none, non-empty = allowlist. Vault values win
    # on env-var collision, so an attached vault can override reviewed
    # agent config — this is the lever that scopes who can do that.
    field :allowed_vault_ids, {:array, :binary_id}
    # Environments a conversation may launch this agent under instead of its
    # own (#783). Same shape: nil = any tenant environment, [] = none,
    # non-empty = allowlist. An override *replaces* the reviewed environment
    # wholesale, so it is scoped the same way a vault override is.
    field :allowed_environment_ids, {:array, :binary_id}
    # Credential sets a conversation may launch this agent on instead of the
    # agent's (ADR 0053 decision 3). Same shape again: nil = any set the
    # tenant owns, [] = none, non-empty = allowlist. Naming a set changes
    # whose provider account pays for the turn, which is the reason it is
    # scoped rather than free.
    field :allowed_inference_credential_ids, {:array, :binary_id}
    # Per-tool permission policy (#939): %{"default" => "auto_allow",
    # "Bash" => "auto_deny"}. Empty means no opinion, which resolves to
    # auto_allow — what every agent does today. A launch may supply its own,
    # but only to narrow this one; see Managoat.ACP.Permissions.
    field :permission_policy, :map, default: %{}
    field :avatar_media_type, :string
    field :conversation_count, :integer, virtual: true, default: 0
    belongs_to :user, User
    belongs_to :environment, Environment
    # Which credential set this agent's conversations run on (ADR 0053
    # decision 3). nil is the account's default set, which is what every
    # agent had before there was more than one.
    belongs_to :inference_credential, Fountain.InferenceCredentials.Credential
    timestamps(type: :utc_datetime)
  end

  @doc "Every runtime that can appear in persisted data, including the opt-in test fixture."
  def known_runtimes, do: @runtimes ++ ["fountain-fixture"]

  def runtimes do
    if Fountain.DeployedACPFixture.enabled?(),
      do: known_runtimes(),
      else: @runtimes
  end

  @sandbox_modes ~w(ephemeral persistent)

  @doc "The sandbox modes a launch may choose (ADR 0023)."
  def sandbox_modes, do: @sandbox_modes

  @doc false
  def cast_fields,
    do: [
      :name,
      :description,
      :system,
      :model,
      :runtime,
      :runtime_command,
      :sandbox_provider,
      :sandbox_mode,
      :skills,
      :mcp_servers,
      :metadata,
      :allowed_vault_ids,
      :allowed_environment_ids,
      :allowed_inference_credential_ids,
      :permission_policy,
      :user_id,
      :environment_id,
      :inference_credential_id
    ]

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, cast_fields())
    |> validate_required([:name, :runtime])
    |> validate_inclusion(:runtime, runtimes())
    |> validate_fixture_account()
    |> validate_inclusion(:sandbox_mode, @sandbox_modes)
    |> validate_model_presence()
    |> validate_runtime_command()
    |> validate_format(:model, ~r{^[a-z0-9_-]+/[a-z0-9._-]+$},
      message: "must be in canonical provider/model_id form"
    )
    |> validate_model_provider()
    |> validate_sandbox_provider()
    |> validate_length(:name, min: 1, max: 200)
    |> Fountain.Changeset.validate_ids([
      :user_id,
      :environment_id,
      :inference_credential_id,
      :allowed_vault_ids,
      :allowed_inference_credential_ids,
      :allowed_environment_ids
    ])
    |> validate_skills()
    |> validate_mcp_servers()
    |> validate_permission_policy()
    |> unique_constraint(:name, name: :agents_user_id_name_index)
    |> foreign_key_constraint(:environment_id)
    |> foreign_key_constraint(:inference_credential_id)
  end

  defp validate_fixture_account(changeset) do
    if get_field(changeset, :runtime) == "fountain-fixture" do
      changeset =
        if Fountain.DeployedACPFixture.allowed?(get_field(changeset, :user_id)),
          do: changeset,
          else: add_error(changeset, :runtime, "fixture is not enabled for this account")

      Enum.reduce([:skills, :mcp_servers, :system], changeset, fn field, acc ->
        if get_field(acc, field) in [nil, [], %{}, ""],
          do: acc,
          else: add_error(acc, field, "is not supported by the scripted fixture")
      end)
    else
      changeset
    end
  end

  # `model` is required for every runtime but `acp`, where it is optional and
  # inert: that runtime resolves no inference credential, so a model would be
  # a field nothing reads. It is still accepted, and still has to parse and
  # name a known provider if it is given, because a value that is stored and
  # ignored is worse than one that is refused.
  defp validate_model_presence(changeset) do
    if RuntimeDispatch.model_required?(get_field(changeset, :runtime)) do
      validate_required(changeset, [:model])
    else
      changeset
    end
  end

  # The command is the whole configuration of the `acp` runtime and means
  # nothing to any other, so it is required for one and refused for the rest.
  # Refused rather than ignored: a `runtime_command` sitting on a claude agent
  # reads as something that runs, and nothing would ever run it.
  defp validate_runtime_command(changeset) do
    runtime = get_field(changeset, :runtime)
    command = get_field(changeset, :runtime_command)

    cond do
      RuntimeDispatch.command_required?(runtime) ->
        # `validate_required/2` trims, so a blank line is a missing command
        # rather than one that spawns an empty shell.
        validate_required(changeset, [:runtime_command])

      is_nil(command) or String.trim(command) == "" ->
        changeset

      true ->
        add_error(
          changeset,
          :runtime_command,
          "only the acp runtime launches a command; #{runtime || "this runtime"} resolves its own"
        )
    end
  end

  # claude / codex / gemini each drive a single provider's CLI and take a
  # bare model id, so the runtime strips the canonical prefix at spawn.
  # Reject a mismatched prefix here rather than shipping `gpt-5` to
  # `claude --model`: before #553 those runtimes ignored the field
  # entirely, so `openai/gpt-5` on a claude agent looked configured and
  # silently ran the CLI's own default.
  #
  # opencode takes any *known* prefix. It is multi-provider but not
  # open-ended: it reads the prefix to pick which API key to export, and
  # Fountain only holds three (`InferenceCredentials.Credential`). A
  # misspelled provider used to fall through to no credentials at all and
  # fail as an auth error inside the sprite, so reject it here too (#554).
  #
  # The model id itself is never checked — a model released since the last
  # deploy has to work the day it ships.
  defp validate_model_provider(changeset) do
    if get_field(changeset, :runtime) == "fountain-fixture" do
      validate_inclusion(changeset, :model, ["fixture/deterministic-v1"])
    else
      validate_packaged_model_provider(changeset)
    end
  end

  defp validate_packaged_model_provider(changeset) do
    case Model.provider(get_field(changeset, :model)) do
      nil -> changeset
      actual -> validate_provider(changeset, actual, get_field(changeset, :runtime))
    end
  end

  defp validate_provider(changeset, actual, runtime) do
    case Model.provider_for_runtime(runtime) do
      nil -> validate_known_provider(changeset, actual)
      ^actual -> changeset
      expected -> add_error(changeset, :model, "#{runtime} runtime requires a #{expected}/ model")
    end
  end

  defp validate_known_provider(changeset, provider) do
    if Model.known_provider?(provider) do
      changeset
    else
      add_error(
        changeset,
        :model,
        "unknown provider \"#{provider}\" — must be one of: #{Enum.join(Model.providers(), ", ")}"
      )
    end
  end

  # Distinct from the *model* provider above: this picks which sandbox
  # backend the agent's conversations run on. Nil inherits the instance
  # default. Only validated when the field changes, so removing a provider's
  # credentials later does not brick unrelated edits to existing agents —
  # conversation start re-checks enabledness anyway.
  defp validate_sandbox_provider(changeset) do
    validate_change(changeset, :sandbox_provider, fn :sandbox_provider, value ->
      cond do
        value not in Fountain.SandboxProviders.known_providers() ->
          [
            sandbox_provider:
              "must be one of: " <> Enum.join(Fountain.SandboxProviders.known_providers(), ", ")
          ]

        not Fountain.SandboxProviders.enabled?(String.to_existing_atom(value)) ->
          [sandbox_provider: "is not configured on this instance"]

        true ->
          []
      end
    end)
  end

  # A policy is a flat map of tool name (or "default") to verdict. Validated
  # here rather than trusted, because `Permissions.verdict_for/2` treats an
  # unrecognised value as `auto_deny` — safe, but a silent deny on a typo is a
  # bad way to find out. `ask` is a real verdict with nowhere to ask until #940
  # builds the stream event and the answer endpoint, so it is refused at the
  # door instead of degrading to an allow or hanging the turn.
  defp validate_permission_policy(changeset) do
    validate_change(changeset, :permission_policy, fn :permission_policy, policy ->
      cond do
        not is_map(policy) ->
          [permission_policy: "must be a map of tool name to verdict"]

        true ->
          verdicts = PermissionPolicy.verdicts(policy)

          Enum.flat_map(verdicts, fn {tool, verdict} -> policy_errors(tool, verdict) end) ++
            reserved_errors(policy) ++
            runtime_errors(changeset, verdicts)
      end
    end)
  end

  defp reserved_errors(policy) do
    Enum.map(PermissionPolicy.reserved_errors(policy), fn {key, message} ->
      {:permission_policy, "#{key}: #{message}"}
    end)
  end

  # A policy the runtime will never consult is refused rather than stored. The
  # verdicts are carried by `session/request_permission`, and opencode does not
  # send it — measured live, see `Managoat.Runtimes.ACP.asks_permission?/1`. An
  # accepted-but-inert `auto_deny` is the worst of the three outcomes: it reads
  # like protection on every screen that shows it.
  defp runtime_errors(changeset, policy) do
    runtime = Ecto.Changeset.get_field(changeset, :runtime)

    if not Managoat.ACP.Permissions.needs_enforcement?(policy) or
         Fountain.RuntimeDispatch.asks_permission?(runtime) do
      []
    else
      [
        permission_policy:
          "the #{runtime} runtime never asks before it runs a tool, so a policy " <>
            "stricter than auto_allow cannot be enforced on it"
      ]
    end
  end

  defp policy_errors(tool, verdict) do
    cond do
      not is_binary(tool) or tool == "" ->
        [permission_policy: "tool names must be non-empty strings"]

      verdict not in Managoat.ACP.Permissions.verdicts() ->
        [
          permission_policy:
            "#{tool}: unknown verdict #{inspect(verdict)} " <>
              "(one of #{Enum.join(Managoat.ACP.Permissions.verdicts(), ", ")})"
        ]

      not Managoat.ACP.Permissions.buildable?(verdict) ->
        [permission_policy: "#{tool}: #{verdict} is not built yet — see #940"]

      true ->
        []
    end
  end

  # An entry may name a connection instead of a server (#1178):
  # `%{"connection" => "<id>"}`, rewritten at spawn into the Fountain-served
  # server. Only the shape is checked here — a connection that is gone or
  # revoked by the time a conversation runs fails at the tool call with a
  # reason, which is the contract; a changeset cannot know the future.
  defp validate_mcp_servers(changeset) do
    validate_change(changeset, :mcp_servers, fn :mcp_servers, servers ->
      if is_map(servers) do
        servers
        |> Enum.filter(fn {_name, entry} ->
          is_map(entry) and Map.has_key?(entry, "connection")
        end)
        |> Enum.reject(fn {_name, %{"connection" => id}} ->
          is_binary(id) and match?({:ok, _}, Ecto.UUID.dump(id))
        end)
        |> Enum.map(fn {name, _} ->
          {:mcp_servers, "#{name}: connection must be a connection id"}
        end)
      else
        [mcp_servers: "must be a map of server name to server config"]
      end
    end)
  end

  defp validate_skills(changeset) do
    validate_change(changeset, :skills, fn :skills, skills ->
      skills
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, i} -> skill_errors(entry, i) end)
    end)
  end

  defp skill_errors(entry, i) when is_map(entry) do
    has_content = is_binary(Map.get(entry, "content") || Map.get(entry, :content))
    has_source = is_binary(Map.get(entry, "source") || Map.get(entry, :source))
    name = Map.get(entry, "name") || Map.get(entry, :name)
    ref = Map.get(entry, "ref") || Map.get(entry, :ref)

    cond do
      has_content and has_source ->
        [skills: "entry #{i}: only one of content or source may be set"]

      not has_content and not has_source ->
        [skills: "entry #{i}: must set content (inline) or source (github)"]

      has_content and not is_binary(name) ->
        [skills: "entry #{i}: inline skills require a name"]

      has_content and not is_nil(ref) ->
        [skills: "entry #{i}: ref only applies to github-sourced skills"]

      not is_nil(ref) and not valid_ref?(ref) ->
        [skills: "entry #{i}: ref must match [A-Za-z0-9._/-]+ (tag, branch, or sha)"]

      true ->
        []
    end
  end

  defp skill_errors(_entry, i), do: [skills: "entry #{i}: must be an object"]

  # Mirrors Managoat.Runtimes.Skills.safe_token!/1 — the ref is interpolated into the
  # sprite-side install command, so reject anything outside the allow-list
  # at write time instead of failing the spawn later.
  defp valid_ref?(ref) when is_binary(ref), do: Regex.match?(~r{\A[A-Za-z0-9._/-]+\z}, ref)
  defp valid_ref?(_), do: false
end
