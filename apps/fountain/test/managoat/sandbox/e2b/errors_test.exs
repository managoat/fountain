defmodule Managoat.Sandbox.E2B.ErrorsTest do
  use ExUnit.Case, async: true

  alias Managoat.Sandbox.E2B.Errors

  @http_cases [
    {{:api_error, 404, %{"error" => "gone"}}, :not_found},
    {{:api_error, 401, %{"error" => "bad key"}},
     {:denied, {:http, 401, %{"error" => "bad key"}}}},
    {{:api_error, 403, %{"error" => "forbidden"}},
     {:denied, {:http, 403, %{"error" => "forbidden"}}}},
    {{:api_error, 429, %{"retryAfterSeconds" => 17}}, {:rate_limited, 17}},
    {{:api_error, 429, %{"retryAfterSeconds" => -1}}, {:rate_limited, nil}},
    {{:api_error, 429, %{"retryAfterSeconds" => "17"}}, {:rate_limited, nil}},
    {{:api_error, 429, %{"error" => "slow down"}}, {:rate_limited, nil}},
    {{:api_error, 500, %{"error" => "down"}}, {:unavailable, {:http, 500, %{"error" => "down"}}}},
    {{:api_error, 599, "gateway"}, {:unavailable, {:http, 599, "gateway"}}},
    {{:api_error, 400, %{"error" => "bad request"}},
     {:invalid, {:http, 400, %{"error" => "bad request"}}}},
    {{:api_error, 422, ["bad input"]}, {:invalid, {:http, 422, ["bad input"]}}}
  ]

  test "normalizes every E2B HTTP error class into the closed taxonomy" do
    for {raw, expected} <- @http_cases do
      assert Errors.normalize(raw) == expected
    end
  end

  test "normalizes provider-neutral sentinel atoms" do
    assert Errors.normalize(:not_found) == :not_found
    assert Errors.normalize(:truncated) == :truncated
    assert Errors.normalize(:command_exited) == :command_exited
    assert Errors.normalize(:timeout) == {:unavailable, :timeout}
  end

  test "normalizes Req and Mint transport failures as unavailable" do
    req = %Req.TransportError{reason: :nxdomain}
    mint = %Mint.TransportError{reason: :closed}

    assert Errors.normalize(req) == {:unavailable, req}
    assert Errors.normalize(mint) == {:unavailable, mint}
  end

  test "unknown shapes retain their provider identity in the escape hatch" do
    assert Errors.normalize({:unexpected, %{detail: 1}}) ==
             {:provider, :e2b, {:unexpected, %{detail: 1}}}
  end
end
