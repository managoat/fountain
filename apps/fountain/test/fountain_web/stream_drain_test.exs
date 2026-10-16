defmodule FountainWeb.StreamDrainTest do
  use ExUnit.Case, async: false

  alias FountainWeb.StreamDrain

  setup do
    StreamDrain.reset()
    on_exit(fn -> StreamDrain.reset() end)
    :ok
  end

  test "shutdown notifies existing subscribers and covers late subscribers" do
    StreamDrain.subscribe()
    refute_received :fountain_shutdown
    StreamDrain.begin()
    assert_receive :fountain_shutdown

    parent = self()

    spawn(fn ->
      StreamDrain.subscribe()

      receive do
        :fountain_shutdown -> send(parent, :late_subscriber_drained)
      end
    end)

    assert_receive :late_subscriber_drained
  end
end
