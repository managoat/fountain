defmodule Fountain.Conversations.HomeCheckpoint do
  @moduledoc """
  Checkpoint a persistent home when it parks (ADR 0023, #1073).

  A home's disk is the agent's memory across every conversation on it, so
  the moment it goes quiet is the moment its state is worth keeping. Where
  the provider advertises `:checkpoint`, a park calls `on_park/2` before
  flipping the row to `suspended`. The checkpoint id and time land in
  `sandboxes.provider_meta` (`checkpoint_id`, `checkpoint_at`) and a
  `checkpoint` stage is written to every live conversation on the machine, so
  each transcript shows it.

  **One caller, and it holds the lease.** Until ADR 0058 stage 6b the two park
  paths each called this for themselves, before their own row write. They now
  go through `Fountain.Machines.Park`, which claims the machine's lease,
  stamps `transition: "parking"` and calls this *inside* that transition — so
  the checkpoint happens while every reader already refuses the machine, and
  the `provider_meta` write is made with `Fountain.Machines.Lease.cas_update/3`
  under the park's own epoch rather than with `Conversations.update_sandbox/2`.
  A park that has been superseded writes no checkpoint id, which is the same
  compare-and-set rule the finalize follows and for the same reason: a
  checkpoint recorded by an operation that no longer owns the machine would be
  read back by a reset as the state to roll to.

  What a checkpoint can restore, honestly: on Sprites a checkpoint is scoped
  to the sprite that created it (#654) and the SDK has no "create a sprite
  from a checkpoint", so it rolls *this* machine back and cannot rebuild a
  machine that is gone. The `{:machine_gone, …}` re-provision path therefore
  does not restore from it; a reset that rolls a home back to its last park
  is the path it is for. Ephemeral sandboxes are never checkpointed here —
  their disk dies with the conversation.

  Best-effort by construction: a failed checkpoint is logged and recorded as
  a failed stage, and the park goes ahead — an unparked machine keeps billing.
  """

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Managoat.Sandbox.Retry

  require Logger

  @doc """
  Checkpoint `sandbox` if it is a home on a provider that can, recording the
  result under `epoch` — the lease the calling park holds.

  Returns the checkpoint id, `:skipped` when there is nothing to do, or the
  error after it has been recorded.
  """
  @spec on_park(Sandbox.t(), Lease.epoch()) :: {:ok, String.t()} | :skipped | {:error, term()}
  # A machine whose reset is unconfirmed keeps no checkpoint: the disk is meant
  # to be gone. `Park` refuses a fenced row before it ever gets here, so this
  # clause is now belt and braces rather than the guard it was — kept because
  # the rule belongs to the checkpoint as much as to the park, and a second
  # caller would arrive without it.
  def on_park(%Sandbox{reset_requested_at: at}, _epoch) when not is_nil(at), do: :skipped

  def on_park(%Sandbox{mode: "persistent", machine_name: name} = sandbox, epoch)
      when is_binary(name) do
    provider = Conversations.sandbox_provider_atom(sandbox)

    if Managoat.Sandbox.supports?(provider, :checkpoint) do
      create(sandbox, Managoat.Sandbox.build_handle(provider, name), epoch)
    else
      :skipped
    end
  end

  def on_park(_sandbox, _epoch), do: :skipped

  @doc "The checkpoint recorded on `sandbox`, as `%{id, at}`, or nil."
  @spec recorded(Sandbox.t()) :: %{id: String.t(), at: String.t()} | nil
  def recorded(%Sandbox{provider_meta: %{"checkpoint_id" => id} = meta}) when is_binary(id) do
    %{id: id, at: meta["checkpoint_at"]}
  end

  def recorded(_sandbox), do: nil

  defp create(sandbox, handle, epoch) do
    comment = "home park #{sandbox.id}"

    result =
      Fountain.Telemetry.span([:checkpoint, :create], %{sandbox_id: sandbox.id}, fn ->
        # Retried: a duplicate checkpoint from a lost-response retry costs
        # storage, a missing one costs the state the park was meant to keep.
        case Retry.with_backoff(
               fn -> Managoat.Sandbox.create_checkpoint(handle, comment: comment) end,
               label: "home checkpoint"
             ) do
          {:ok, id} -> {{:ok, id}, %{outcome: :ok, checkpoint_id: id}}
          {:error, reason} -> {{:error, reason}, %{outcome: :error, reason: inspect(reason)}}
        end
      end)

    case result do
      {:ok, id} ->
        record(sandbox, id, epoch)
        {:ok, id}

      {:error, reason} ->
        Logger.warning(
          "home checkpoint failed for sandbox #{sandbox.id} (#{sandbox.machine_name}): " <>
            "#{inspect(reason)}; parking without one"
        )

        publish(sandbox, "failed", %{reason: inspect(reason)})
        {:error, reason}
    end
  end

  # Not matched on with `{:ok, _} =`, unlike the `update_sandbox/2` call it
  # replaces. A compare-and-set can legitimately write nothing — the park was
  # superseded, or the row was retired while the provider was taking the
  # checkpoint — and raising there would unwind out of a park that is otherwise
  # about to answer for itself properly. The checkpoint exists at the provider
  # either way; what is lost is the pointer to it, and the log line says so.
  defp record(sandbox, id, epoch) do
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    meta =
      Map.merge(sandbox.provider_meta || %{}, %{"checkpoint_id" => id, "checkpoint_at" => at})

    case Lease.cas_update(sandbox.id, epoch, provider_meta: meta) do
      {:ok, _} ->
        Logger.info("home checkpoint #{id} for sandbox #{sandbox.id} (#{sandbox.machine_name})")
        publish(sandbox, "done", %{checkpoint_id: id})

      {:error, reason} ->
        Logger.warning(
          "home checkpoint #{id} for sandbox #{sandbox.id} (#{sandbox.machine_name}) " <>
            "could not be recorded (#{inspect(reason)}); the checkpoint itself was taken"
        )

        publish(sandbox, "failed", %{checkpoint_id: id, reason: inspect(reason)})
    end
  end

  # One stage per live conversation on the machine: the checkpoint is the
  # machine's, but transcripts are per conversation.
  # ownership: a system path — the caller is the ConversationServer or the
  # reaper acting on a sandbox row it already holds, never a tenant request.
  defp publish(sandbox, state, meta) do
    sandbox.id
    |> Conversations._unsafe_list_holder_ids()
    |> Enum.each(&Conversations.publish_stage(&1, "checkpoint", state, meta))
  end
end
