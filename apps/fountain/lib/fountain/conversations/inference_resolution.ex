defmodule Fountain.Conversations.InferenceResolution do
  @moduledoc """
  The two shapes of resolver call a conversation makes, built in one place.

  `Fountain.InferenceCredentials.resolve/4` takes three options, and a
  conversation reaches it at five moments (ADR 0053). Admission (launch and
  attach) is a **new selection**: the user's credential record, and the
  environment and vault the conversation will run against. Wake, resume,
  provision and reapply are a **re-validation**: the stored source is the
  `expected_source`, and a different result is `:inference_source_changed`.
  Each site used to build its own keyword list.

  A re-validation still names the environment and vault the conversation
  runs against **now**, not the ones the stored source names: wake passes
  the agent's current environment and provision the rows it loaded, and a
  configuration that moved since admission is exactly what the comparison
  is there to refuse.
  """

  alias Fountain.InferenceCredentials

  @typedoc "What `Fountain.InferenceCredentials.resolve/4` returns."
  @type result ::
          {:ok, InferenceCredentials.Source.t(), %{atom() => String.t()}} | {:error, atom()}

  @doc """
  The model a conversation runs: its own override (ADR 0061), else its
  agent's. Nil for a conversation with neither, which the `acp` runtime is.
  """
  @spec model(map(), map() | nil) :: String.t() | nil
  def model(conv, agent), do: Map.get(conv, :model) || (agent && agent.model)

  @doc """
  A new selection, for admission: its environment override
  (`:environment_id`, nil for the agent's), its vault (`:vault_id`) and its
  model override (`:model`, nil for the agent's).
  """
  @spec select(binary(), map(), keyword()) :: result()
  def select(user_id, agent, opts) do
    opts = Keyword.validate!(opts, [:environment_id, :vault_id, :model])

    InferenceCredentials.resolve(user_id, model(%{model: opts[:model]}, agent), agent.runtime,
      environment_id: opts[:environment_id] || agent.environment_id,
      vault_id: opts[:vault_id]
    )
  end

  @doc """
  A re-validation against a stored source, for wake, resume, provision and
  reapply: the conversation's `inference_source` is the expected source and
  its `runtime` the runtime, `model/2` is the model, and
  `:environment_id` / `:vault_id` are the rows it runs against now.

  Reapply is the one caller that overrides `:expected_source` (the stored
  source with the new configuration merged in), `:runtime` (the agent's,
  which the row takes only after the source is resolved) and `:model` (the
  selection's, for the same reason).

  The conversation's override is read here, not by each caller, because a
  caller that passed the agent's model for an overridden conversation would
  read as `:inference_source_changed` on its next wake.
  """
  @spec revalidate(map(), map() | nil, keyword()) :: result()
  def revalidate(conv, agent, opts) do
    opts =
      Keyword.validate!(opts, [:expected_source, :runtime, :environment_id, :vault_id, :model])

    InferenceCredentials.resolve(
      conv.user_id,
      Keyword.get_lazy(opts, :model, fn -> model(conv, agent) end),
      Keyword.get(opts, :runtime, conv.runtime),
      expected_source: Keyword.get(opts, :expected_source, conv.inference_source),
      environment_id: opts[:environment_id],
      vault_id: opts[:vault_id]
    )
  end
end
