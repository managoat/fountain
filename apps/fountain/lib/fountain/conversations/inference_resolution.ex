defmodule Fountain.Conversations.InferenceResolution do
  @moduledoc """
  The two shapes of resolver call a conversation makes, built in one place.

  `Fountain.InferenceCredentials.resolve/4` takes four options, and a
  conversation reaches it at five moments (ADR 0053). Admission (launch and
  attach) is a **new selection**: which set (the launch's override, else
  the agent's, else the account default), and the environment and vault the
  conversation will run against. Wake, resume, provision and reapply are a
  **re-validation**: the stored source is the `expected_source`, the
  resolver takes the set from it, and a different result is
  `:inference_source_changed`. Each site used to build its own keyword
  list.

  A re-validation still names the environment and vault the conversation
  runs against **now**, not the ones the stored source names: wake passes
  the agent's current environment and provision the rows it loaded, and a
  configuration that moved since admission is exactly what the comparison
  is there to refuse.

  It also still names the set the conversation or its agent points at.
  The resolver ignores that whenever an `expected_source` is present (the
  stored source carries `set_id`), but a conversation admitted before
  sources were stored has none, and re-validating it is a new selection:
  on the set it names, not the account default. Channel resume reserves
  what this returns, and the binding's legacy branch persists it, so
  dropping the set here would pin such a conversation to the wrong
  credential for good.
  """

  alias Fountain.InferenceCredentials

  @typedoc "What `Fountain.InferenceCredentials.resolve/4` returns."
  @type result ::
          {:ok, InferenceCredentials.Source.t(), %{atom() => String.t()}} | {:error, atom()}

  @doc """
  The credential set a selection names: the set pinned in a conversation's
  stored source; else the conversation's own `inference_credential_id` (a
  launch override, ADR 0053 decision 3); else the agent's; else `nil`, the
  account default.

  Admission persists the resolved source; wake and resume retain that
  binding even after the agent or account default changes. A stored nil
  set ID means that selection had no credential set and stays nil.
  """
  @spec credential_set_id(map(), map() | nil) :: binary() | nil
  def credential_set_id(conv, agent) do
    case Map.get(conv, :inference_source) do
      %{} = source -> source["set_id"]
      _ -> Map.get(conv, :inference_credential_id) || (agent && agent.inference_credential_id)
    end
  end

  @doc """
  A new selection, for admission: the launch's set override (`:credential_set_id`,
  nil for the agent's set), its environment override (`:environment_id`,
  nil for the agent's) and its vault (`:vault_id`).
  """
  @spec select(binary(), map(), keyword()) :: result()
  def select(user_id, agent, opts) do
    opts = Keyword.validate!(opts, [:credential_set_id, :environment_id, :vault_id])

    InferenceCredentials.resolve(user_id, agent.model, agent.runtime,
      credential_set_id:
        credential_set_id(%{inference_credential_id: opts[:credential_set_id]}, agent),
      environment_id: opts[:environment_id] || agent.environment_id,
      vault_id: opts[:vault_id]
    )
  end

  @doc """
  A re-validation against a stored source, for wake, resume, provision and
  reapply: the conversation's `inference_source` is the expected source and
  its `runtime` the runtime, the agent's model is the model, and
  `:environment_id` / `:vault_id` are the rows it runs against now. The set
  comes from the expected source; with none stored, from the conversation
  or its agent (`credential_set_id/2`).

  Reapply is the one caller that overrides `:expected_source` (the stored
  source with the new configuration merged in) and `:runtime` (the agent's,
  which the row takes only after the source is resolved).
  """
  @spec revalidate(map(), map() | nil, keyword()) :: result()
  def revalidate(conv, agent, opts) do
    opts = Keyword.validate!(opts, [:expected_source, :runtime, :environment_id, :vault_id])

    InferenceCredentials.resolve(
      conv.user_id,
      agent && agent.model,
      Keyword.get(opts, :runtime, conv.runtime),
      expected_source: Keyword.get(opts, :expected_source, conv.inference_source),
      credential_set_id: credential_set_id(conv, agent),
      environment_id: opts[:environment_id],
      vault_id: opts[:vault_id]
    )
  end
end
