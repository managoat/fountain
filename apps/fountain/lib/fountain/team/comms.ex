defmodule Fountain.Team.Comms do
  @moduledoc """
  A teammate's email address and phone number, and the MCP tools it uses them
  through (flag `team_comms`).

  Fountain owns the AgentMail and AgentPhone keys. Giving a teammate a contact
  (`provision_contact/3`) creates an inbox and a number under those keys and
  records them in `Fountain.Team.Contact`; the teammate's sandbox never sees a
  key — it reaches email and SMS through MCP tools Fountain serves
  (`Fountain.Team.Comms.Mcp` behind `POST /api/mcp/team-comms/:conversation_id`),
  the same shape as the hosted Buzz tools (ADR 0020). The tools are injected
  into the teammate's conversation at each turn (`conversation_mcp_servers/2`),
  so a contact given while the teammate is mid-session shows up on its next
  turn.

  Two gates, both checked on every path: the **flag** (`flag_on?/1`, per user,
  from `Fountain.FeatureFlags`) and the **providers** (`configured?/0`, both
  keys present). `status/1` reports them separately so a surface can say
  which one is missing.

  Every function is tenant-scoped by `user_id`; provisioning and release are
  audited here, as the context rule requires. The audit trail records which
  channels a teammate got, never the address or number.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Fountain.{Audit, Conversations, FeatureFlags, Repo, Team}
  alias Fountain.Team.Comms.{AgentMail, AgentPhone}
  alias Fountain.Team.{CommsMessage, Contact}

  @flag :team_comms
  @mcp_name "fountain-comms"

  ## gates

  @doc "Whether the `team_comms` flag is on for this user (a `%User{}` or id)."
  def flag_on?(user), do: FeatureFlags.enabled?(@flag, user)

  @doc "Whether both provider keys are configured on this instance."
  def configured?, do: AgentMail.configured?() and AgentPhone.configured?()

  @doc "Whether the feature can be used by this user: flag on and providers configured."
  def available?(user), do: flag_on?(user) and configured?()

  @doc """
  The two gates, separately: `%{enabled: flag, configured: providers}`. A
  surface shows the feature when `enabled` and explains itself when
  `configured` is false.
  """
  def status(user), do: %{enabled: flag_on?(user), configured: configured?()}

  @doc "The MCP server name the teammate sees the tools under."
  def mcp_name, do: @mcp_name

  ## messages

  @doc """
  Record a message a provider charged for. **This is the row the credit
  ledger prices from** (#1143), so unlike `Billing.record_usage/5` it does
  not rescue: a write that fails must be visible, not logged and forgotten.

  Idempotent on the provider's own message id, so a send retried after a
  timeout that in fact reached the provider converges on one row rather than
  billing twice. That makes `{:ok, :duplicate}` a success from every caller's
  point of view.

  `attrs` (atom-keyed): `:user_id`, `:channel` (`email`/`sms`), `:direction`
  (`outbound`/`inbound`), `:provider_message_id`, and optionally
  `:contact_id`, `:agent_id` and `:metadata`.
  """
  @spec record_message(map()) ::
          {:ok, CommsMessage.t()} | {:ok, :duplicate} | {:error, Ecto.Changeset.t()}
  def record_message(attrs) when is_map(attrs) do
    attrs = Map.put_new(attrs, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))

    %CommsMessage{}
    |> CommsMessage.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, %CommsMessage{}} = ok ->
        ok

      # The unique index did its job. The provider already told us about this
      # message once, and it is already priced or waiting to be.
      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if Keyword.has_key?(errors, :user_id) or has_provider_id_error?(errors),
          do: {:ok, :duplicate},
          else: {:error, cs}
    end
  end

  defp has_provider_id_error?(errors) do
    Enum.any?(errors, fn
      {:provider_message_id, {_, opts}} -> opts[:constraint] == :unique
      {_, {_, opts}} -> opts[:constraint] == :unique
    end)
  end

  @doc """
  Messages this tenant was charged for in a period, for the finance view.
  Counts both directions: AgentPhone charges for a received SMS as well as a
  sent one.
  """
  @spec message_counts(binary(), DateTime.t(), DateTime.t()) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def message_counts(user_id, from, to) when is_binary(user_id) do
    from(m in CommsMessage,
      where: m.user_id == ^user_id and m.inserted_at >= ^from and m.inserted_at < ^to,
      group_by: m.channel,
      select: {m.channel, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  ## contacts

  @doc "The teammate's contact, or nil."
  def get_contact(user_id, agent_id) when is_binary(user_id) and is_binary(agent_id) do
    Repo.one(from(c in Contact, where: c.user_id == ^user_id and c.agent_id == ^agent_id))
  end

  @doc """
  How many of this tenant's teammates hold a contact. `TEAM_CONTACT_CEILING`
  bounds it.
  """
  @spec contact_count(binary()) :: non_neg_integer()
  def contact_count(user_id) when is_binary(user_id) do
    Repo.aggregate(from(c in Contact, where: c.user_id == ^user_id), :count, :id)
  end

  @doc """
  Contact counts for every tenant with at least one, in a single query — for
  the admin view, which shows the number on every row and must not run a count
  per row (the same contract as `Fountain.Quotas.active_sandbox_counts/0`).

  Returns `%{user_id => count}`; tenants with no contacts are absent.
  """
  @spec contact_counts() :: %{optional(binary()) => non_neg_integer()}
  def contact_counts do
    from(c in Contact, group_by: c.user_id, select: {c.user_id, count(c.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Contacts for many teammates at once, `%{agent_id => %Contact{}}`."
  def contacts_by_agent(user_id, agent_ids) when is_binary(user_id) and is_list(agent_ids) do
    from(c in Contact, where: c.user_id == ^user_id and c.agent_id in ^agent_ids)
    |> Repo.all()
    |> Map.new(&{&1.agent_id, &1})
  end

  @doc """
  Give the teammate for `agent_id` an email address and a phone number.

  `attrs` is what the user supplies: `"prompt_from_number"`, required — the
  one number whose texts to the teammate's new number arrive as prompts in
  its conversation (`Fountain.Team.Comms.Inbound`). It is validated before
  anything is bought.

  Creates the AgentMail inbox (display name = the teammate's name, username
  derived from it) and the AgentPhone number, then records both. All or
  nothing: if the number cannot be provisioned the inbox is deleted again and
  the error says which channel failed.

  Returns `{:ok, %Contact{}}`, or `{:error, reason}` with one of
  `:not_found` (not on the team), `:not_enabled` (flag off), `:not_configured`
  (a provider key is missing), `:already_provisioned`, an
  `%Ecto.Changeset{}` (a bad `prompt_from_number`), or
  `{:email | :phone, provider_error}`.
  """
  def provision_contact(user_id, agent_id, attrs \\ %{}, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) and is_map(attrs) do
    with :ok <- gate(user_id),
         %{name: name} = teammate <- Team.get_teammate(user_id, agent_id) || {:error, :not_found},
         :ok <- ensure_no_contact(user_id, agent_id),
         :ok <- check_contact_ceiling(user_id),
         {:ok, requested} <-
           Ecto.Changeset.apply_action(Contact.request_changeset(attrs), :insert),
         {:ok, inbox} <- create_inbox(name, teammate, opts),
         {:ok, phone_agent} <- create_phone_agent(name, teammate, inbox),
         {:ok, number} <- create_number(inbox, phone_agent, opts) do
      attrs = %{
        user_id: user_id,
        agent_id: agent_id,
        email_address: inbox["email"],
        email_inbox_id: inbox["inbox_id"],
        phone_number: number["phoneNumber"],
        phone_number_id: number["id"],
        phone_agent_id: phone_agent["id"],
        prompt_from_number: requested.prompt_from_number
      }

      case %Contact{} |> Contact.changeset(attrs) |> Repo.insert() do
        {:ok, contact} ->
          record("team.contact.provisioned", contact, opts, %{
            "channels" => channels(contact),
            "agent_name" => teammate.agent.name,
            "prompt_from_number" => not is_nil(contact.prompt_from_number)
          })

          Team.broadcast_changed(user_id)
          {:ok, contact}

        {:error, changeset} ->
          # A race with a second provision, most likely. Release what we
          # just created so nothing is left unrecorded upstream.
          release_upstream(inbox["inbox_id"], number["id"], phone_agent["id"])
          {:error, changeset}
      end
    end
  end

  @doc """
  Change what the user supplied for the teammate's contact — today the
  number whose texts become prompts (`"prompt_from_number"`). Nothing is
  bought or released. `{:ok, %Contact{}}`, `{:error, :not_found}` (no
  contact, or not on the team), or `{:error, %Ecto.Changeset{}}`.
  """
  def update_contact(user_id, agent_id, attrs, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) and is_map(attrs) do
    case get_contact(user_id, agent_id) do
      nil ->
        {:error, :not_found}

      %Contact{} = contact ->
        changeset = Contact.update_changeset(contact, attrs)

        case Repo.update(changeset) do
          {:ok, updated} ->
            record("team.contact.updated", updated, opts, %{
              "fields" => Audit.changed_fields(changeset)
            })

            Team.broadcast_changed(user_id)
            {:ok, updated}

          {:error, cs} ->
            {:error, cs}
        end
    end
  end

  @doc """
  Record the registered number's SMS opt-out (`true`: it texted STOP) or
  opt-in (`false`: START). Nothing is bought or released; while opted out
  its texts are not prompts. Audited as `team.contact.opted_out` /
  `team.contact.opted_in`.
  """
  def set_opt_out(%Contact{} = contact, opted_out?, opts \\ []) when is_boolean(opted_out?) do
    at = if opted_out?, do: DateTime.utc_now() |> DateTime.truncate(:second)

    case contact |> Ecto.Changeset.change(prompt_opted_out_at: at) |> Repo.update() do
      {:ok, updated} ->
        action = if opted_out?, do: "team.contact.opted_out", else: "team.contact.opted_in"
        record(action, updated, opts, %{})
        Team.broadcast_changed(updated.user_id)
        {:ok, updated}

      {:error, cs} ->
        {:error, cs}
    end
  end

  @doc """
  Take the teammate's email address and phone number away: the inbox and the
  number are deleted upstream and the contact row removed. A provider that
  no longer knows the resource (404) counts as released; any other provider
  failure keeps the row so the resource is not orphaned, and is returned.
  """
  def release_contact(user_id, agent_id, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) do
    case get_contact(user_id, agent_id) do
      nil ->
        {:error, :not_found}

      %Contact{} = contact ->
        with :ok <- release_email(contact),
             :ok <- release_phone(contact),
             {:ok, _} <- Repo.delete(contact) do
          record("team.contact.released", contact, opts, %{"channels" => channels(contact)})
          Team.broadcast_changed(user_id)
          :ok
        end
    end
  end

  ## MCP wiring

  @doc """
  The MCP server entry to inject into `session/new` for `conversation_id`,
  authenticated with the conversation's own sprite `token` — `[]` unless the
  conversation is a teammate's, the teammate has a contact, and the feature
  is available to its owner.

  Ownership: a system-level call from `ConversationServer`, which established
  ownership of the conversation at provision; the contact lookup that follows
  is scoped again by the conversation's `user_id`.
  """
  def conversation_mcp_servers(conversation_id, token)
      when is_binary(conversation_id) and is_binary(token) and token != "" do
    channel = Team.channel()

    with %Conversations.Conversation{channel_id: ^channel, user_id: uid, agent_id: aid}
         when is_binary(aid) <- fetch_conv(conversation_id),
         %Contact{} <- get_contact(uid, aid),
         true <- available?(uid) do
      [
        %{
          name: @mcp_name,
          type: "http",
          url: Fountain.PublicUrl.base() <> "/api/mcp/team-comms/" <> conversation_id,
          headers: [%{name: "Authorization", value: "Bearer " <> token}]
        }
      ]
    else
      _ -> []
    end
  end

  def conversation_mcp_servers(_conversation_id, _token), do: []

  @doc """
  The contact that owns the teammate number `phone_number` (E.164), across
  every tenant — or nil.

  `_unsafe_`: no `user_id` scopes this; the inbound SMS webhook
  (`Fountain.Team.Comms.Inbound`) has nothing but the number to go on. The
  caller has already verified the provider's signature, and the result only
  ever prompts the conversation that belongs to the contact's own user.
  """
  def _unsafe_get_contact_by_phone_number(phone_number) when is_binary(phone_number) do
    Repo.one(from(c in Contact, where: c.phone_number == ^phone_number, limit: 1))
  end

  @doc """
  Resolve a conversation the caller owns to the contact its MCP tools act
  for: `{:ok, %Contact{}}`, or `{:error, :not_team}` / `{:error, :no_contact}` /
  `{:error, :unavailable}`. The controller's whole authorization question.
  """
  def contact_for_conversation(%Conversations.Conversation{} = conv, user_id)
      when is_binary(user_id) do
    cond do
      conv.user_id != user_id or conv.channel_id != Team.channel() or is_nil(conv.agent_id) ->
        {:error, :not_team}

      not available?(user_id) ->
        {:error, :unavailable}

      true ->
        case get_contact(user_id, conv.agent_id) do
          nil -> {:error, :no_contact}
          contact -> {:ok, contact}
        end
    end
  end

  defp fetch_conv(conversation_id) do
    # ownership: system-level call from ConversationServer, which owns the
    # conversation; the contact fetched next is re-scoped by its user_id.
    Conversations._unsafe_get_conversation(conversation_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  ## provisioning

  defp gate(user_id) do
    cond do
      not flag_on?(user_id) -> {:error, :not_enabled}
      not configured?() -> {:error, :not_configured}
      true -> :ok
    end
  end

  # The ceiling on how many teammates may hold a contact at once
  # (`TEAM_CONTACT_CEILING`): the bound on how much Fountain can be made to
  # buy in one burst.
  defp check_contact_ceiling(user_id) do
    limit = Application.get_env(:fountain, :team_contact_ceiling, 10)
    count = contact_count(user_id)

    if count < limit do
      :ok
    else
      {:error, {:contact_limit_reached, %{count: count, limit: limit}}}
    end
  end

  defp ensure_no_contact(user_id, agent_id) do
    case get_contact(user_id, agent_id) do
      nil -> :ok
      %Contact{} -> {:error, :already_provisioned}
    end
  end

  defp create_inbox(name, teammate, opts) do
    attrs =
      %{
        "username" => username(name, opts),
        "display_name" => name,
        # AgentMail client ids allow only [A-Za-z0-9._~-]; no colon.
        "client_id" => "fountain-team." <> teammate.agent.id
      }
      |> put_present("domain", AgentMail.domain())

    case AgentMail.create_inbox(attrs) do
      {:ok, %{"inbox_id" => _, "email" => _} = inbox} -> {:ok, inbox}
      {:ok, other} -> {:error, {:email, {:unexpected_response, other}}}
      {:error, reason} -> {:error, {:email, reason}}
    end
  end

  # AgentPhone sends only from a number attached to one of its "agents", so
  # each teammate number gets a persona of its own. Webhook voice mode: a
  # call reaches our master webhook, which declines it — nothing of
  # AgentPhone's own LLM answers on a teammate's behalf.
  defp create_phone_agent(name, teammate, inbox) do
    attrs = %{
      "name" => name,
      "description" => "Fountain teammate #{teammate.agent.name} (#{teammate.agent.id})",
      "voiceMode" => "webhook",
      "enableMessaging" => true
    }

    case AgentPhone.create_agent(attrs) do
      {:ok, %{"id" => _} = agent} ->
        {:ok, agent}

      {:ok, other} ->
        release_upstream(inbox["inbox_id"], nil, nil)
        {:error, {:phone, {:unexpected_response, other}}}

      {:error, reason} ->
        release_upstream(inbox["inbox_id"], nil, nil)
        {:error, {:phone, reason}}
    end
  end

  defp create_number(inbox, phone_agent, opts) do
    attrs = %{"country" => Keyword.get(opts, :country, "US"), "agentId" => phone_agent["id"]}

    case AgentPhone.create_number(attrs) do
      {:ok, %{"id" => _, "phoneNumber" => _} = number} ->
        {:ok, number}

      {:ok, other} ->
        release_upstream(inbox["inbox_id"], nil, phone_agent["id"])
        {:error, {:phone, {:unexpected_response, other}}}

      {:error, reason} ->
        release_upstream(inbox["inbox_id"], nil, phone_agent["id"])
        {:error, {:phone, reason}}
    end
  end

  # The local part of the address: the teammate's name as a slug plus a short
  # random suffix, since usernames are unique per domain and teammates are
  # not. `opts[:username]` overrides for a deliberate address.
  defp username(name, opts) do
    case Keyword.get(opts, :username) do
      u when is_binary(u) and u != "" ->
        u

      _ ->
        slug =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")
          |> String.slice(0, 24)

        suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
        if slug == "", do: "teammate-" <> suffix, else: slug <> "-" <> suffix
    end
  end

  defp release_email(%Contact{} = c) do
    if Contact.email?(c),
      do: release_one(:email, AgentMail.delete_inbox(c.email_inbox_id)),
      else: :ok
  end

  defp release_phone(%Contact{} = c) do
    number =
      if Contact.phone?(c),
        do: release_one(:phone, AgentPhone.delete_number(c.phone_number_id)),
        else: :ok

    # The persona goes with the number; a missing one (older contacts, or
    # already gone) is nothing to report.
    with :ok <- number do
      if is_binary(c.phone_agent_id) and c.phone_agent_id != "",
        do: release_one(:phone, AgentPhone.delete_agent(c.phone_agent_id)),
        else: :ok
    end
  end

  defp release_one(_channel, {:ok, _}), do: :ok
  defp release_one(_channel, {:error, {:status, 404, _}}), do: :ok
  defp release_one(channel, {:error, reason}), do: {:error, {channel, reason}}

  # Best-effort cleanup after a partial provision; a failure here is logged,
  # not raised — the caller is already returning the real error.
  defp release_upstream(inbox_id, number_id, phone_agent_id) do
    if is_binary(inbox_id) do
      case AgentMail.delete_inbox(inbox_id) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "team comms: could not delete inbox #{inbox_id} after a failed provision: #{inspect(reason)}"
          )
      end
    end

    if is_binary(number_id) do
      case AgentPhone.delete_number(number_id) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "team comms: could not release number #{number_id} after a failed provision: #{inspect(reason)}"
          )
      end
    end

    if is_binary(phone_agent_id) do
      case AgentPhone.delete_agent(phone_agent_id) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "team comms: could not delete phone agent #{phone_agent_id} after a failed provision: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp channels(%Contact{} = c) do
    Enum.reject([Contact.email?(c) && "email", Contact.phone?(c) && "phone"], &(&1 == false))
  end

  defp put_present(map, _k, nil), do: map
  defp put_present(map, k, v), do: Map.put(map, k, v)

  defp record(action, %Contact{} = contact, opts, metadata) do
    Audit.record(%{
      user_id: contact.user_id,
      action: action,
      resource_type: "team_contact",
      resource_id: contact.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: Map.put(metadata, "agent_id", contact.agent_id)
    })
  end
end
