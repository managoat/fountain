defmodule FountainWeb.StreamDrain do
  @moduledoc """
  Close SSE readers before the HTTP listener drains on a single-node rollout.
  The marker covers a request subscribing after the shutdown broadcast. It is
  reset only at application start; no prompt or conversation is terminated.
  """
  @key {__MODULE__, :draining}
  @topic "server:stream_drain"

  def reset, do: :persistent_term.put(@key, false)

  def subscribe do
    Phoenix.PubSub.subscribe(Fountain.PubSub, @topic)
    if :persistent_term.get(@key, false), do: send(self(), :fountain_shutdown)
    :ok
  end

  def begin do
    :persistent_term.put(@key, true)
    Phoenix.PubSub.broadcast(Fountain.PubSub, @topic, :fountain_shutdown)
  end
end
