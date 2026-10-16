defmodule Fountain.EnvironmentLayers.Restore do
  @moduledoc "Restore before conversation identity; every uncertain cache failure requests a fresh cold machine."
  alias Fountain.{Broker, Environments}
  alias Fountain.EnvironmentLayers.{Builds, Envelope, Helper, Pipeline, Probe, Store}
  alias Managoat.Sandbox
  alias Managoat.Sandbox.NetworkPolicy

  @cipher "/opt/managoat-layer/restore.age"

  def attempt(handle, user_id, environment, conversation_id) do
    case measure(handle, user_id, environment, conversation_id) do
      {:cold, _} -> :cold
      {:retry_fresh, _} -> :retry_fresh
      warm -> warm
    end
  end

  def measure(handle, user_id, environment, conversation_id) do
    if handle.provider == :sprites and not is_nil(environment) and environment.cache_enabled and
         match?({:ok, _}, Store.identity()) do
      event(conversation_id, "started", %{})
      started = System.monotonic_time(:millisecond)

      result =
        try do
          restore(handle, user_id, environment)
        rescue
          _ -> :retry_fresh
        catch
          _, _ -> :retry_fresh
        end

      elapsed = System.monotonic_time(:millisecond) - started

      case result do
        {:warm, refs, metadata} ->
          {:warm, refs, Map.put(metadata, :restore_ms, elapsed)}

        {:cold, metadata} ->
          event(conversation_id, "failed", %{
            reason: "miss",
            restore_ms: elapsed,
            probe_ms: elapsed
          })

          {:cold, Map.put(metadata, :restore_ms, elapsed)}

        :retry_fresh ->
          event(conversation_id, "failed", %{reason: "fresh_cold_fallback", restore_ms: elapsed})
          {:retry_fresh, %{restore_ms: elapsed}}

        {:retry_fresh, metadata} ->
          event(conversation_id, "failed", %{reason: "fresh_cold_fallback", restore_ms: elapsed})
          {:retry_fresh, Map.put(metadata, :restore_ms, elapsed)}
      end
    else
      {:cold, %{}}
    end
  end

  defp restore(handle, user_id, environment) do
    started = System.monotonic_time(:millisecond)

    with %{} = current <- Environments.get_environment(environment.id, user_id),
         true <-
           current.build_generation == environment.build_generation and
             current.build_policy_revision == environment.build_policy_revision,
         {:ok, compatibility} <- Probe.run(handle, current) do
      case Builds.ready(user_id, current.id, compatibility) do
        nil ->
          _ = Pipeline.enqueue(user_id, current.id, compatibility)
          {:cold, %{probe_ms: System.monotonic_time(:millisecond) - started}}

        build ->
          download(
            handle,
            user_id,
            current,
            compatibility,
            build,
            System.monotonic_time(:millisecond) - started
          )
      end
    else
      _ -> :retry_fresh
    end
  end

  defp download(handle, user_id, environment, compatibility, build, probe_ms) do
    environment_id = environment.id
    started = System.monotonic_time(:millisecond)

    with {:ok, grant} <- Store.grant(user_id, environment_id, build.id, :get),
         :ok <- floor(handle, [Broker.proxy_host(), URI.parse(grant.origin).host]),
         {:ok, _} <-
           Helper.call(handle, %{
             operation: "fetch",
             url: grant.url,
             origin: grant.origin,
             output: @cipher
           }),
         :ok <- floor(handle, [Broker.proxy_host()]),
         fetch_ms = System.monotonic_time(:millisecond) - started,
         %{} = current <- Environments.get_environment(environment_id, user_id),
         true <- current.build_policy_revision == environment.build_policy_revision,
         %{id: id} <- Builds.ready(user_id, environment_id, compatibility),
         true <- id == build.id,
         {:ok, identity} <-
           Envelope.unwrap(
             user_id,
             environment_id,
             build.id,
             build.binding,
             build.wrapped_identity
           ),
         {:ok, _} <-
           Helper.call(handle, %{
             operation: "restore",
             input: @cipher,
             output: "/",
             identity: identity,
             sha256: build.ciphertext_sha256,
             binding: build.binding
           }) do
      {:warm, compatibility["revisions"],
       %{
         bytes: build.ciphertext_bytes,
         build_id: build.id,
         fingerprint: build.binding["fingerprint"],
         probe_ms: probe_ms,
         fetch_ms: fetch_ms,
         authenticate_extract_ms: System.monotonic_time(:millisecond) - started - fetch_ms
       }}
    else
      _ -> {:retry_fresh, %{probe_ms: probe_ms}}
    end
  end

  defp floor(handle, hosts),
    do: Sandbox.apply_network_policy(handle, %NetworkPolicy{allow: Enum.uniq(hosts)})

  def event(nil, _state, _meta), do: :ok

  def event(id, state, meta),
    do: Fountain.Conversations.publish_stage(id, "checkpoint_restore", state, meta)
end
