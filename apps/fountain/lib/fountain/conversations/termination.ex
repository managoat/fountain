defmodule Fountain.Conversations.Termination do
  @moduledoc """
  The client half of terminate and release: what a caller does to end a
  conversation, whether or not its `ConversationServer` is alive.

  Moved out of `Fountain.Conversations.ConversationServer` and
  `Fountain.Conversations.Lifecycle` in #2209 (one owner per lifecycle verb,
  #2175). The server keeps the actor halves — `handle_call({:terminate_conv, ..})`,
  `handle_call(:release_conv)`, `terminate_machine`, `terminate_kept_machine`,
  `finish_termination` and OTP `terminate/2` — because each needs
  `state.handle` or orders a row write against the reply. Everything here is a
  function over a conversation id, the registry and rows.

  The row writes stay in `Fountain.Conversations`
  (`_unsafe_release_conversation/2`, `_unsafe_finish_conversation_termination/2`,
  `_unsafe_fence_sandbox_for_teardown/2`).

  Tenant scoping is the caller's job: every public function here is reached
  after a tenant-scoped fetch established ownership at the controller,
  `Fountain.Team`, `Fountain.Accounts.Deletion` or a system sweep, exactly as
  when these lived on the server. `ConversationServer.terminate_conversation/2`
  and `release_conversation/2` delegate here so no caller moved.
  """

  alias Fountain.Conversations

  import Fountain.Conversations.ConversationServer, only: [whereis: 1, call_server: 2]

  @doc """
  Terminate the conversation. If the GenServer is alive, it tears down the
  sprite. If not, just mark the DB rows terminated so the user can still
  clean up dead conversations after a server restart.

  An enclosing database transaction is refused before contacting the actor or
  updating rows, so teardown cannot escape a caller's rollback.

  Named `terminate_conversation` rather than `terminate`: taking `opts` for
  audit attribution (#545) would have made this `terminate/2`, which is the
  OTP callback on `ConversationServer`. Two different meanings under one name in one module was
  already a readability trap — `ConversationServer.terminate/1` (stop this
  tenant's conversation) and `terminate/2` (OTP teardown) are unrelated — so
  the client half gets the unambiguous name.
  """
  def terminate_conversation(conv_id, opts \\ []) do
    if Fountain.Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      # ownership: callers established this conversation's tenant. Cleanup must
      # survive a blocked actor, failed provider teardown, or subsequent deletion.
      case Fountain.Conversations.ExecutionGuard._unsafe_interrupt(conv_id) do
        {:ok, _} -> terminate_after_retirement(conv_id, opts)
        {:error, :not_found} -> {:error, :not_running}
        {:error, _} = error -> error
      end
    end
  end

  defp terminate_after_retirement(conv_id, opts) do
    result =
      case whereis(conv_id) do
        nil ->
          # ownership: established by the caller before terminate_conversation/2.
          case Conversations._unsafe_get_conversation(conv_id) do
            nil ->
              {:error, :not_running}

            conv ->
              with {:ok, terminated} <-
                     Conversations.update_conversation(conv, %{status: "terminated"}) do
                retire_terminated_sandbox(terminated, opts)
              end
          end

        pid ->
          call_server(pid, {:terminate_conv, Keyword.take(opts, [:actor, :request_ip])})
      end

    audit_lifecycle(conv_id, "conversation.terminated", result, opts)
    result
  end

  @doc """
  End the conversation but keep its computer: the conversation goes
  `terminated` (past resuming, its transcript intact), the sandbox row and
  the sprite behind it are left exactly as they are, and this server stops
  holding them. The callback key this server minted is revoked on the way
  out (`terminate/2`), so nothing on the sandbox can act as the retired
  conversation.

  This is how a teammate starts a fresh conversation on the same computer
  (`Fountain.Team.open_fresh_conversation/3`): the successor conversation
  takes the `sandbox_id`, and its first prompt reattaches through the
  ordinary wake path — a new runtime session on the same disk.

  `{:error, :busy}` while a turn runs on a **live** server; nothing is
  interrupted. With no server alive that row is as likely an orphan (see
  `Conversations.wake_for_interrupt/1`), so release proceeds. Unresolved
  bounded execution answers `{:error, :execution_fenced}` either way: a
  durable fact rather than an inference, and bounded (ADR 0046).

  Audited as `conversation.released` unless `audit: false`.
  """
  def release_conversation(conv_id, opts \\ []) do
    result =
      case whereis(conv_id) do
        nil ->
          # ownership: established by the caller before release_conversation/2.
          Conversations._unsafe_release_conversation(conv_id, actor_alive?: false)

        pid ->
          call_server(pid, :release_conv)
      end

    audit_lifecycle(conv_id, "conversation.released", result, opts)
    result
  end

  @doc """
  Retire the machine of an authorized, terminated conversation with no actor.
  The conditional fence preserves homes and other live co-tenants, and blocks
  new attachments before the terminal write. No provider I/O runs here; the
  reaper handles terminal rows. The caller owns the conversation lifecycle
  audit; the fence records teardown intent using the supplied attribution.
  """
  def retire_terminated_sandbox(%{sandbox_id: nil}, _opts), do: :ok

  def retire_terminated_sandbox(conv, opts) do
    opts =
      opts
      |> Keyword.put(:terminating_conversation_id, conv.id)
      |> Keyword.put_new(:reason, "conversation_terminated")

    # ownership: this sandbox belongs to the conversation authorized by the caller.
    case Conversations._unsafe_get_sandbox(conv.sandbox_id) do
      nil ->
        {:error, :sandbox_unavailable}

      sandbox ->
        # ownership: the authorized conversation supplies this sandbox; the fence rechecks binding.
        case Conversations._unsafe_fence_sandbox_for_teardown(sandbox, opts) do
          {:ok, %{status: status}} when status in ["terminated", "failed"] ->
            :ok

          {:ok, fenced} ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)

            with {:ok, _} <-
                   Conversations.update_sandbox(fenced, %{
                     status: "terminated",
                     terminated_at: now
                   }) do
              :ok
            end

          {:error, :sandbox_kept} ->
            :ok

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  The journal door for `Conversations._unsafe_release_conversation/2`: the
  same durable-idle-parent release `ExecutionGuard._unsafe_release_parent/3`
  performs, exposed so that module is the journal's only caller outside
  `ExecutionGuard` itself. Arguments and return are the guard's, unchanged.
  """
  def release_journal(conversation_id, writer, opts \\ []) do
    # ownership: the caller (Conversations._unsafe_release_conversation/2)
    # already received an owned conversation id from its own caller.
    Fountain.Conversations.ExecutionGuard._unsafe_release_parent(conversation_id, writer, opts)
  end

  # Records a lifecycle action against the conversation's owner.
  #
  # Only on success: an attempt against a conversation that is not running
  # changed nothing, and a trail that logged it would show terminations that
  # never happened.
  #
  # `audit: false` suppresses the row where a caller's own higher-level event
  # already describes the action — `delete_conversation/2` and account
  # deletion both cascade through `terminate/2`, and neither is a second thing
  # the user asked for.
  #
  # The `_unsafe_` read is legitimate here under the rule in CLAUDE.md: these
  # are GenServer client functions, reached only after a tenant-scoped fetch
  # established ownership at the controller or LiveView, and the read exists
  # solely to attribute the event to that same owner.
  def audit_lifecycle(conv_id, action, result, opts, metadata \\ %{}) do
    if Keyword.get(opts, :audit, true) and result == :ok do
      case Conversations._unsafe_get_conversation(conv_id) do
        nil ->
          :ok

        conv ->
          Fountain.Audit.record(%{
            user_id: conv.user_id,
            action: action,
            resource_type: "conversation",
            resource_id: conv_id,
            actor: Keyword.get(opts, :actor, "self"),
            request_ip: Keyword.get(opts, :request_ip),
            metadata: metadata
          })
      end
    end

    :ok
  end
end
