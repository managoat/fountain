defmodule Fountain.EnvironmentLayers.Pipeline do
  @moduledoc """
  Production environment-only build/export callback. The caller must supply
  resolved revisions and the content-derived base identity measured on a fresh
  machine; an unknown or different base refuses the build. No conversation,
  vault, inference grant, callback key, runtime or skill participates.
  """
  alias Fountain.{Broker, Crypto, Environments, Repo, SecretBindings}
  alias Fountain.Broker.{Native, TransportRelay}
  alias Fountain.Broker.Native.Sessions
  alias Fountain.Conversations.Provisioning
  alias Fountain.EnvironmentLayers.{Builds, Helper}
  alias Managoat.Sandbox
  alias Managoat.Sandbox.NetworkPolicy

  @base "/opt/managoat-layer/base.json"
  @processes "/opt/managoat-layer/processes.json"
  @tar "/opt/managoat-layer/layer.tar"
  @sealed "/opt/managoat-layer/layer.age"

  @doc "Queue a build with compatibility established by trusted fresh-machine probing."
  def enqueue(user_id, environment_id, compatibility) do
    with true <-
           is_binary(compatibility["base"]) and
             Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, compatibility["base"]),
         {:ok, build} <- Builds.request(user_id, environment_id, compatibility) do
      if build.state == "queued" do
        case Fountain.Workers.EnvironmentLayerBuild.new(%{user_id: user_id, build_id: build.id})
             |> Oban.insert() do
          {:ok, _} ->
            {:ok, build}

          {:error, _} ->
            Builds.cancel(user_id, build.id)
            {:error, :build_unavailable}
        end
      else
        {:ok, build}
      end
    else
      _ -> {:error, :build_unavailable}
    end
  end

  def run(user_id, build_id, opts \\ []) do
    Builds.run(user_id, build_id, &build(&1, &2, opts), opts)
  end

  def build(handle, input, opts \\ []) do
    try do
      with :ok <- floor(handle, [Broker.proxy_host()]),
           :ok <- Helper.install(handle, input.binding["architecture"]),
           {:ok, architecture, 0} <- Sandbox.exec(handle, "uname", ["-m"], timeout: 10_000),
           true <- String.trim(architecture) == machine_arch(input.binding["architecture"]),
           :ok <- Provisioning.install_broker_ca(handle, nil),
           :ok <- TransportRelay.ensure(handle, input.build_id),
           {:ok, %{"result" => baseline}} <-
             Helper.call(handle, %{operation: "snapshot", input: "/", output: @base}),
           true <- baseline["base"] == input.binding["base"],
           {:ok, %{"result" => processes}} <-
             Helper.call(handle, %{operation: "process_snapshot", output: @processes}),
           {:ok, secrets, session} <- credentials(input),
           :ok <- setup(handle, input, secrets, session),
           :ok <- Sessions.release_build(input.user_id, input.build_id),
           :ok <- TransportRelay.stop(handle),
           :ok <- Helper.install(handle, input.binding["architecture"]),
           {:ok, _} <-
             Helper.call(handle, %{
               operation: "quiescent",
               input: @processes,
               sha256: processes["sha256"]
             }),
           {:ok, _} <-
             Helper.call(handle, %{
               operation: "export",
               input: "/",
               baseline: @base,
               output: @tar,
               sha256: baseline["sha256"]
             }),
           {:ok, _} <-
             Helper.call(handle, %{
               operation: "quiescent",
               input: @processes,
               sha256: processes["sha256"]
             }),
           {:ok, key} <- Helper.keygen(),
           {:ok, %{"result" => artifact}} <-
             Helper.call(handle, %{
               operation: "seal",
               input: @tar,
               output: @sealed,
               recipient: key["recipient"],
               binding: input.binding
             }),
           {:ok, _} <-
             Helper.call(handle, %{
               operation: "quiescent",
               input: @processes,
               sha256: processes["sha256"]
             }),
           {:ok, grant} <- Builds.upload_grant(input.user_id, input.build_id, input.claim, opts),
           :ok <- floor(handle, [URI.parse(grant.origin).host]),
           {:ok, %{"result" => uploaded}} <-
             Helper.call(handle, %{
               operation: "upload",
               input: @sealed,
               url: grant.url,
               origin: grant.origin,
               sha256: artifact["sha256"]
             }),
           true <-
             uploaded["sha256"] == artifact["sha256"] and uploaded["bytes"] == artifact["bytes"] do
        {:ok, %{sha256: artifact["sha256"], bytes: artifact["bytes"], identity: key["identity"]}}
      else
        _ -> {:error, :build_failed}
      end
    after
      Sessions.release_build(input.user_id, input.build_id)
    end
  end

  defp credentials(input) do
    with %{} = env <- Environments.get_environment(input.environment_id, input.user_id),
         {:ok, dek} <- Crypto.load_tenant_key(input.user_id),
         {:ok, values} <- decrypt_secrets(Repo.preload(env, :secrets), dek) do
      bindings = SecretBindings.enabled_by_key(input.user_id)
      {plain, brokered} = Broker.split(values, bindings)
      network = Broker.network_for(input)
      rules = Native.rules_for(brokered, bindings, network)

      with {:ok, session} <-
             Sessions.create_build(input.user_id, input.build_id, input.claim, rules, network) do
        {:ok, plain, session}
      end
    else
      _ -> {:error, :build_failed}
    end
  end

  defp decrypt_secrets(env, dek) do
    Enum.reduce_while(env.secrets, {:ok, %{}}, fn secret, {:ok, values} ->
      case Fountain.Environments.Secret.decrypt(secret, dek) do
        {:ok, value} -> {:cont, {:ok, Map.put(values, secret.key, value)}}
        _ -> {:halt, {:error, :build_failed}}
      end
    end)
  end

  defp setup(handle, input, secrets, session) do
    env = input.env_vars |> Map.merge(secrets) |> Map.to_list()
    # Proxy settings win over tenant values: the floor only permits this broker.
    env = Map.new(env) |> Map.merge(Map.new(Broker.sandbox_env(session))) |> Map.to_list()
    commands = Provisioning.build_package_commands(input.packages)

    with :ok <- commands(handle, commands, env, input.timeout_seconds),
         :ok <- repositories(handle, input, secrets, env) do
      command(handle, input.build_script, env, input.timeout_seconds)
    end
  end

  defp repositories(handle, input, secrets, env) do
    Enum.zip(input.repositories, input.revisions)
    |> Enum.reduce_while(:ok, fn {repo, revision}, _ ->
      url = Provisioning.inject_token(repo["url"], repo["secret_key"], secrets)
      dir = quote_shell(repo["mount_path"])

      script =
        "git clone --no-checkout -- " <>
          quote_shell(url) <>
          " " <>
          dir <>
          " && git -C " <>
          dir <>
          " fetch --depth=1 origin " <>
          quote_shell(revision) <>
          " && git -C " <>
          dir <>
          " checkout --detach " <>
          quote_shell(revision) <>
          " && test \"$(git -C " <> dir <> " rev-parse HEAD)\" = " <> quote_shell(revision)

      case command(handle, script, env, input.timeout_seconds) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp commands(handle, scripts, env, timeout) do
    Enum.reduce_while(scripts, :ok, fn script, _ ->
      case command(handle, script, env, timeout) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp command(_handle, "", _env, _timeout), do: :ok

  defp command(handle, script, env, timeout) do
    case Sandbox.exec(handle, "bash", ["-c", script],
           env: env,
           timeout: timeout * 1000,
           on_output: fn _ -> :ok end
         ) do
      {:ok, _, 0} -> :ok
      _ -> {:error, :build_failed}
    end
  end

  defp floor(handle, hosts),
    do: Sandbox.apply_network_policy(handle, %NetworkPolicy{allow: hosts})

  defp machine_arch("amd64"), do: "x86_64"
  defp machine_arch("arm64"), do: "aarch64"
  defp quote_shell(value), do: Provisioning.shell_quote(value)
end
