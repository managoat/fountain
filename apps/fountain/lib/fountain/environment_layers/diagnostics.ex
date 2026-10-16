defmodule Fountain.EnvironmentLayers.Diagnostics do
  @moduledoc "Bounded build phase evidence; never accepts output or request metadata."
  import Ecto.Query
  alias Fountain.{Audit, Repo}
  alias Fountain.EnvironmentLayers.Build

  @phases ~w(network_floor helper_install architecture broker_ca broker_relay baseline process_snapshot credentials packages repositories build_script revoke_broker stop_relay helper_reinstall quiescent_before_export export quiescent_before_seal keygen seal quiescent_before_upload upload_grant upload_floor upload verify_upload provision cleanup publication total worker_wait)a
  @classes ~w(base_mismatch architecture_mismatch artifact_mismatch timeout canceled helper_unavailable layer_operation_failed build_failed obsolete obsolete_or_claimed publication_refused cleanup_pending exception exit throw worker_exit build_canceled)a
  @helper_codes ~w(invalid_request key_generation_failed operation_failed invalid_layer limit_exceeded incompatible_layer authentication_failed unsafe_archive transfer_failed canceled timeout)

  def phase(input, phase, fun) when phase in @phases and is_function(fun, 0) do
    started = System.monotonic_time(:millisecond)
    # Admission is claim-fenced. Finish belongs to this admitted attempt even
    # when publication/failure clears its claim; diagnostics never mutate builds.
    admitted = admitted?(input)

    if admitted, do: record(input, phase, %{status: "started"})

    result =
      try do
        fun.()
      rescue
        _ -> {:error, :exception}
      catch
        :exit, _ -> {:error, :exit}
        :throw, _ -> {:error, :throw}
      end

    metadata =
      result
      |> outcome()
      |> Map.put(:elapsed_ms, max(0, System.monotonic_time(:millisecond) - started))

    if admitted, do: record(input, phase, metadata)
    result
  end

  defp admitted?(input) do
    Repo.exists?(
      from b in Build,
        where:
          b.user_id == ^input.user_id and b.id == ^input.build_id and
            b.claim == ^input.claim and b.state == "building"
    )
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc "Completed attempt costs for the artifact's owner, generation, fingerprint and store."
  def costs(user_id, build_id) do
    case Repo.get_by(Build, user_id: user_id, id: build_id) do
      nil -> []
      build -> generation_costs(build)
    end
  rescue
    _ -> [%{"status" => "unknown", "elapsed_ms" => nil}]
  catch
    :exit, _ -> [%{"status" => "unknown", "elapsed_ms" => nil}]
  end

  defp generation_costs(build) do
    Repo.all(
      from b in Build,
        left_join: e in Audit.Event,
        on:
          e.user_id == b.user_id and e.resource_id == fragment("?::text", b.id) and
            e.action == "environment_layer.phase" and
            fragment("?->>'phase' = 'total'", e.metadata) and
            fragment("?->>'status' IN ('ok', 'failed')", e.metadata),
        where:
          b.user_id == ^build.user_id and b.environment_ref == ^build.environment_ref and
            b.generation == ^build.generation and b.fingerprint == ^build.fingerprint and
            b.store_ref == ^build.store_ref,
        order_by: b.inserted_at,
        select: e.metadata
    )
    |> Enum.map(fn
      nil -> %{"status" => "unknown", "elapsed_ms" => nil}
      metadata -> Map.take(metadata, ["status", "elapsed_ms"])
    end)
  end

  defp outcome({:ok, :provisioned, {:error, reason}}), do: outcome({:error, reason})

  defp outcome({:error, {:unavailable, {:exec_timeout, _}}}),
    do: %{status: "failed", failure: "timeout"}

  defp outcome({:error, {:unavailable, :timeout}}), do: %{status: "failed", failure: "timeout"}
  defp outcome({:error, {:unavailable, _}}), do: %{status: "failed", failure: "unavailable"}
  defp outcome({:error, {:provider, _, _}}), do: %{status: "failed", failure: "provider_error"}
  defp outcome({:error, {:denied, _}}), do: %{status: "failed", failure: "denied"}
  defp outcome(:ok), do: %{status: "ok"}
  defp outcome({:ok, result}) when is_map(result), do: %{status: "ok"}
  defp outcome({:ok, :provisioned, {:ok, _}}), do: %{status: "ok"}

  defp outcome({:ok, secrets, session}) when is_map(secrets) and is_map(session),
    do: %{status: "ok"}

  defp outcome({:error, {:command_exit, code}}) when code in 0..255,
    do: %{status: "failed", failure: "command_exit", exit_code: code}

  defp outcome({:error, {:helper_failed, code, exit_code}})
       when code in @helper_codes and exit_code in 0..255,
       do: %{status: "failed", failure: code, exit_code: exit_code}

  defp outcome({:error, class}) when class in @classes,
    do: %{status: "failed", failure: Atom.to_string(class)}

  defp outcome(_), do: %{status: "failed", failure: "operation_failed"}

  defp record(input, phase, metadata) do
    Audit.record(%{
      user_id: input.user_id,
      resource_id: input.build_id,
      resource_type: "environment_layer",
      action: "environment_layer.phase",
      actor: "system:environment_layers",
      metadata: Map.put(metadata, :phase, Atom.to_string(phase))
    })
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
