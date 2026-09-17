defmodule Fountain.Analytics.SinkTest do
  @moduledoc """
  The batching sink, exercised in the `:async` mode production runs.

  The rest of the suite runs the sink `:inline` so a `Req.Test` stub belongs
  to the test that installed it. Here the request leaves a task the sink
  spawned, which is why this file shares its stub and cannot be async.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fountain.Analytics.Sink

  setup :set_req_test_to_shared

  setup do
    previous = %{
      key: Application.get_env(:fountain, :posthog_project_api_key),
      mode: Application.get_env(:fountain, :analytics_mode)
    }

    Application.put_env(:fountain, :posthog_project_api_key, "phc_test")
    Application.put_env(:fountain, :analytics_mode, :async)

    on_exit(fn ->
      restore(:posthog_project_api_key, previous.key)
      restore(:analytics_mode, previous.mode)
    end)

    test = self()

    Req.Test.stub(Fountain.Analytics, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posthog, Jason.decode!(body)})
      Req.Test.json(conn, %{"status" => 1})
    end)

    :ok
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp payload(n),
    do: %{event: "agent.created", distinct_id: "u#{n}", properties: %{}, timestamp: "now"}

  describe "batching" do
    test "queued events go out together, oldest first" do
      for n <- 1..3, do: Sink.enqueue(payload(n))

      Sink.flush()

      assert_receive {:posthog, %{"batch" => batch, "api_key" => "phc_test"}}
      assert Enum.map(batch, & &1["distinct_id"]) == ~w(u1 u2 u3)
    end

    test "a caller never waits for the network" do
      Req.Test.stub(Fountain.Analytics, fn conn ->
        Process.sleep(200)
        Req.Test.json(conn, %{"status" => 1})
      end)

      # 150 events is past the 100-event batch size, so this also proves the
      # sink keeps taking work while a flush it already started is in flight.
      {micros, :ok} =
        :timer.tc(fn ->
          for n <- 1..150, do: Sink.enqueue(payload(n))
          :ok
        end)

      assert micros < 100_000

      Sink.flush()
    end

    test "flushing an empty sink sends nothing" do
      Sink.flush()
      refute_receive {:posthog, _}, 50
    end
  end

  describe "casts the sink does not match" do
    test "an unknown cast neither stops it nor loses the queue" do
      pid = Process.whereis(Sink)
      Sink.enqueue(payload(1))

      log =
        capture_log(fn ->
          # The shape a caller on a later release would send. `use GenServer`
          # stops the process with `{:bad_cast, …}`; defining the `:enqueue`
          # clause removed that, so before the catch-all this raised and took
          # the queued events with it (#2380).
          GenServer.cast(Sink, {:enqueue_batch, [payload(2)]})
          Sink.flush()
        end)

      assert log =~ "no handle_cast clause for :enqueue_batch/2"
      # The shape, never the payload: an enqueued event carries its
      # properties and its distinct_id.
      refute log =~ "agent.created"
      refute log =~ "distinct_id"

      assert Process.alive?(pid)
      assert Process.whereis(Sink) == pid
      assert_receive {:posthog, %{"batch" => [%{"distinct_id" => "u1"}]}}
    end
  end

  describe "when PostHog is unreachable" do
    test "the batch is dropped and counted, and the sink survives" do
      Req.Test.stub(Fountain.Analytics, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      handler = {__MODULE__, make_ref()}
      test = self()

      :telemetry.attach(
        handler,
        [:fountain, :analytics, :dropped],
        fn _e, measurements, metadata, _ -> send(test, {:dropped, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      pid = Process.whereis(Sink)
      Sink.enqueue(payload(1))
      Sink.flush()

      assert_receive {:dropped, %{count: 1}, _}
      assert Process.alive?(pid)

      # And it keeps working once PostHog comes back.
      Req.Test.stub(Fountain.Analytics, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:posthog, Jason.decode!(body)})
        Req.Test.json(conn, %{"status" => 1})
      end)

      Sink.enqueue(payload(2))
      Sink.flush()
      assert_receive {:posthog, %{"batch" => [%{"distinct_id" => "u2"}]}}
    end
  end
end
