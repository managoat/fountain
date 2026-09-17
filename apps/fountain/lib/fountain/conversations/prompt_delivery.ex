defmodule Fountain.Conversations.PromptDelivery do
  @moduledoc """
  What travels with a prompt's text to the turn it opens (#1406).

  A prompt reaches its turn by one of two roads. A live `ConversationServer`
  takes it in a call and opens the turn before it answers. A conversation with
  no server is woken first, and the prompt follows in a cast once the machine
  is up, long after the request that carried it was answered. The caller's
  `client_request_id` has to arrive at `TurnMachine.open/7` down both, and this
  module is the one place that says how.

  **The message only changes shape when there is something to carry.** A
  deploy runs two releases side by side, and a server on the previous one
  matches `{:send_prompt, prompt, images}` and `{:initial_prompt, prompt,
  images}` exactly: a fourth element there is an `:unknown_call`, or for the
  cast a prompt dropped with nobody told. So a prompt with nothing travelling
  is sent in the shape every release understands, and only a caller that
  supplied a `client_request_id` can meet the older server during a rollout.
  On the call that caller gets an error it can retry. On the cast it can lose
  the prompt, in one case: its wake lost the race for the conversation to a
  server the previous release started, and handed the prompt to that winner.
  The window is the rollout that ships this, and it closes with it.
  """

  @carried [:client_request_id]

  @type travelling :: keyword()
  @type wake_prompt :: nil | String.t() | {String.t(), travelling()}

  @doc "The part of a door's `opts` that goes with the prompt to its turn."
  @spec travelling(keyword()) :: travelling()
  def travelling(opts) when is_list(opts) do
    for {key, value} <- opts, key in @carried, is_binary(value), do: {key, value}
  end

  @doc "The call a live server takes a prompt in."
  @spec call(String.t(), list(), keyword()) :: tuple()
  def call(prompt, images, opts) do
    case travelling(opts) do
      [] -> {:send_prompt, prompt, images}
      meta -> {:send_prompt, prompt, images, meta}
    end
  end

  @doc "The cast that delivers a prompt to a server once it has provisioned."
  @spec cast(String.t(), list(), keyword()) :: tuple()
  def cast(prompt, images, opts) do
    case travelling(opts) do
      [] -> {:initial_prompt, prompt, images}
      meta -> {:initial_prompt, prompt, images, meta}
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
    Fountain.Conversations.ConversationServer.queue_initial_prompt(pid, prompt, images, meta)
  end

  def hand_over(pid, prompt, images) when is_binary(prompt) and prompt != "" do
    Fountain.Conversations.ConversationServer.queue_initial_prompt(pid, prompt, images)
  end

  def hand_over(_pid, _nothing, _images), do: :ok
end
