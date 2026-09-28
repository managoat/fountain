defmodule Fountain.Conversations.PromptDelivery do
  @moduledoc """
  What travels with a prompt's text to the turn it opens (#1406).

  A prompt reaches its turn by one of two roads. A live `ConversationServer`
  takes it in a call and opens the turn before it answers. A conversation with
  no server is woken first, and the prompt follows in a cast once the machine
  is up, long after the request that carried it was answered. The caller's
  `client_request_id` has to arrive at `TurnMachine.open/7` down both, and this
  module is the one place that says how.

  ## A deploy runs two releases side by side

  Horde places a conversation's server on any node of the cluster
  (`Horde.UniformDistribution`), so during a rollout the server a prompt is
  sent to can be on a pod of the previous release, whoever started it. That
  server matches `{:send_prompt, prompt, images}` and `{:initial_prompt,
  prompt, images}` exactly. A fourth element falls to its catch-all clauses:
  the call is answered `:unknown_call`, the cast is dropped with nobody told,
  and both log the message, which means the prompt's text.

  So the message only changes shape when there is something to carry **and the
  node that will receive it has this module**. `understands?/1` asks the
  receiving node. When it does not, the prompt goes in the shape every release
  matches and the correlation is left behind, with a warning that names the
  node and never the prompt: a turn without its label is a smaller loss than a
  prompt that never ran. The window is a rollout across the release that
  introduced this module, and it closes with it.

  The machine owner has the same window: an owner on the previous release
  inserts the turn from a changeset that does not cast `client_request_id`, so
  that turn opens without it.

  ## `read_only` is never left behind

  A prompt may also carry `read_only: true` (#2533). That is a permission, and
  dropping it would run the prompt writable, so the rule above is inverted for
  it: a node whose release cannot enforce it (`understands_read_only?/1`) is
  not sent the prompt at all. The call answers
  `{:error, :read_only_unavailable}`; the cast that follows a wake has nobody
  to answer, so it is not sent, and the stream says the prompt did not run. A
  machine owner on the previous release is caught after admission instead,
  by `Fountain.Conversations.ReadOnly.confirm_admitted/3`.
  """

  require Logger

  alias Fountain.Conversations.{ConversationServer, Output, ReadOnly, Turn}

  @carried [:client_request_id, :read_only]

  @type travelling :: keyword()
  @type wake_prompt :: nil | String.t() | {String.t(), travelling()}

  @doc """
  The part of a door's `opts` that goes with the prompt to its turn.

  An id the turn's changeset would refuse is dropped here, because the API has
  already refused it (422) and this is the backstop for a caller that is not
  the API. Reaching the insert instead would make turn admission fail, and a
  live server answers a failed admission by dropping its connection: a healthy
  agent session torn down over a label. An id carrying U+0000 is worse than a
  refused changeset — PostgreSQL raises 22021 from inside the insert — and it
  is dropped here for the same reason.
  """
  @spec travelling(keyword()) :: travelling()
  def travelling(opts) when is_list(opts) do
    for {key, value} <- opts, key in @carried, carriable?(key, value), do: {key, value}
  end

  defp carriable?(:client_request_id, value) when is_binary(value),
    do: String.length(value) in 1..Turn.client_request_id_max() and not Turn.has_nul?(value)

  # Only `true` travels: a normal prompt keeps the message shape it had.
  defp carriable?(:read_only, value), do: value == true
  defp carriable?(_key, _value), do: false

  @doc """
  Whether the server on `node` matches the four-element messages. It does when
  that node's release has this module, which shipped in the same commit as the
  clauses that match them. Any failure to find out reads as no.
  """
  @spec understands?(node()) :: boolean()
  def understands?(node) when node == node(), do: true

  def understands?(node) do
    :erpc.call(node, Code, :ensure_loaded?, [__MODULE__], 2_000) == true
  catch
    _kind, _reason -> false
  end

  @doc """
  Whether the server on `node` enforces a read-only turn: its release has
  `Fountain.Conversations.ReadOnly`, which shipped with the clauses that do.
  Any failure to find out reads as no.
  """
  @spec understands_read_only?(node()) :: boolean()
  def understands_read_only?(node) when node == node(), do: true

  def understands_read_only?(node) do
    :erpc.call(node, Code, :ensure_loaded?, [ReadOnly], 2_000) == true
  catch
    _kind, _reason -> false
  end

  @doc """
  What a launch request asks to travel with its first prompt. `attrs` is the
  string-keyed map `Launch` takes, from the API or replayed from the queue.
  """
  @spec from_request(map()) :: travelling()
  def from_request(attrs) when is_map(attrs) do
    travelling(client_request_id: attrs["client_request_id"], read_only: attrs["read_only"])
  end

  @doc """
  Queue a launch's first prompt on the server just started for it. With
  nothing travelling this is the three-argument `queue_initial_prompt`, the
  call it has always been.
  """
  @spec queue(pid(), String.t(), list(), travelling()) :: :ok
  def queue(pid, prompt, images, []),
    do: ConversationServer.queue_initial_prompt(pid, prompt, images)

  def queue(pid, prompt, images, meta),
    do: ConversationServer.queue_initial_prompt(pid, prompt, images, meta)

  @doc "The call the live server `pid` takes a prompt in."
  @spec call(pid(), String.t(), list(), keyword(), (node() -> boolean())) :: tuple()
  def call(pid, prompt, images, opts, understands? \\ &understands?/1) do
    case deliverable(pid, opts, understands?) do
      [] -> {:send_prompt, prompt, images}
      meta -> {:send_prompt, prompt, images, meta}
    end
  end

  @doc """
  Whether a prompt carrying `opts` may go to `pid` at all: `:ok`, or
  `{:error, :read_only_unavailable}` when it asks for a read-only turn and the
  server's release cannot enforce one. See the moduledoc.
  """
  @spec permitted(pid(), keyword(), (node() -> boolean())) ::
          :ok | {:error, :read_only_unavailable}
  def permitted(pid, opts, understands_read_only? \\ &understands_read_only?/1) do
    if Keyword.get(travelling(opts), :read_only) != true or understands_read_only?.(node(pid)),
      do: :ok,
      else: {:error, :read_only_unavailable}
  end

  @doc """
  Cast a woken or launched conversation's first prompt to `pid`, unless it
  asks for a read-only turn that server cannot enforce. Then nothing is sent:
  the prompt is not run, the stream says so, and the log names the node, never
  the prompt.
  """
  @spec send_cast(pid(), String.t(), list(), keyword()) :: :ok
  def send_cast(pid, prompt, images, opts) do
    case permitted(pid, opts) do
      :ok ->
        GenServer.cast(pid, cast(pid, prompt, images, opts))

      {:error, :read_only_unavailable} ->
        Logger.warning(
          "read-only prompt for a server on #{node(pid)}, which predates read-only turns " <>
            "(#2533): not delivered"
        )

        refuse_cast(pid)
    end
  end

  defp refuse_cast(pid) do
    case Horde.Registry.keys(Fountain.ConversationRegistry, pid) do
      [conversation_id | _] when is_binary(conversation_id) ->
        Output.publish_stage(conversation_id, "turn", "failed", %{
          reason: "read_only_unavailable",
          message:
            "This prompt asked to run read-only and reached a server that cannot " <>
              "enforce that during a deploy. It did not run. Send it again."
        })

      _ ->
        :ok
    end
  end

  @doc """
  Deliver to a live server, with the caller's uncertain-delivery classification.

  A timeout or distribution loss can follow acceptance of the prompt. The
  sandbox queue sets `:uncertain_error` to `:prompt_delivery_unknown` to stop
  automatic retries on either outcome. Ordinary callers keep their existing
  timeout response and exit behavior. An explicit refusal from the server is
  returned unchanged. This option stays local and never travels with the prompt.
  """
  def deliver(pid, prompt, images, opts) do
    uncertain_error = Keyword.get(opts, :uncertain_error, :provisioning)

    with :ok <- permitted(pid, opts),
         do: ConversationServer.call_server(pid, call(pid, prompt, images, opts), uncertain_error)
  end

  @doc "The cast that delivers a prompt to the server `pid` once it has provisioned."
  @spec cast(pid(), String.t(), list(), keyword(), (node() -> boolean())) :: tuple()
  def cast(pid, prompt, images, opts, understands? \\ &understands?/1) do
    case deliverable(pid, opts, understands?) do
      [] -> {:initial_prompt, prompt, images}
      meta -> {:initial_prompt, prompt, images, meta}
    end
  end

  defp deliverable(pid, opts, understands?) do
    meta = travelling(opts)

    cond do
      meta == [] ->
        []

      understands?.(node(pid)) ->
        meta

      true ->
        Logger.warning(
          "prompt for a server on #{node(pid)}, which predates client_request_id (#1406): " <>
            "delivering the prompt without it"
        )

        []
    end
  end

  @doc """
  The prompt as `Wake` carries it: the bare text when nothing travels with it,
  which is what every existing caller of `Wake.wake_conversation/3` passes.
  """
  @spec for_wake(String.t() | nil, keyword()) :: wake_prompt()
  def for_wake(prompt, opts) when is_binary(prompt) do
    case travelling(opts) do
      [] -> prompt
      meta -> {prompt, meta}
    end
  end

  def for_wake(prompt, _opts), do: prompt

  @doc """
  Hand a woken conversation's prompt to the server that ended up owning it.
  Nothing to deliver is not an error: a wake for an interrupt carries no prompt.

  `images` has no default, for the reason #2373 gave: the wake used to reach
  `queue_initial_prompt/2`, whose default was `[]`, and a woken turn opened
  with the text and none of its images while the caller was told `queued`.
  """
  @spec hand_over(pid(), wake_prompt(), list()) :: :ok
  def hand_over(pid, {prompt, meta}, images) when is_binary(prompt) and prompt != "" do
    ConversationServer.queue_initial_prompt(pid, prompt, images, meta)
  end

  def hand_over(pid, prompt, images) when is_binary(prompt) and prompt != "" do
    ConversationServer.queue_initial_prompt(pid, prompt, images)
  end

  def hand_over(_pid, _nothing, _images), do: :ok
end
