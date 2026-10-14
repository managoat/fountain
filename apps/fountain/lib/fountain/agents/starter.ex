defmodule Fountain.Agents.Starter do
  @moduledoc """
  The one agent every account is verified into owning (ADR 0038 decision 4).

  It exists so that a freshly verified account has something to send a first
  request to. Before it, the first screen asked for an inference credential, an
  agent and a conversation before anything could run.

  What it is *not* is a special kind of agent. There is no flag on the row, no
  branch that reads its name, and nothing that recreates it: it is listed,
  edited, launched and deleted exactly like an agent the developer wrote. This
  module holds the definition and the one call site that plants it, and that is
  the whole of its existence in the codebase.

  Its inference runs on the platform key while the account has no credential of
  its own (#1388); the selection rule lives there, not here. On a deployment
  with no platform key the first run fails with the existing "no credential"
  error, which is where the account was starting from anyway.

  The canned manifests under `examples/agents/` were the other candidate source
  for this definition (#1010). The only one is `fountain-contributor`, which
  needs an environment, a repository and a GitHub token — the three costs this
  agent exists to remove — so the definition below is its own.
  """

  alias Fountain.Agents

  @name "starter"
  @runtime "claude"
  @model "anthropic/claude-sonnet-5"

  @description "The agent this account started with. Runs on Fountain's " <>
                 "inference key until you add your own. Edit it or delete it freely."

  @system """
  You are `starter`, the agent Fountain put in this account when it was
  verified. You exist so that there is something to send a first request to.

  While this account has no inference credential of its own, your model runs on
  the deployment's platform key, when it has one. Adding a credential on the
  credentials page moves you onto that key. Nothing here changes when it does.

  You are an ordinary agent. Change the model, this prompt, the environment and
  the skills, or delete this agent and write your own with `fountain apply`.

  No environment is attached, so you run in a plain sandbox: no repository, no
  extra packages and no MCP servers. Answer what you are asked. When a request
  needs a repository or a tool you do not have, say what is missing and where it
  is configured rather than guessing at it.
  """

  @doc "The agent's name. `starter`, and the tenant may rename it the next minute."
  @spec name() :: String.t()
  def name, do: @name

  @doc """
  The attrs the starter agent is created from, for `user_id`.

  String-keyed, so it reads the way every other `create_agent/2` call site and
  the factories do.
  """
  @spec attrs(binary()) :: map()
  def attrs(user_id) when is_binary(user_id) do
    %{
      "user_id" => user_id,
      "name" => @name,
      "runtime" => @runtime,
      "model" => @model,
      "description" => @description,
      "system" => @system
    }
  end

  @doc """
  Create the starter agent for `user_id`.

  Idempotent per account by name: an account that already has an agent called
  `starter` gets nothing, which is what makes a re-run of a verification route
  harmless. It is *not* a resurrection — the call site fires on the
  unverified-to-verified transition only, so deleting the agent afterwards
  leaves it deleted.

  Returns `{:ok, agent}`, `{:ok, :exists}`, or the changeset error. Callers on
  the verification path treat every outcome as non-fatal; see
  `Fountain.Accounts.verify_email/2`.
  """
  @spec create_for(binary(), keyword()) ::
          {:ok, Agents.Agent.t()} | {:ok, :exists} | {:error, Ecto.Changeset.t()}
  def create_for(user_id, opts \\ []) when is_binary(user_id) do
    case Agents.get_agent_by_name(@name, user_id) do
      nil -> Agents.create_agent(attrs(user_id), Keyword.put_new(opts, :actor, actor()))
      _agent -> {:ok, :exists}
    end
  end

  @doc """
  The audit actor for the planting, `system:onboarding` (ADR 0013).

  Not `self`: nobody asked for this agent, and a trail that said the account
  created it would be describing an account action that never happened.
  """
  @spec actor() :: String.t()
  def actor, do: "system:onboarding"
end
