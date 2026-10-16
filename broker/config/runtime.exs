import Config

if config_env() != :test do
  url = System.fetch_env!("BROKER_CONTROL_URL")

  case URI.parse(url) do
    %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
    when is_binary(host) ->
      :ok

    _ ->
      raise "BROKER_CONTROL_URL must be an HTTPS URL without credentials"
  end

  token = System.fetch_env!("BROKER_CONTROL_TOKEN")
  if byte_size(token) < 32, do: raise("BROKER_CONTROL_TOKEN must be at least 32 bytes")

  seed =
    case Base.decode64(System.fetch_env!("BROKER_CA_SEED")) do
      {:ok, <<_::256>> = seed} -> seed
      _ -> raise "BROKER_CA_SEED must be base64 encoding of 32 random bytes"
    end

  config :remote_broker,
    control_url: String.trim_trailing(url, "/"),
    token: token,
    ca_seed: seed,
    port: String.to_integer(System.get_env("BROKER_LISTEN_PORT", "14322"))
end
