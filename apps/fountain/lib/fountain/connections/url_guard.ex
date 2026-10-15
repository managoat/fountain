defmodule Fountain.Connections.UrlGuard do
  @moduledoc """
  The one rule for a URL Managoat fetches on a user's behalf while
  connecting a remote MCP server (ADR 0085, decision 3).

  Discovery, registration, the token exchange, refresh and revocation all
  reach addresses a user typed, or that a server it named sent back. That is
  the request an SSRF wants, so each one is checked here immediately before it
  is made, and `Fountain.Connections.OAuth` then connects to the address this
  check resolved rather than resolving the name again: a name that answers a
  public address to the check and a private one to the fetch gets nowhere.

  Refused: any scheme but `https`; a URL with no host or with userinfo; an IP
  literal, public or not; `localhost` and the cluster-internal names; and a
  hostname any of whose addresses is not public. A name that does not resolve
  is refused too.

  Kept from `managoat_mcp_auth` 0.2.0's guard, with the address ranges
  widened to ex_mcp's (below).
  """

  import Bitwise

  @internal_hosts ~w(localhost localhost.localdomain internal kubernetes kubernetes.default metadata.google.internal metadata.google instance-data)
  @internal_suffixes ~w(.localhost .internal .local .cluster.local .svc)

  @type reason ::
          :not_https
          | :no_host
          | :userinfo
          | :ip_literal
          | :internal_host
          | :private_address
          | :unresolvable

  @type target :: %{uri: URI.t(), host: String.t(), address: :inet.ip_address()}

  @doc """
  `{:ok, target}` with the parsed URL, its hostname and the address to
  connect to, or `{:error, reason}` naming the rule the URL broke.
  """
  @spec check(term()) :: {:ok, target()} | {:error, reason()}
  def check(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when not is_binary(host) or host == "" ->
        {:error, :no_host}

      %URI{scheme: "https", userinfo: info} when is_binary(info) ->
        {:error, :userinfo}

      %URI{scheme: "https", host: host} = uri ->
        host = String.downcase(host)

        with :ok <- check_name(host),
             {:ok, address} <- resolve(host) do
          {:ok, %{uri: uri, host: host, address: address}}
        end

      _ ->
        {:error, :not_https}
    end
  end

  def check(_url), do: {:error, :not_https}

  @doc "Why a URL was refused, for a form or an API error."
  @spec message(reason()) :: String.t()
  def message(:not_https), do: "must be an https URL"
  def message(:no_host), do: "must name a host"
  def message(:userinfo), do: "must not carry a user name or password"
  def message(:ip_literal), do: "must be a hostname, not an IP address"
  def message(:internal_host), do: "must not be an internal host"
  def message(:private_address), do: "must not resolve to a private address"
  def message(:unresolvable), do: "does not resolve"

  defp check_name(host) do
    cond do
      ip_literal?(host) -> {:error, :ip_literal}
      host in @internal_hosts -> {:error, :internal_host}
      Enum.any?(@internal_suffixes, &String.ends_with?(host, &1)) -> {:error, :internal_host}
      not String.contains?(host, ".") -> {:error, :internal_host}
      true -> :ok
    end
  end

  defp ip_literal?(host) do
    bare = host |> String.trim_leading("[") |> String.trim_trailing("]")
    match?({:ok, _}, :inet.parse_address(String.to_charlist(bare)))
  end

  # Every address the name has must be public, not just the one we pick:
  # a client library elsewhere might pick another. IPv4 first, for the
  # connection, because more networks route it.
  defp resolve(host) do
    case resolver().(host) do
      [] ->
        {:error, :unresolvable}

      addrs ->
        if Enum.all?(addrs, &public?/1),
          do: {:ok, Enum.find(addrs, &(tuple_size(&1) == 4)) || hd(addrs)},
          else: {:error, :private_address}
    end
  end

  defp resolver do
    case Application.get_env(:fountain, :connections_resolver) do
      nil -> &getaddrs/1
      module when is_atom(module) -> &module.resolve/1
    end
  end

  defp getaddrs(host) do
    charlist = String.to_charlist(host)

    Enum.flat_map([:inet, :inet6], fn family ->
      case :inet.getaddrs(charlist, family) do
        {:ok, addrs} -> addrs
        _ -> []
      end
    end)
  end

  @doc """
  Whether an address is on the public internet. The ranges are ex_mcp's
  `ExMCP.Internal.NetworkPolicy` (ex_mcp 1.6.0, MIT licence, copyright its
  authors): IPv4 0/8, 10/8, 127/8, multicast and above, CGNAT, link-local
  (the metadata service among it), RFC 1918, the IETF and documentation
  ranges, 6to4 relay and benchmarking; IPv6 anything outside 2000::/3, the
  documentation, ORCHID, Teredo, benchmarking and 6to4 ranges, and an
  IPv4-mapped address by its IPv4 half.
  """
  @spec public?(:inet.ip_address()) :: boolean()
  def public?({a, b, c, d} = ip) when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
    do: not restricted_ipv4?(ip)

  def public?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: public?({high >>> 8, high &&& 255, low >>> 8, low &&& 255})

  def public?({first, _, _, _, _, _, _, _} = ip),
    do: (first &&& 0xE000) == 0x2000 and not reserved_ipv6?(ip)

  def public?(_), do: false

  defp restricted_ipv4?({a, _, _, _}) when a in [0, 10, 127] or a >= 224, do: true
  defp restricted_ipv4?({100, b, _, _}) when b in 64..127, do: true
  defp restricted_ipv4?({169, 254, _, _}), do: true
  defp restricted_ipv4?({172, b, _, _}) when b in 16..31, do: true
  defp restricted_ipv4?({192, b, _, _}) when b in [0, 168], do: true
  defp restricted_ipv4?({192, 88, 99, _}), do: true
  defp restricted_ipv4?({198, b, _, _}) when b in 18..19, do: true
  defp restricted_ipv4?({198, 51, 100, _}), do: true
  defp restricted_ipv4?({203, 0, 113, _}), do: true
  defp restricted_ipv4?(_), do: false

  defp reserved_ipv6?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: true
  defp reserved_ipv6?({0x3FFF, b, _, _, _, _, _, _}) when b <= 0x0FFF, do: true
  defp reserved_ipv6?({0x2001, b, _, _, _, _, _, _}) when b in [0x0000, 0x0002], do: true
  defp reserved_ipv6?({0x2001, b, _, _, _, _, _, _}) when b in 0x0010..0x002F, do: true
  defp reserved_ipv6?({0x2002, _, _, _, _, _, _, _}), do: true
  defp reserved_ipv6?(_), do: false
end
