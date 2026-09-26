defmodule Fountain.Conversations.CotenantSecrets do
  @moduledoc """
  A conversation's redaction registry on a **mixed-runtime** machine: one that
  also carries live conversations of another runtime (#2513, tracker #2517).

  `Fountain.Conversations.Redaction` is keyed by conversation, and each
  conversation registers its own secrets (`SpriteEnv.build/4`). That is enough
  while every conversation on a disk runs the same runtime from the same
  environment and vault: they were handed the same values. It is not enough
  once a `claude` and a `codex` conversation share a disk. Every process there
  runs as one unix user, and each runtime's inference credential lives where
  the other can read it: codex's API key in `~/.codex/auth.json` (written by
  `codex login --with-api-key`) and in its process environment, claude's in
  its own. Without this, a `cat ~/.codex/auth.json` in the claude
  conversation would print a value registered only for the codex
  conversation, and `log_events` would store it in the clear. The attach rule
  admits no second runtime yet (#2515), so this is dormant until it does.

  So on a mixed machine each conversation also registers the inference
  credential values of every co-tenant of another runtime (`register/2`).
  They are recomputed from the database, not asked of the co-tenant's server
  (which may be on another node, or between wakes): the co-tenant's agent and
  its stored `inference_source`, re-validated against its environment and
  vault by `InferenceResolution.revalidate/3`. That path is read-only — one
  transaction holding the per-user source lock (advisory locks, no row
  writes), no reservation, no audit and no provider I/O; a ChatGPT grant is
  read by metadata only and never renewed there. Registration is `Redaction.add/2`,
  so nothing registered is forgotten before the conversation ends. What is
  registered is every credential in the resolved map, not only the one the
  co-tenant's runtime exports: over-redacting costs a little stream latency
  (`RedactionCarry`), missing a value is the disclosure.

  ## When

    * whenever the server assembles its sandbox env (`assembled/2`, from
      `ConversationServer.build_sprite_env/6`: a fresh provision, and every
      wake or reattach), and at every turn admission
      (`Fountain.Conversations.TurnMachine.open/7`);
    * when a co-tenant of another runtime assembles *its* env. `assembled/2`
      subscribes the server to its machine's `topic/1` and, on a mixed
      machine, `announce/2`s there; every server on the machine handles the
      announcement with `arrived/2`, which runs `register/2` again. The
      announcement is made before the co-tenant's credential reaches the
      disk, not after its provisioning finishes, so the window it closes is
      as small as it can be. A server subscribes before it reads, so an
      announcement it was not yet subscribed for is one its own read sees.

  On a single-runtime machine — every machine until an attach admits a
  second runtime (#2515) — each of those is one query
  (`Fountain.Machines.Occupancy.other_runtime_ids/2`) that answers empty, no
  credential is read, nothing is registered and nothing is announced.

  ## What is not covered

    * **A ChatGPT subscription** (ADR 0060, and the deployment's grant). Its
      resolution yields the grant's placeholder, never its bearer, and the
      bearer never enters a sandbox (`CodexChatGPT`), so there is nothing to
      register; the placeholder is skipped as it is in `SpriteEnv` (#2366).
    * **A co-tenant whose source no longer re-validates** (its configuration
      moved since admission). It is re-resolved as a new selection on the
      set it names, which covers a changed revision but not a rotated value:
      the value on its disk is the one it was provisioned with, and the
      database no longer holds it. The same re-validation refuses that
      source when the co-tenant next provisions or wakes.
    * **A co-tenant's per-conversation process tokens.** Its `FOUNTAIN_TOKEN`
      callback key and its broker session token sit in its process
      environment, readable by any process of the same user through
      `/proc/<pid>/environ`, and are registered only for it. That exposure
      already exists between two conversations of one agent on a shared
      machine, and is not closed here.
    * **Values the co-tenant's environment and vault hold.** Not recomputed:
      the attach rule admits a conversation only with the machine's own
      environment and vault, so each already registers them itself.
  """

  require Logger

  alias Fountain.Conversations.{Conversation, InferenceResolution, Redaction, TurnMachine}
  alias Fountain.Machines.Occupancy
  alias Fountain.Repo

  import Ecto.Query

  @doc "The PubSub topic a machine's servers hear co-tenant arrivals on."
  @spec topic(String.t()) :: String.t()
  def topic(sandbox_id) when is_binary(sandbox_id), do: "machine_cotenants:" <> sandbox_id

  @doc """
  The server has assembled its sandbox env (`SpriteEnv.build/4` has
  registered its own secrets): subscribe to the machine's arrivals, register
  the co-tenants' credentials, and on a mixed machine announce this
  conversation so they register its credential. Returns `sprite_env`, so it
  pipes.

  Called from the conversation's own server process, which is what
  subscribes. Every provision and reattach calls it, so the subscription is
  replaced rather than added to: one per server, however many times it wakes.
  """
  @spec assembled(list(), %{conversation_id: String.t(), sandbox_id: String.t() | nil}) :: list()
  def assembled(sprite_env, %{sandbox_id: nil}), do: sprite_env

  def assembled(sprite_env, %{conversation_id: conversation_id, sandbox_id: sandbox_id}) do
    Phoenix.PubSub.unsubscribe(Fountain.PubSub, topic(sandbox_id))
    :ok = Phoenix.PubSub.subscribe(Fountain.PubSub, topic(sandbox_id))

    if register(conversation_id, sandbox_id) == :mixed,
      do: announce(sandbox_id, conversation_id)

    sprite_env
  end

  @doc """
  Handle an announcement from `announce/2` in the server that received it:
  register again, unless it is this conversation's own or for a machine this
  server has left. Returns `state` unchanged.
  """
  @spec arrived({:cotenant_arrived, String.t(), String.t()}, map()) :: map()
  def arrived(
        {:cotenant_arrived, sandbox_id, from},
        %{sandbox_id: sandbox_id, conversation_id: conversation_id} = state
      )
      when from != conversation_id do
    register(conversation_id, sandbox_id)
    state
  end

  def arrived(_arrival, state), do: state

  @doc """
  Tell the machine's servers that `conversation_id` of another runtime is
  here. The message is `{:cotenant_arrived, sandbox_id, conversation_id}`
  and carries no value: each receiver reads what it needs itself.
  """
  @spec announce(String.t(), String.t()) :: :ok
  def announce(sandbox_id, conversation_id)
      when is_binary(sandbox_id) and is_binary(conversation_id) do
    Phoenix.PubSub.broadcast(
      Fountain.PubSub,
      topic(sandbox_id),
      {:cotenant_arrived, sandbox_id, conversation_id}
    )
  end

  @doc """
  Register, for `conversation_id`, the inference credential values of every
  co-tenant on `sandbox_id` that runs another runtime. Call only from the
  conversation's own server: `Redaction.add/2` reads then writes.

  `:single` when there is no such co-tenant (nothing read, nothing written),
  `:mixed` otherwise.
  """
  @spec register(String.t(), String.t() | nil) :: :single | :mixed
  def register(_conversation_id, nil), do: :single

  def register(conversation_id, sandbox_id)
      when is_binary(conversation_id) and is_binary(sandbox_id) do
    case Occupancy.other_runtime_ids(sandbox_id, conversation_id) do
      [] ->
        :single

      ids ->
        values = ids |> load() |> Enum.flat_map(&credential_values/1)
        Redaction.add(conversation_id, values)
        :mixed
    end
  end

  # ownership: the ids come from `Occupancy.other_runtime_ids/2`, which keeps
  # only conversations of the caller's own owner.
  defp load(ids), do: Repo.all(from c in Conversation, where: c.id in ^ids)

  @doc false
  # The values a co-tenant's inference resolution holds. Recomputed as its own
  # provision computes them (`SpriteEnv.resolve_inference/4` without the
  # reservation): its agent, its stored source, and the environment and
  # vault it runs against.
  def credential_values(%Conversation{} = conv) do
    agent = TurnMachine.agent_for(conv)

    opts = [
      environment_id: conv.environment_id || (agent && agent.environment_id),
      vault_id: conv.vault_id
    ]

    case resolve(conv, agent, opts) do
      {:ok, _source, creds} ->
        for {_kind, value} <- creds,
            is_binary(value),
            not Fountain.ChatGPTAccounts.Reserved.placeholder?(value),
            do: value

      {:error, reason} ->
        Logger.warning(
          "conv #{conv.id}: co-tenant inference credentials not readable for redaction: " <>
            inspect(Fountain.InferenceCredentials.loggable_reason(reason))
        )

        []
    end
  end

  # A stored source that no longer matches is re-read as a new selection on
  # the set it names (`credential_set_id/2` still takes the stored `set_id`).
  defp resolve(conv, agent, opts) do
    case InferenceResolution.revalidate(conv, agent, opts) do
      {:error, :inference_source_changed} ->
        InferenceResolution.revalidate(conv, agent, [expected_source: nil] ++ opts)

      result ->
        result
    end
  end
end
