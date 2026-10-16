defmodule Fountain.EnvironmentLayers.Manifest do
  @moduledoc """
  Tenant-keyed build identity. Compatibility is supplied by the trusted provider
  integration, never inferred from an OS label. Revisions are resolved immutable
  Git object IDs in the environment's repository order. No build inputs or secret
  values are persisted in the artifact binding.
  """
  import Ecto.Query
  alias Fountain.{Crypto, Repo}
  alias Fountain.Environments.Secret

  def binding(env, %{
        "provider" => "sprites",
        "architecture" => arch,
        "base" => base,
        "revisions" => revisions
      }) do
    with true <- arch in ["amd64", "arm64"],
         true <- is_binary(base) and byte_size(base) in 1..256,
         true <- valid_revisions?(revisions, env.repositories),
         {:ok, key} <- Crypto.load_tenant_key(env.user_id) do
      secrets =
        Repo.all(
          from s in Secret,
            where: s.environment_id == ^env.id,
            order_by: s.key,
            select: {s.key, s.inference_revision}
        )

      inputs = [
        "managoat.environment-build.v1",
        env.id,
        "sprites",
        arch,
        base,
        env.packages,
        env.env_vars,
        env.repositories,
        revisions,
        env.build_script,
        env.setup_timeout_seconds,
        Enum.map(secrets, &Tuple.to_list/1)
      ]

      digest = :crypto.mac(:hmac, :sha256, key, Jason.encode!(canonical(inputs)))

      {:ok,
       %{
         "version" => 1,
         "user" => env.user_id,
         "environment" => env.id,
         "fingerprint" => Base.encode16(digest, case: :lower),
         "provider" => "sprites",
         "architecture" => arch,
         "base" => base
       }}
    else
      _ -> {:error, :incompatible_build}
    end
  end

  def binding(_, _), do: {:error, :incompatible_build}

  defp valid_revisions?(refs, repos) when is_list(refs) and is_list(repos) do
    length(refs) == length(repos) and
      Enum.all?(
        refs,
        &(is_binary(&1) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, &1))
      )
  end

  defp valid_revisions?(_, _), do: false

  defp canonical(value) when is_map(value),
    do: [
      "map",
      value |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {k, v} -> [k, canonical(v)] end)
    ]

  defp canonical(value) when is_list(value), do: ["list", Enum.map(value, &canonical/1)]
  defp canonical(value), do: value
end
