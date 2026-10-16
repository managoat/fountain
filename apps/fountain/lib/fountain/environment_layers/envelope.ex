defmodule Fountain.EnvironmentLayers.Envelope do
  @moduledoc """
  Wrap one artifact's age identity under its owner's existing envelope key.

  The helper generates a fresh identity per artifact. Only the wrapped identity
  is suitable for persistence. The tenant key must never enter a sandbox; unwrap
  after ownership and generation checks, and deliver the artifact identity only
  after narrowing the restore floor. These functions do not create an artifact
  catalog or enable cache reuse.
  """

  alias Fountain.{Crypto, Environments}

  @binding_fields ~w(version user environment fingerprint provider architecture base)

  @doc "Wrap an artifact identity, binding all compatibility metadata and its object ID."
  def wrap(user_id, environment_id, artifact_id, binding, identity) do
    with :ok <- ownership(user_id, environment_id),
         {:ok, aad} <- aad(user_id, environment_id, artifact_id, binding),
         :ok <- valid_identity(identity),
         {:ok, key} <- Crypto.load_tenant_key(user_id) do
      {:ok, Crypto.encrypt(identity, key, aad)}
    end
  end

  @doc "Unwrap only for the same owner, environment, artifact and compatibility binding."
  def unwrap(user_id, environment_id, artifact_id, binding, ciphertext) do
    with :ok <- ownership(user_id, environment_id),
         {:ok, aad} <- aad(user_id, environment_id, artifact_id, binding),
         {:ok, key} <- Crypto.load_tenant_key(user_id),
         {:ok, identity} <- Crypto.decrypt(ciphertext, key, aad),
         :ok <- valid_identity(identity) do
      {:ok, identity}
    else
      :error -> {:error, :invalid_envelope}
      {:error, _} = error -> error
    end
  end

  defp ownership(user_id, environment_id) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         {:ok, environment_id} <- Ecto.UUID.cast(environment_id),
         %{} <- Environments.get_environment(environment_id, user_id) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp aad(user_id, environment_id, artifact_id, binding) when is_map(binding) do
    valid =
      Enum.sort(Map.keys(binding)) == Enum.sort(@binding_fields) and
        binding["version"] == 1 and binding["user"] == user_id and
        binding["environment"] == environment_id and
        Enum.all?(~w(fingerprint provider architecture base), fn field ->
          value = binding[field]
          is_binary(value) and byte_size(value) in 1..256
        end)

    with true <- valid,
         {:ok, _} <- Ecto.UUID.cast(artifact_id),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, binding["fingerprint"]) do
      fields = Enum.map(@binding_fields, &Map.fetch!(binding, &1))
      {:ok, Jason.encode!(["managoat.environment-layer.v1", artifact_id, fields])}
    else
      _ -> {:error, :invalid_binding}
    end
  end

  defp aad(_, _, _, _), do: {:error, :invalid_binding}

  # The Go helper performs the full age/Bech32 validation. This check prevents
  # arbitrary large payloads from using the artifact-envelope primitive.
  defp valid_identity("AGE-SECRET-KEY-1" <> rest) when byte_size(rest) in 1..128, do: :ok
  defp valid_identity(_), do: {:error, :invalid_identity}
end
