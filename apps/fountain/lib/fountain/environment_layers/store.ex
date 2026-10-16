defmodule Fountain.EnvironmentLayers.Store do
  @moduledoc """
  Optional private S3/Tigris capabilities for environment artifacts (ADR 0090).

  No configuration means `:disabled`. This primitive does not enable caching or
  publish a ready artifact. The build lifecycle must persist the digest, wrapped
  artifact identity and generation before a restore may select an object.

  Account credentials stay on the server. Callers receive a short-lived grant
  for exactly one tenant/environment/artifact key, never a bucket listing or a
  caller-selected object key. Every grant first resolves environment ownership.
  """

  alias Fountain.Environments

  defmodule Config do
    @moduledoc false
    @derive {Inspect, only: [:bucket, :region]}
    @enforce_keys [:endpoint, :bucket, :access_key_id, :secret_access_key]
    defstruct [
      :endpoint,
      :bucket,
      :access_key_id,
      :secret_access_key,
      :session_token,
      region: "auto"
    ]
  end

  defmodule Grant do
    @moduledoc false
    @derive {Inspect, only: [:method, :origin, :expires_at]}
    @enforce_keys [:method, :origin, :url, :expires_at]
    defstruct [:method, :origin, :url, :expires_at]
  end

  @doc "Stable non-secret store identity; changing buckets must not acknowledge cleanup in another store."
  def identity(opts \\ []) do
    config = Keyword.get(opts, :config, Application.get_env(:fountain, :environment_layer_store))

    with {:ok, config} <- validate_config(config) do
      {:ok,
       :crypto.hash(:sha256, Jason.encode!([config.endpoint, config.bucket]))
       |> Base.encode16(case: :lower)}
    end
  end

  @doc "Generate a bounded object capability after a tenant-scoped environment fetch."
  def grant(user_id, environment_id, artifact_id, method, opts \\ []) do
    config = Keyword.get(opts, :config, Application.get_env(:fountain, :environment_layer_store))

    with {:ok, config} <- validate_config(config),
         {:ok, user_id} <- uuid(user_id),
         {:ok, environment_id} <- uuid(environment_id),
         {:ok, artifact_id} <- uuid(artifact_id),
         :ok <- authorize(environment_id, user_id),
         :ok <- validate_method(method),
         {:ok, expires} <- expiry(Keyword.get(opts, :expires, 300)) do
      {:ok, sign(config, user_id, environment_id, artifact_id, method, expires, opts)}
    end
  end

  defp sign(config, user_id, environment_id, artifact_id, method, expires, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:second)
    key = "environment-layers/v1/#{user_id}/#{environment_id}/#{artifact_id}.age"
    url = config.endpoint <> "/" <> config.bucket <> "/" <> key

    # Req's pinned implementation is shared with its public SigV4 request
    # signing step. Tests lock down the query contract, including STS tokens.
    signed =
      Req.Utils.aws_sigv4_url(
        access_key_id: config.access_key_id,
        secret_access_key: config.secret_access_key,
        region: config.region,
        service: :s3,
        datetime: now,
        method: method,
        url: url,
        expires: expires,
        query: session_query(config.session_token)
      )
      |> URI.to_string()

    %Grant{
      method: method,
      origin: config.endpoint,
      url: signed,
      expires_at: DateTime.add(now, expires, :second)
    }
  end

  @doc "System cleanup only: delete a durable artifact address even after its owner/environment was deleted."
  def _unsafe_delete_artifact(user_id, environment_id, artifact_id, opts \\ []) do
    config = Keyword.get(opts, :config, Application.get_env(:fountain, :environment_layer_store))

    with {:ok, config} <- validate_config(config),
         {:ok, user_id} <- uuid(user_id),
         {:ok, environment_id} <- uuid(environment_id),
         {:ok, artifact_id} <- uuid(artifact_id) do
      grant = sign(config, user_id, environment_id, artifact_id, :delete, 60, [])
      request_opts = Keyword.get(opts, :request_options, [])

      case Req.request(
             [
               url: grant.url,
               method: :delete,
               retry: false,
               redirect: false,
               receive_timeout: 15_000
             ] ++ request_opts
           ) do
        {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
        _ -> {:error, :cleanup_failed}
      end
    end
  rescue
    _ -> {:error, :cleanup_failed}
  end

  defp authorize(environment_id, user_id) do
    if Environments.get_environment(environment_id, user_id), do: :ok, else: {:error, :not_found}
  end

  defp validate_config(nil), do: {:error, :disabled}

  defp validate_config(%Config{} = config) do
    uri = endpoint_uri(config.endpoint)

    valid_endpoint =
      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
        uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
        uri.path in [nil, "", "/"] and is_integer(uri.port) and uri.port in 1..65_535

    valid_bucket =
      is_binary(config.bucket) and
        Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/, config.bucket) and
        not String.contains?(config.bucket, "..")

    credentials = [config.access_key_id, config.secret_access_key, config.region]

    if valid_endpoint and valid_bucket and
         Enum.all?(credentials, &(is_binary(&1) and byte_size(&1) in 1..4096)) and
         (is_nil(config.session_token) or
            (is_binary(config.session_token) and byte_size(config.session_token) in 1..8192)) do
      {:ok, %{config | endpoint: String.trim_trailing(config.endpoint, "/")}}
    else
      {:error, :invalid_store}
    end
  end

  defp validate_config(_), do: {:error, :invalid_store}

  defp endpoint_uri(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, uri} -> uri
      {:error, _} -> %URI{}
    end
  end

  defp endpoint_uri(_), do: %URI{}

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_reference}
    end
  end

  defp validate_method(method) when method in [:get, :put, :delete], do: :ok
  defp validate_method(_), do: {:error, :invalid_operation}
  defp expiry(seconds) when is_integer(seconds) and seconds in 1..900, do: {:ok, seconds}
  defp expiry(_), do: {:error, :invalid_expiry}
  defp session_query(nil), do: []
  defp session_query(token), do: [{"X-Amz-Security-Token", token}]
end
