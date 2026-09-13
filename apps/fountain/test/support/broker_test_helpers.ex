defmodule Fountain.BrokerTestHelpers do
  @moduledoc """
  Put the egress broker "on" or "off" for a test, and restore the app env
  after. Global state, so the test module that uses it is `async: false`.

  There is no per-tenant form. Brokerage was a per-tenant ratchet while the
  hosted deployment widened one id at a time (ADR 0019 §9); that retired, and
  `BROKER_LISTEN_PORT` is the only switch, so these take no user.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @keys [:broker_listen_port, :broker_proxy_url]

  @doc "Broker on, plus the `connections` rollout flag."
  def enable_connections do
    enable_broker()
    previous = Application.get_env(:fountain, :feature_flag_overrides, %{})
    on_exit(fn -> Application.put_env(:fountain, :feature_flag_overrides, previous) end)

    Application.put_env(
      :fountain,
      :feature_flag_overrides,
      Map.put(previous, "connections", true)
    )

    :ok
  end

  @doc "Broker on for this test."
  def enable_broker do
    restore_after()

    # A port, not a listener: `Broker.backend/0` reads the config, and a test
    # that only needs brokerage on does not need anything bound.
    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    :ok
  end

  @doc "Broker off for this test: no listen port, so `Broker.configured?/0` is false."
  def disable_broker do
    restore_after()

    for k <- @keys, do: Application.delete_env(:fountain, k)
    :ok
  end

  defp restore_after do
    previous = for k <- @keys, do: {k, Application.get_env(:fountain, k)}

    on_exit(fn ->
      for {k, v} <- previous do
        if is_nil(v),
          do: Application.delete_env(:fountain, k),
          else: Application.put_env(:fountain, k, v)
      end
    end)
  end
end
