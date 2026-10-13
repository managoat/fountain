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

  # `Vaults.copy_vault/4` met a source secret it cannot write again (it no
  # longer decrypts, or no longer passes the write-time checks) and rolled the
  # whole copy back. The key names the row to fix; the value is never known here.
  def call(conn, {:error, {:secret_not_copyable, key}}) when is_binary(key) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "secret_not_copyable",
      message:
        "The source vault's secret #{key} could not be copied; no vault was created. " <>
          "Rewrite that secret in the source vault, then copy again."
    })
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

  # And again for a per-launch credential set (ADR 0053 decision 3). 404 for
  # a set the tenant does not own, so an id cannot be probed; 422 for one
  # they own that the agent does not allow, which is a different mistake and
  # a fixable one.
  def call(conn, {:error, :inference_credential_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "inference_credential_not_found"})
  end

  def call(conn, {:error, :inference_credential_not_allowed}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "inference_credential_not_allowed",
      message: "credential set is not in the agent's allowed_inference_credential_ids"
    })
  end

  def call(conn, {:error, :inference_source_changed}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "inference_source_changed",
      message:
        "the conversation's credential source was changed or deleted; start a new " <>
          "conversation with an available source, on a sandbox not bound to the old one " <>
          "(sandbox_mode ephemeral, or reset the persistent home)"
    })
  end

  def call(conn, {:error, :chatgpt_reconnect_required}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "chatgpt_reconnect_required",
      message:
        "the ChatGPT subscription this conversation runs on was disconnected, refused by " <>
          "OpenAI, or linked to another account; link it again under Inference credentials " <>
          "(or ask an admin, for the deployment's), then send the prompt again"
    })
  end

  def call(conn, {:error, :inference_credential_unusable}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "inference_credential_unusable",
      message:
        "the selected credential set has no credential this runtime can use; add one or select another set"
    })
  end

  def call(conn, {:error, :inference_credential_conflict}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "inference_credential_conflict",
      message:
        "multiple authentication inputs compete for this runtime; keep one credential source before launching"
    })
  end

  def call(conn, {:error, :codex_inference_conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "codex_inference_conflict",
      message:
        "this sandbox is reserved for a different Codex credential source or revision; a " <>
          "persistent home keeps the source it started on. Use the same source or a fresh " <>
          "sandbox: launch with sandbox_mode ephemeral, or reset the home with " <>
          "DELETE /api/sandboxes/{id}"
    })
  end

  # `is_default: false` on a set. There is no such state: exactly one set per
  # account is the default and nothing allows zero.
  def call(conn, {:error, :cannot_undefault}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "cannot_undefault",
      message: "a set stops being the default when another becomes it; promote another instead"
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

  # A conversation's model override (ADR 0061) that the runtime cannot run,
  # checked as an agent's model is. The message says which check failed.
  def call(conn, {:error, {:model_invalid, message}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "model_invalid", message: "model: #{message}"})
  end

  # ADR 0062: only the shape of a session config is checked here; the adapter
  # decides which ids and values exist.
  def call(conn, {:error, {:session_config_invalid, message}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "session_config_invalid", message: "session_config #{message}"})
  end

  # A channel request naming session config options the conversation it
  # resumes does not request (ADR 0062), refused like a differing model.
  def call(conn, {:error, {:conversation_session_config_differs, current}}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "conversation_session_config_differs",
      message:
        "the channel's conversation requests session_config #{Jason.encode!(current)}; " <>
          "change it with POST /api/conversations/{id}/reapply, send session_config on " <>
          "the prompt for one turn, or pass fresh: true for a new conversation"
    })
  end

  # A channel request naming a model the conversation it resumes does not run
  # (ADR 0061 decision 5). Refused before the prompt goes out: resuming on the
  # old model would take the field and ignore it.
  def call(conn, {:error, {:conversation_model_differs, current}}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "conversation_model_differs",
      message:
        "the channel's conversation runs #{current || "its agent's model"}; change it " <>
          "with POST /api/conversations/{id}/reapply, or pass fresh: true for a new " <>
          "conversation on the requested model",
      model: current
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

  # Operator suspension (#287). 403: the operator decided it, and nothing the
  # caller sends changes that.
  def call(conn, {:error, :account_suspended}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "account_suspended"})
  end

  # Every provider slot the deployment has is in use, whoever holds them
  # (ADR 0042). 503 with a retry hint: capacity the caller waits for.
  def call(conn, {:error, :fleet_full}) do
    conn
    |> put_resp_header("retry-after", "60")
    |> put_status(:service_unavailable)
    |> json(%{
      error: "fleet_full",
      message: "Every sandbox slot is in use right now. Try again in a minute."
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

  # Three sources now, all retryable and all meaning "Fountain is doing
  # something else to this machine right now". A lifecycle fence refusing an
  # actor whose sandbox binding just changed (#2049); the machine's owner
  # refusing a teardown while another operation holds its lease (ADR 0058 stage
  # 5); and — since stage 6a, the commonest of the three — a wake or an attach
  # onto a machine whose owner holds a live lease.
  #
  # It carried no `message` while there were two, on the grounds that they did
  # not mean the same thing to a caller. The third made that the wrong trade
  # (round 1, surfaces review): it is the one most callers meet, and the CLI
  # prints `http 503: sandbox_unavailable` with nothing else when the body has
  # no `message`.
  #
  # **The sentence names no cause**, and that is the point rather than
  # vagueness (round 2, surfaces review). The first draft said Fountain was
  # "finishing another operation", which is true of the stage 5 and 6a sources
  # and false of #2049's: there nothing is in flight, the caller's conversation
  # is simply no longer attached to the machine it named. What all three share
  # is the outcome — this machine will not take this request now, and later it
  # may. An operation with something *more* precise to say still renders its
  # own: `SandboxController.delete/2` does, because there the fence has already
  # committed and "send it again" is the wrong advice.
  def call(conn, {:error, :sandbox_unavailable}) do
    conn
    |> put_resp_header("retry-after", "30")
    |> put_status(:service_unavailable)
    |> json(%{
      error: "sandbox_unavailable",
      message: "this sandbox cannot take that request right now; send it again shortly"
    })
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
      field: if(field == :missing_build_fingerprint, do: "environment", else: to_string(field)),
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
        "the sandbox was built from a different environment or vault, or for another agent " <>
          "this conversation's agent cannot join; a conversation attaches with the same " <>
          "environment and vault, and another agent only to a persistent sandbox where " <>
          "it makes a claude and codex pair (a codex agent on a claude agent's home, or " <>
          "the other way round; never two agents of one runtime, nor any other runtime)"
    })
  end

  # A guest attach (a conversation of another agent onto a home by
  # `sandbox_id`) made with a credential below full scope (#2525): a sandbox's
  # own `sprite` token. 403 with `RequireFullScope`'s shape,
  # `reason: "insufficient_scope"` and `required_scope: "full"`, because the
  # refusal is that plug's rule applied inside the attach door, and only ever
  # given for an attach that passed the pairing checks.
  def call(conn, {:error, :guest_attach_requires_full_scope}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "guest_attach_requires_full_scope",
      reason: "insufficient_scope",
      required_scope: "full",
      message:
        "attaching a conversation of another agent to this sandbox needs a full-scope " <>
          "API key; a sandbox's own token may attach only conversations of the agent the " <>
          "sandbox already runs"
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

  # The word is `sandbox_reset_pending` for history, but the state it names is
  # either fence on the row — a reset the provider has not confirmed, or a
  # teardown. Since ADR 0058 stage 8b the second is what most callers meet:
  # the point at which a machine stops taking attaches is the last detach's
  # commit, so every attach after a conversation is terminated arrives here.
  # The message therefore says "torn down or reset" rather than promising the
  # caller a reset that is not happening (round 1, surfaces review).
  def call(conn, {:error, :sandbox_reset_pending}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "sandbox_reset_pending",
      message:
        "this computer is being torn down or reset and the provider has not confirmed it " <>
          "yet; Fountain retries automatically, or an administrator can retry from the " <>
          "admin sandbox list"
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
          "by the old one; start a new conversation without sandbox_id for the new runtime, " <>
          "or reset this agent's computer to rebuild it"
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

  # The provider was asked to bring a parked machine back and would not
  # (ADR 0058 stage 7a; the word is #799's). Same shape as the probe failure
  # and for the same reason: nothing was written, the row is still `suspended`
  # and the disk — the agent's memory — is intact, so the caller should retry.
  #
  # Until 7a this atom had no clause here at all and fell to the terminal
  # safety net's 422, which told every SDK that a transient provider refusal
  # was the caller's fault and not worth retrying. It is a 503 with a
  # `Retry-After`, which is `NotReadyError` in the TypeScript SDK.
  def call(conn, {:error, :sandbox_resume_failed}) do
    conn
    |> put_resp_header("retry-after", "10")
    |> put_status(:service_unavailable)
    |> json(%{
      error: "sandbox_resume_failed",
      message: "the sandbox provider would not wake the conversation's machine; retry shortly"
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
