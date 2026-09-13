defmodule FountainWeb.FallbackController do
  @moduledoc false
  use FountainWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: FountainWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end

  def call(conn, {:error, {:execution_limits_invalid, field}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "execution_limits_invalid",
      errors: %{execution_limits: ["invalid #{field}"]}
    })
  end

  def call(conn, {:error, {:execution_limits_widen, field}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "execution_limits_widen",
      errors: %{execution_limits: ["cannot widen #{field}"]}
    })
  end

  def call(conn, {:error, {:execution_limits_unsupported, controls}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "execution_limits_unsupported",
      message: "Execution-limit enforcement is unavailable: #{Enum.join(controls, ", ")}."
    })
  end

  # Opening input a launch cannot use (Fountain.Conversations.PromptInput).
  # Refused before any sandbox is reserved, so nothing was spent. Named here
  # rather than left to the terminal safety net below: these are ordinary
  # client mistakes, and the net logs a warning and answers without a message.
  def call(conn, {:error, :invalid_prompt}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_prompt",
      message:
        "prompt must be a string with words in it; images require one. " <>
          "Omit both to open a conversation with no first turn."
    })
  end

  def call(conn, {:error, :invalid_images}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_images",
      message:
        "each image needs a supported media_type (" <>
          Enum.join(Fountain.Images.valid_media_types(), ", ") <>
          ") and between 1 byte and " <>
          "#{div(Fountain.Images.max_prompt_image_bytes(), 1024 * 1024)}MB of data"
    })
  end

  # start_conversation rejects an unknown / cross-tenant vault by returning
  # {:error, :vault_not_found}. Surface as 404 so callers can't tell the
  # difference between "no such vault" and "vault belongs to someone else".
  def call(conn, {:error, :vault_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "vault_not_found"})
  end

  # The agent's allowed_vault_ids forbids attaching this (existing, same-
  # tenant) vault. Unlike :vault_not_found this is a policy denial, so a
  # distinct status + message tells the caller which knob to look at.
  def call(conn, {:error, :vault_not_allowed}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "vault_not_allowed",
      message: "vault is not in the agent's allowed_vault_ids"
    })
  end

  # Same two shapes for a per-launch environment override (#783).
  def call(conn, {:error, :environment_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "environment_not_found"})
  end

  def call(conn, {:error, :environment_not_allowed}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "environment_not_allowed",
      message: "environment is not in the agent's allowed_environment_ids"
    })
  end

  # A per-launch permission override that would loosen the agent's policy
  # (#939). 422 naming the tool, because the caller asked for something
  # specific and a generic "invalid" would send them hunting. Refused rather
  # than clamped: `Permissions.effective/2` would clamp it to something safe
  # anyway, but silently handing back a tighter policy than the one requested
  # gives the caller no way to learn the ask was a mistake.
  def call(conn, {:error, {:permission_policy_widens, tool}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "permission_policy_widens",
      message:
        "permission_policy may only narrow the agent's own policy; " <>
          "#{tool} would be loosened"
    })
  end

  # `ask` is a real verdict with nowhere to ask until #940 builds the stream
  # event and the answer endpoint. Refused here rather than degrading to an
  # allow (unsafe) or hanging the turn on a prompt nobody will see (worse).
  def call(conn, {:error, {:permission_policy_unbuilt, verdict}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "permission_policy_unbuilt",
      message: "permission verdict #{verdict} is not supported yet"
    })
  end

  def call(conn, {:error, :permission_policy_invalid}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "permission_policy_invalid",
      message:
        "permission_policy must map a tool title or ACP kind to one of " <>
          Enum.join(Managoat.ACP.Permissions.verdicts(), ", ")
    })
  end

  # The runtime never sends `session/request_permission`, so the verdicts have
  # nothing to travel on. Refused rather than stored: an inert `auto_deny`
  # reads like protection everywhere it is displayed.
  def call(conn, {:error, {:permission_policy_unenforceable, runtime}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "permission_policy_unenforceable",
      message:
        "the #{runtime} runtime never asks before it runs a tool, so a policy " <>
          "stricter than auto_allow cannot be enforced on it"
    })
  end

  # A sandbox's per-conversation token naming a conversation it was not minted
  # for (#1637). 403 rather than 404: the holder knows the conversation exists
  # — it belongs to the account the token authenticates as — and what is being
  # refused is the credential, not the id. The same shape and the same reason
  # as `sprite_may_not_answer` on the permission route.
  #
  # Here rather than in a controller because three doors write labels: the
  # labels route, a team message, and a `channel_id` resume on conversation
  # create.
  def call(conn, {:error, :sprite_may_not_label_another_conversation}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "sprite_may_not_label_another_conversation",
      message: "a sandbox callback token may label only the conversation it was minted for"
    })
  end

  # An unknown or cross-tenant parent conversation. 404 rather than 403 so the
  # caller cannot use the response to probe which conversation ids exist.
  def call(conn, {:error, :parent_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "parent_conversation_not_found"})
  end

  # The agent pins a sandbox provider that is not usable on this instance
  # (its adapter is missing or its credentials were removed). 422 with the
  # provider named: an admin either configures the credentials or clears the
  # agent's override.
  def call(conn, {:error, {:sandbox_provider_disabled, provider}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "sandbox_provider_disabled",
      message:
        "sandbox provider #{provider} is not configured on this instance — " <>
          "set its credentials or clear the agent's sandbox_provider override"
    })
  end

  # The agent runs on the self-hosted runner provider (ADR 0022) and none of
  # the user's runners is connected right now. 409: nothing is misconfigured,
  # a machine just is not online — start `fountain runner` and retry.
  def call(conn, {:error, :no_runner_online}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "no_runner_online",
      message:
        "this agent runs on a self-hosted runner and none of yours is connected — " <>
          "start `fountain runner` on the machine and try again"
    })
  end

  # Prepaid balance exhausted (ADR 0031): the credit gate, returned from the
  # context so every provisioning path renders the same 402 rather than each
  # controller inventing one.
  def call(conn, {:error, :insufficient_credits}) do
    conn
    |> put_status(:payment_required)
    |> json(%{error: "insufficient_credits", upgrade_url: "/account/billing"})
  end

  # Operator suspension (#287). 403 rather than 402: there is nothing the
  # caller can buy their way out of.
  def call(conn, {:error, :account_suspended}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "account_suspended"})
  end

  # Per-tenant sandbox concurrency cap (ADR 0005). 429 rather than 402: this is
  # a rate/concurrency condition the caller can clear by terminating a
  # conversation, not a billing state they have to resolve by paying.
  def call(conn, {:error, {:sandbox_quota_exceeded, %{count: count, limit: limit}}}) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{
      error: "sandbox_quota_exceeded",
      message:
        "You have #{count} of #{limit} concurrent sandboxes in use. " <>
          "Terminate a conversation before starting another.",
      active_sandboxes: count,
      limit: limit
    })
  end

  # Every provider slot the deployment has is in use, whoever holds them
  # (ADR 0031). 503 with a retry hint: capacity, not the caller's quota and
  # not a billing state.
  def call(conn, {:error, :fleet_full}) do
    conn
    |> put_resp_header("retry-after", "60")
    |> put_status(:service_unavailable)
    |> json(%{
      error: "fleet_full",
      message: "Every sandbox slot is in use right now. Try again in a minute."
    })
  end

  # The deployment has spent its platform inference budget for the day
  # (#1388). 503 rather than 402, for the same reason as `:fleet_full`: this
  # is Fountain's own ceiling, not the caller's balance, and there is nothing
  # they can buy to clear it. Adding an inference credential does clear it —
  # a tenant's own key never touches this ceiling — so the message says so.
  def call(conn, {:error, :platform_inference_unavailable}) do
    conn
    |> put_resp_header("retry-after", "3600")
    |> put_status(:service_unavailable)
    |> json(%{
      error: "platform_inference_unavailable",
      message:
        "Fountain's shared inference budget for today is spent. Add your own " <>
          "inference credential to run now, or try again tomorrow.",
      credentials_url: "/account/inference-credentials"
    })
  end

  # The ConversationServer did not answer within the call timeout — almost
  # always a server still inside handle_continue(:provision), whose blocked
  # mailbox makes every call wait the full 30s and exit (#412). 503 with
  # Retry-After rather than 500: the conversation is coming up, the request
  # was fine, and the caller should try again shortly.
  def call(conn, {:error, :provisioning}) do
    conn
    |> put_resp_header("retry-after", "30")
    |> put_status(:service_unavailable)
    |> json(%{
      error: "provisioning",
      message: "the conversation is still provisioning; retry shortly"
    })
  end

  # A lifecycle fence can refuse an actor whose sandbox binding just changed.
  # The request is valid, but must retry after the actor catches up (#2049).
  def call(conn, {:error, :sandbox_unavailable}) do
    conn
    |> put_resp_header("retry-after", "30")
    |> put_status(:service_unavailable)
    |> json(%{error: "sandbox_unavailable"})
  end

  # A reapply that would need the machine built again (#1565). 409 rather than
  # 422: the selection is valid, it just cannot be applied to the computer
  # this conversation is already on. `field` says which one forced it, so a
  # client can tell "your agent runs a different runtime" from "your
  # environment installs different packages".
  def call(conn, {:error, {:rebuild_required, field}}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "rebuild_required",
      field: to_string(field),
      message:
        "this conversation's machine cannot be reconfigured in place because " <>
          Fountain.Conversations.Reapply.explain(field) <>
          "; start a new conversation, or build this one's machine again with " <>
          "DELETE /api/sandboxes/:id"
    })
  end

  # A conversation is reconfigured between turns, never during one. 409 and
  # not 503: waiting does not help by itself, the caller either waits for the
  # turn to end or interrupts it.
  def call(conn, {:error, :conversation_busy}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "conversation_busy",
      message: "the conversation has a running turn; wait for it to finish or interrupt it"
    })
  end

  # A turn refused because another conversation is running one on the same
  # sandbox and the runtime takes one at a time (ADR 0023 step 4). Not a
  # queue: the caller sends again when the other turn ends, or interrupts it.
  def call(conn, {:error, :sandbox_at_capacity}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "sandbox_at_capacity",
      message:
        "another conversation is running a turn on this sandbox and its runtime takes one " <>
          "at a time; wait for it to finish or interrupt it, then send again"
    })
  end

  # Attaching a conversation to an existing sandbox (ADR 0023 gate 3). 404
  # for an unknown or foreign id, indistinguishable on purpose; 409 for a
  # machine in a state nothing can attach to; 422 when the launch names a
  # different identity than the disk was built from.
  def call(conn, {:error, :sandbox_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "sandbox_not_found"})
  end

  def call(conn, {:error, {:sandbox_not_attachable, status}}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "sandbox_not_attachable",
      message:
        "the sandbox is #{status}; a conversation attaches only to a ready or suspended one",
      status: status
    })
  end

  def call(conn, {:error, :sandbox_identity_mismatch}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "sandbox_identity_mismatch",
      message:
        "the sandbox was built for a different agent, environment or vault; a conversation " <>
          "attaches only with the same three"
    })
  end

  # Reset (#1071): an ephemeral sandbox is a conversation's own and ends
  # with it; a terminated or failed one is already gone.
  def call(conn, {:error, {:sandbox_not_resettable, why}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "sandbox_not_resettable",
      message: sandbox_not_resettable_message(why),
      reason: why
    })
  end

  # A reset while a turn runs would cut it from under the conversation; the
  # caller waits for the turn to end, or interrupts it, then sends again.
  def call(conn, {:error, :sandbox_mid_turn}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "sandbox_mid_turn",
      message:
        "a conversation on this sandbox is running a turn; wait for it to finish or " <>
          "interrupt it, then send again"
    })
  end

  def call(conn, {:error, :sandbox_reset_pending}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "sandbox_reset_pending",
      message: "reset is pending confirmation; contact the operator before retrying"
    })
  end

  # A third reason a reset is refused, distinct from the two above (ADR 0046).
  # `:sandbox_mid_turn` is a turn that is running and ends by itself;
  # `:sandbox_reset_pending` is a delete this server asked for and never had
  # confirmed; this is a bounded turn whose remote command was never confirmed
  # stopped. Unlike the other two it clears on its own — the deadline
  # coordinator writes an obligation nothing can resolve off after a cutoff —
  # so the caller is told to wait rather than to fetch an operator.
  #
  # Without this clause the atom reached the unmapped-atom safety net: a 422
  # carrying no message at all, plus a warning log on every refusal.
  def call(conn, {:error, :execution_fenced}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "execution_fenced",
      message:
        "a bounded turn on this sandbox has remote work that was never confirmed " <>
          "stopped; this clears on its own once the obligation ages out, then send again"
    })
  end

  # Sandbox files (ADR 0039). A read never wakes a parked sandbox: 409 with
  # the status, and the caller decides whether a prompt is worth the wake.
  def call(conn, {:error, {:sandbox_not_ready, status}}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "sandbox_not_ready",
      message: "the sandbox is #{status}; files are read from a ready one only",
      status: status
    })
  end

  # A path the disk does not have. 404 like a missing sandbox: the caller
  # asked for something by name and it is not there.
  def call(conn, {:error, :path_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "path_not_found"})
  end

  def call(conn, {:error, :ref_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "ref_not_found", message: "no such commit, branch or tag"})
  end

  # The path is there but is the wrong kind of thing for the operation, or
  # git has no repository at it. The atom is the message.
  def call(conn, {:error, reason})
      when reason in [
             :not_a_directory,
             :is_a_directory,
             :path_unreadable,
             :not_a_repository,
             :invalid_ref,
             :invalid_path
           ] do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: to_string(reason), message: sandbox_files_message(reason)})
  end

  def call(conn, {:error, :path_outside_sandbox}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "path_outside_sandbox",
      message: "path must be under the sandbox home or the agent's working directory"
    })
  end

  # The command itself failed — git refusing a repository it does not own,
  # a filesystem error. Its output travels, redacted, because the exit code
  # alone sends the caller guessing.
  def call(conn, {:error, {:sandbox_command_failed, code, output}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "sandbox_command_failed", exit_code: code, output: output})
  end

  # The provider did not answer (transport, timeout, runner offline).
  # Nothing changed; retry.
  def call(conn, {:error, {:sandbox_unreachable, _reason}}) do
    conn
    |> put_resp_header("retry-after", "10")
    |> put_status(:service_unavailable)
    |> json(%{
      error: "sandbox_unreachable",
      message: "could not reach the sandbox; retry shortly"
    })
  end

  def call(conn, {:error, :invalid_sandbox_api_access}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_sandbox_api_access",
      message:
        "sandbox_api_access must be owner or none; none requires a fresh ephemeral sandbox, " <>
          "cannot name a sprite_name, and cannot change on resume"
    })
  end

  def call(conn, {:error, :invalid_sprite_name}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_sprite_name",
      message:
        "sprite_name is the suffix of an account-scoped sandbox name: 1 to 40 characters " <>
          "of letters, digits, - and _, starting with a letter or digit"
    })
  end

  def call(conn, {:error, :sprite_name_not_supported}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "sprite_name_not_supported",
      message:
        "this agent runs on a self-hosted runner, where the sandbox name carries the " <>
          "runner it is placed on; omit sprite_name and let the server mint it"
    })
  end

  def call(conn, {:error, :invalid_sandbox_mode}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_sandbox_mode",
      message:
        "sandbox_mode must be one of " <> Enum.join(Fountain.Agents.Agent.sandbox_modes(), ", ")
    })
  end

  def call(conn, {:error, :sandbox_runtime_mismatch}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "sandbox_runtime_mismatch",
      message:
        "the agent's runtime changed since this sandbox was built and the disk was shaped " <>
          "by the old one; start a new conversation instead"
    })
  end

  # The wake path could not reach the sandbox provider to check whether the
  # conversation's sandbox is still there (#799). Nothing was changed — the
  # row is deliberately left as it was rather than retired on a transport
  # error — so the caller should simply retry, same as :provisioning.
  def call(conn, {:error, :sprite_probe_failed}) do
    conn
    |> put_resp_header("retry-after", "10")
    |> put_status(:service_unavailable)
    |> json(%{
      error: "sandbox_probe_failed",
      message: "could not reach the sandbox provider to wake the conversation; retry shortly"
    })
  end

  # A runner-backed sandbox whose machine is not connected (#834). Same
  # shape as the probe failure — nothing was changed, retry — but named, so
  # a client can say "the machine is off" and the retry hint is honest: it
  # comes back when the runner reconnects, not in ten seconds.
  def call(conn, {:error, :runner_offline}) do
    conn
    |> put_resp_header("retry-after", "30")
    |> put_status(:service_unavailable)
    |> json(%{
      error: "runner_offline",
      message: "the teammate's machine is offline; it wakes when the runner reconnects"
    })
  end

  # Prompting a terminated conversation. 410 rather than 404: the id was
  # real, the resource is gone for good, and the caller should stop retrying.
  def call(conn, {:error, :gone}) do
    conn
    |> put_status(:gone)
    |> json(%{error: "conversation_terminated"})
  end

  # The conversation's agent was deleted out from under it; it cannot resume.
  def call(conn, {:error, :no_agent}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "no_agent", message: "the conversation's agent has been deleted"})
  end

  # Billing is off on this instance (#524). 404 rather than 402/403: the
  # endpoint does not exist here, and the UI likewise redirects away from the
  # billing page entirely.
  def call(conn, {:error, :billing_disabled}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "billing_disabled", billing: "disabled"})
  end

  # ── claimable principals (ADR 0044) ───────────────────────────────────────
  #
  # Named rather than left to the 422 safety net below, because an application
  # recovering from a lost response branches on exactly these: a claim it lost
  # the response to (409) reads differently from one it was too late for (410),
  # and both read differently from a bad token (403).

  def call(conn, {:error, :already_claimed}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "already_claimed", reason: "already_claimed"})
  end

  def call(conn, {:error, reason}) when reason in [:expired, :released] do
    conn
    |> put_status(:gone)
    |> json(%{error: to_string(reason), reason: to_string(reason)})
  end

  def call(conn, {:error, :invalid_claim_token}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "invalid_claim_token", reason: "invalid_claim_token"})
  end

  # The claiming account, not the grant: verified, not suspended, and able to
  # fund the work the claim moves onto its ledger.
  def call(conn, {:error, :ineligible}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "this account cannot claim a principal",
      reason: "ineligible_claimer"
    })
  end

  def call(conn, {:error, reason})
      when reason in [:too_many_outstanding_principals, :principal_rate_limited] do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: to_string(reason), reason: to_string(reason)})
  end

  def call(conn, {:error, {:invalid, message}}) when is_binary(message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: message, reason: "invalid_request"})
  end

  def call(conn, {:error, reason}) when is_binary(reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: reason})
  end

  # Terminal safety net (#332): an error shape nothing above recognises.
  # Contexts grow new refusal atoms faster than controllers learn them, and
  # every miss used to be a CaseClauseError 500. A domain refusal is the
  # caller's problem, so 422 with the atom beats a blank 500 — and anything
  # that genuinely is a server fault still shows up in the logs below.
  def call(conn, {:error, reason}) when is_atom(reason) do
    require Logger
    Logger.warning("fallback: unmapped error atom #{inspect(reason)} on #{conn.request_path}")

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: to_string(reason)})
  end

  defp sandbox_files_message(:not_a_directory), do: "path is not a directory"
  defp sandbox_files_message(:is_a_directory), do: "path is a directory; list it with /files"
  defp sandbox_files_message(:path_unreadable), do: "the sandbox user cannot read that path"
  defp sandbox_files_message(:not_a_repository), do: "no git repository contains that path"

  defp sandbox_files_message(:invalid_ref),
    do: "ref must name one commit, branch or tag; no flags and no ranges"

  defp sandbox_files_message(:invalid_path), do: "path must be valid UTF-8 without NUL bytes"

  defp sandbox_not_resettable_message("ephemeral"),
    do: "only a persistent sandbox resets; an ephemeral one ends with its conversation"

  defp sandbox_not_resettable_message(status),
    do: "the sandbox is #{status}; there is nothing left to reset"
end
