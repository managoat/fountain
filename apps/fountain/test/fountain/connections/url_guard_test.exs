defmodule Fountain.Connections.UrlGuardTest do
  use ExUnit.Case, async: true

  alias Fountain.Connections.UrlGuard

  test "an https URL on a public name passes, with the address to connect to" do
    assert {:ok, %{host: "mcp.example.com", address: {93, 184, 216, 34}}} =
             UrlGuard.check("https://MCP.example.com/mcp")
  end

  test "an IPv6-only public name passes" do
    assert {:ok, %{address: {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}}} =
             UrlGuard.check("https://v6.example.com/")
  end

  for {url, reason} <- [
        {"http://mcp.example.com/mcp", :not_https},
        {"ftp://mcp.example.com", :not_https},
        {"mcp.example.com/mcp", :not_https},
        {"https:///path", :no_host},
        {"https://user:pw@mcp.example.com/", :userinfo},
        {"https://8.8.8.8/mcp", :ip_literal},
        {"https://127.0.0.1/", :ip_literal},
        {"https://[::1]/", :ip_literal},
        {"https://[2606:4700::1111]/", :ip_literal},
        {"https://localhost/", :internal_host},
        {"https://metadata.google.internal/", :internal_host},
        {"https://printer.local/", :internal_host},
        {"https://api.svc/", :internal_host},
        {"https://intranet/", :internal_host},
        {"https://private.example.com/", :private_address},
        {"https://loopback.example.com/", :private_address},
        {"https://metadata.example.com/", :private_address},
        {"https://cgnat.example.com/", :private_address},
        {"https://v6loop.example.com/", :private_address},
        {"https://mixed.example.com/", :private_address},
        {"https://nowhere.example.com/", :unresolvable}
      ] do
    test "refuses #{url} (#{reason})" do
      assert UrlGuard.check(unquote(url)) == {:error, unquote(reason)}
      assert is_binary(UrlGuard.message(unquote(reason)))
    end
  end

  test "refuses what is not a string" do
    assert UrlGuard.check(nil) == {:error, :not_https}
  end

  test "the non-public ranges" do
    for ip <- [
          {0, 1, 2, 3},
          {10, 1, 1, 1},
          {127, 0, 0, 1},
          {169, 254, 169, 254},
          {172, 16, 0, 1},
          {172, 31, 255, 255},
          {192, 168, 0, 1},
          {192, 0, 2, 1},
          {100, 64, 0, 1},
          {198, 18, 0, 1},
          {198, 51, 100, 1},
          {203, 0, 113, 1},
          {224, 0, 0, 1},
          {255, 255, 255, 255},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0, 0, 0, 0, 0, 0, 0, 0},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1},
          {0xFE80, 0, 0, 0, 0, 0, 0, 1},
          {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
          {0x2002, 0, 0, 0, 0, 0, 0, 1},
          {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}
        ] do
      refute UrlGuard.public?(ip), "#{inspect(ip)} should not be public"
    end

    for ip <- [{8, 8, 8, 8}, {172, 32, 0, 1}, {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}] do
      assert UrlGuard.public?(ip), "#{inspect(ip)} should be public"
    end
  end
end
