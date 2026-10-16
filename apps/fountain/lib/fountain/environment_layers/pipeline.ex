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
  alias Fountain.EnvironmentLayers.{Builds, Diagnostics, Helper}
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
      with :ok <-
             Diagnostics.phase(input, :network_floor, fn ->
               floor(handle, [Broker.proxy_host()])
             end),
           :ok <-
             Diagnostics.phase(input, :helper_install, fn ->
               Helper.install(handle, input.binding["architecture"])
             end),
           :ok <-
             Diagnostics.phase(input, :architecture, fn ->
               case Sandbox.exec(handle, "uname", ["-m"], timeout: 10_000) do
                 {:ok, architecture, 0} ->
                   if String.trim(architecture) == machine_arch(input.binding["architecture"]),
                     do: :ok,
                     else: {:error, :architecture_mismatch}

                 {:ok, _, code} ->
                   {:error, {:command_exit, code}}

                 error ->
                   error
               end
             end),
           :ok <-
             Diagnostics.phase(input, :broker_ca, fn ->
               Provisioning.install_broker_ca(handle, nil)
             end),
           :ok <-
             Diagnostics.phase(input, :broker_relay, fn ->
               TransportRelay.ensure(handle, input.build_id)
             end),
           {:ok, %{"result" => baseline}} <-
             Diagnostics.phase(input, :baseline, fn ->
               with {:ok, %{"result" => baseline}} <-
                      Helper.call(handle, %{operation: "snapshot", input: "/", output: @base}) do
                 if baseline["base"] == input.binding["base"],
                   do: {:ok, %{"result" => baseline}},
                   else: {:error, :base_mismatch}
               end
             end),
           {:ok, %{"result" => processes}} <-
             Diagnostics.phase(input, :process_snapshot, fn ->
               Helper.call(handle, %{operation: "process_snapshot", output: @processes})
             end),
           {:ok, secrets, session} <-
             Diagnostics.phase(input, :credentials, fn -> credentials(input) end),
           :ok <- setup(handle, input, secrets, session),
           :ok <-
             Diagnostics.phase(input, :revoke_broker, fn ->
               Sessions.release_build(input.user_id, input.build_id)
             end),
           :ok <- Diagnostics.phase(input, :stop_relay, fn -> TransportRelay.stop(handle) end),
           :ok <-
             Diagnostics.phase(input, :helper_reinstall, fn ->
               Helper.install(handle, input.binding["architecture"])
             end),
           {:ok, _} <-
             Diagnostics.phase(input, :quiescent_before_export, fn ->
               Helper.call(handle, %{
                 operation: "quiescent",
                 input: @processes,
                 sha256: processes["sha256"]
               })
             end),
           {:ok, _} <-
             Diagnostics.phase(input, :export, fn ->
               Helper.call(handle, %{
                 operation: "export",
                 input: "/",
                 baseline: @base,
                 output: @tar,
                 sha256: baseline["sha256"]
               })
             end),
           {:ok, _} <-
             Diagnostics.phase(input, :quiescent_before_seal, fn ->
               Helper.call(handle, %{
                 operation: "quiescent",
                 input: @processes,
                 sha256: processes["sha256"]
               })
             end),
           {:ok, key} <- Diagnostics.phase(input, :keygen, fn -> Helper.keygen() end),
           {:ok, %{"result" => artifact}} <-
             Diagnostics.phase(input, :seal, fn ->
               Helper.call(handle, %{
                 operation: "seal",
                 input: @tar,
                 output: @sealed,
                 recipient: key["recipient"],
                 binding: input.binding
               })
             end),
           {:ok, _} <-
             Diagnostics.phase(input, :quiescent_before_upload, fn ->
               Helper.call(handle, %{
                 operation: "quiescent",
                 input: @processes,
                 sha256: processes["sha256"]
               })
             end),
           {:ok, grant} <-
             Diagnostics.phase(input, :upload_grant, fn ->
               Builds.upload_grant(input.user_id, input.build_id, input.claim, opts)
             end),
           :ok <-
             Diagnostics.phase(input, :upload_floor, fn ->
               floor(handle, [URI.parse(grant.origin).host])
             end),
           {:ok, %{"result" => uploaded}} <-
             Diagnostics.phase(input, :upload, fn ->
               Helper.call(handle, %{
                 operation: "upload",
                 input: @sealed,
                 url: grant.url,
                 origin: grant.origin,
                 sha256: artifact["sha256"]
               })
             end),
           :ok <-
             Diagnostics.phase(input, :verify_upload, fn ->
               if uploaded["sha256"] == artifact["sha256"] and
                    uploaded["bytes"] == artifact["bytes"],
                  do: :ok,
                  else: {:error, :artifact_mismatch}
             end) do
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

    with :ok <-
           Diagnostics.phase(input, :packages, fn ->
             commands(handle, commands, env, input.timeout_seconds)
           end),
         :ok <-
           Diagnostics.phase(input, :repositories, fn ->
             repositories(handle, input, secrets, env)
           end) do
      Diagnostics.phase(input, :build_script, fn ->
        command(handle, input.build_script, env, input.timeout_seconds)
      end)
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
      {:ok, _, code} when code in 0..255 -> {:error, {:command_exit, code}}
      {:error, :timeout} -> {:error, :timeout}
      _ -> {:error, :build_failed}
    end
  end

  defp floor(handle, hosts),
    do: Sandbox.apply_network_policy(handle, %NetworkPolicy{allow: hosts})

  defp machine_arch("amd64"), do: "x86_64"
  defp machine_arch("arm64"), do: "aarch64"
  defp quote_shell(value), do: Provisioning.shell_quote(value)
end
