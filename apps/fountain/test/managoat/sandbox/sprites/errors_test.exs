defmodule Managoat.Sandbox.Sprites.ErrorsTest do
  use ExUnit.Case, async: true

  alias Managoat.Sandbox.Sprites.Errors

  test "not-found shapes normalize to :not_found" do
    assert Errors.normalize({:not_found, %{"error" => "gone"}}) == :not_found
    assert Errors.normalize({:api_error, 404, %{}}) == :not_found
  end

  test "credential problems are permanent :denied" do
    assert {:denied, {:http, 401, %{}}} = Errors.normalize({:api_error, 401, %{}})
    assert {:denied, {:http, 403, %{}}} = Errors.normalize({:api_error, 403, %{}})
  end

  test "429 surfaces the structured retry-after when present" do
    assert {:rate_limited, 17} =
             Errors.normalize({:api_error, 429, %{"retry_after_seconds" => 17}})

    assert {:rate_limited, nil} = Errors.normalize({:api_error, 429, %{"error" => "slow down"}})
  end

  test "5xx, timeouts and transport failures are :unavailable" do
    assert {:unavailable, {:http, 502, %{}}} = Errors.normalize({:api_error, 502, %{}})
    assert {:unavailable, :timeout} = Errors.normalize(:timeout)

    # Named rather than left to the escape hatch, because the classification
    # is the point: `Retry.transient?/1` retries a wake on it.
    assert {:unavailable, :closed_before_exit} = Errors.normalize(:closed_before_exit)
    assert Managoat.Sandbox.Retry.transient?(Errors.normalize(:closed_before_exit))

    transport = %Req.TransportError{reason: :nxdomain}
    assert {:unavailable, ^transport} = Errors.normalize(transport)

    mint = %Mint.TransportError{reason: :closed}
    assert {:unavailable, ^mint} = Errors.normalize(mint)
  end

  test "other 4xx are the caller's fault" do
    assert {:invalid, {:http, 422, %{}}} = Errors.normalize({:api_error, 422, %{}})
  end

  test "unknown shapes fall into the provider escape hatch" do
    assert {:provider, :sprites, :weird} = Errors.normalize(:weird)
  end
end
