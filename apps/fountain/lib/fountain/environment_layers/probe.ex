defmodule Fountain.EnvironmentLayers.Probe do
  @moduledoc "Credential-free base inventory and short-lived environment-only Git revision probing."
  alias Fountain.{Broker, Crypto, Environments, Repo, SecretBindings}
  alias Fountain.Broker.{Native, TransportRelay}
  alias Fountain.Broker.Native.Sessions
  alias Fountain.Conversations.Provisioning
  alias Fountain.EnvironmentLayers.Helper
  alias Managoat.Sandbox
  alias Managoat.Sandbox.NetworkPolicy

  def run(handle, env) do
    with :ok <- Sandbox.apply_network_policy(handle, %NetworkPolicy{allow: [Broker.proxy_host()]}),
         {:ok, arch, 0} <- Sandbox.exec(handle, "uname", ["-m"], timeout: 10_000),
         {:ok, architecture} <- architecture(String.trim(arch)),
         :ok <- Helper.install(handle, architecture),
         :ok <- Provisioning.install_broker_ca(handle, nil),
         :ok <- TransportRelay.ensure(handle, env.id),
         {:ok, %{"result" => baseline}} <-
           Helper.call(handle, %{
             operation: "snapshot",
             input: "/",
             output: "/opt/managoat-layer/probe.json"
           }),
         {:ok, revisions} <- revisions(handle, env),
         :ok <- TransportRelay.stop(handle) do
      {:ok,
       %{
         "provider" => "sprites",
         "architecture" => architecture,
         "base" => baseline["base"],
         "revisions" => revisions
       }}
    else
      _ -> {:error, :probe_failed}
    end
  end

  defp revisions(_handle, %{repositories: []}), do: {:ok, []}

  defp revisions(handle, env) do
    with {:ok, dek} <- Crypto.load_tenant_key(env.user_id),
         {:ok, values} <- secrets(env, dek) do
      bindings = SecretBindings.enabled_by_key(env.user_id)
      {placeholders, brokered} = Broker.split(values, bindings)
      network = Broker.network_for(env)

      if map_size(values) != map_size(brokered) do
        {:error, :unbrokered_repository_secret}
      else
        with {:ok, session} <-
               Sessions.create_probe(env, Native.rules_for(brokered, bindings, network), network) do
          try do
            Enum.reduce_while(env.repositories, {:ok, []}, fn repo, {:ok, refs} ->
              case resolve(handle, repo, placeholders, Broker.sandbox_env(session)) do
                {:ok, ref} -> {:cont, {:ok, refs ++ [ref]}}
                _ -> {:halt, {:error, :revision_unavailable}}
              end
            end)
          after
            Sessions.release_probe(env.user_id, session.token)
          end
        end
      end
    end
  end

  defp secrets(env, dek) do
    keys = Enum.map(env.repositories, & &1["secret_key"])
    # env is the caller's tenant-scoped environment, never a conversation/vault.
    env = Repo.preload(env, :secrets)

    Enum.reduce_while(env.secrets, {:ok, %{}}, fn secret, {:ok, values} ->
      if secret.key in keys do
        case Environments.Secret.decrypt(secret, dek) do
          {:ok, value} -> {:cont, {:ok, Map.put(values, secret.key, value)}}
          _ -> {:halt, {:error, :secret_unavailable}}
        end
      else
        {:cont, {:ok, values}}
      end
    end)
  end

  defp resolve(handle, repo, secrets, env) do
    ref = repo["branch"] || "HEAD"

    if Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, ref) do
      {:ok, ref}
    else
      url = Provisioning.inject_token(repo["url"], repo["secret_key"], secrets)

      with {:ok, output, 0} <-
             Sandbox.exec(
               handle,
               "git",
               [
                 "ls-remote",
                 "--exit-code",
                 "--",
                 url,
                 ref,
                 "refs/heads/" <> ref,
                 "refs/tags/" <> ref,
                 "refs/tags/" <> ref <> "^{}"
               ],
               env: env,
               timeout: 30_000
             ),
           true <- byte_size(output) < 8192 do
        parse_revision(output, ref)
      else
        _ -> {:error, :revision_unavailable}
      end
    end
  end

  @doc false
  def parse_revision(output, ref) do
    entries =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, "\t") do
          [sha, name] ->
            if Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, sha),
              do: [{name, sha}],
              else: []

          _ ->
            []
        end
      end)
      |> Map.new()

    case Enum.find_value(
           ["refs/heads/" <> ref, "refs/tags/" <> ref <> "^{}", "refs/tags/" <> ref, ref],
           &entries[&1]
         ) do
      nil -> {:error, :revision_unavailable}
      sha -> {:ok, sha}
    end
  end

  defp architecture("x86_64"), do: {:ok, "amd64"}
  defp architecture("aarch64"), do: {:ok, "arm64"}
  defp architecture(_), do: {:error, :unsupported_architecture}
end
