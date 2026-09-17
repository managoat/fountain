defmodule Fountain.Team do
  @moduledoc """
  The team: the agents a user talks to as people, one persistent
  conversation each.

  A teammate is not a new kind of thing. It is a conversation — one per
  agent — bound to the reserved channel `"fountain:team"`, exactly the way
  a Buzz channel binds a conversation through `channel_id` (#774). Adding an
  agent to the team opens that conversation, which provisions the agent its
  own sandbox: its computer. Messaging the teammate is `send_prompt` on that
  conversation, and `ConversationServer.send_prompt/4` already wakes a
  suspended or reaped sandbox, so the teammate is always reachable. Only a
  `terminated`/`failed` conversation is past resuming; the next message opens
  a fresh one under the same binding — the agent gets a new computer, and the
  team list keeps showing the same teammate.

  A teammate can also start over without losing its computer:
  `open_fresh_conversation/3` retires the current conversation (it stays in
  the teammate's history, past resuming) and opens a new one on the same
  sandbox — the next message runs a fresh runtime session on the same disk,
  the files and installed tools still there.

  Removing a teammate terminates the live conversation and clears the binding
  on every conversation this agent had under it, so the rows stay in the
  user's history (`/conversations`) but leave the team. Its schedules
  (`Fountain.Team.Schedules` — a cron that runs the teammate with a prompt)
  are deleted with it.

  A teammate can be given a name of its own, an environment and a vault when
  it is added. None of these is a new column: the name is the conversation's
  `title`, the other two are the per-launch `environment_id` override (#783)
  and `vault_id` every conversation already carries. They belong to the
  teammate, not the computer, so a fresh conversation opened when the old one
  is past resuming inherits all three.

  Every function is tenant-scoped by `user_id`; the `_unsafe_` reads inside
  are legitimate because they follow the scoped fetch in the same function.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Fountain.{Agents, Audit, Conversations, Repo}
  alias Fountain.Conversations.{Conversation, ConversationServer, Launch, Sandbox, Termination}
  alias Fountain.Machines.Binding
  alias Fountain.Machines.Machine
  alias Fountain.Conversations.Turn

  @channel "fountain:team"

  @doc "The reserved `channel_id` that marks a conversation as a teammate's."
  def channel, do: @channel

  @doc """
  Subscribe the caller to `{:team_changed, user_id}`, broadcast whenever the
  roster's membership changes — a teammate added or removed, or a fresh
  conversation opened for one — so a client following the team knows to
  re-list and to follow the new conversation. Per-conversation events keep
  riding `conv:<id>`.
  """
  def subscribe(user_id) when is_binary(user_id),
    do: Phoenix.PubSub.subscribe(Fountain.PubSub, topic(user_id))

  defp topic(user_id), do: "team:#{user_id}"

  @doc """
  Broadcast `{:team_changed, user_id}` on the team topic — the roster needs
  re-listing.
  """
  def broadcast_changed(user_id),
    do: Phoenix.PubSub.broadcast(Fountain.PubSub, topic(user_id), {:team_changed, user_id})

  @doc """
  Broadcast `{:team_schedules_changed, user_id}` on the team topic — a
  schedule was created, updated, deleted or fired (#825). Same subscribers
  as `subscribe/1`; the API stream turns it into a `schedule` event so a
  client re-lists its routines. Called by `Fountain.Team.Schedules`.
  """
  def broadcast_schedules_changed(user_id) when is_binary(user_id),
    do:
      Phoenix.PubSub.broadcast(
        Fountain.PubSub,
        topic(user_id),
        {:team_schedules_changed, user_id}
      )

  @doc """
  The MCP server a team conversation's turns carry (#851): `fountain-team`,
  served by Fountain at `/api/mcp/team/:conversation_id`, authenticated with
  the sandbox's own token. Only conversations on the team channel get it —
  the tools are "the team", and a conversation outside it has no team.
  """
  def conversation_mcp_servers(conversation_id, token)
      when is_binary(conversation_id) and is_binary(token) and token != "" do
    case fetch_conv(conversation_id) do
      %Conversation{channel_id: @channel} ->
        [
          %{
            name: Fountain.Team.Mcp.mcp_name(),
            type: "http",
            url: Fountain.PublicUrl.base() <> "/api/mcp/team/" <> conversation_id,
            headers: [%{name: "Authorization", value: "Bearer " <> token}]
          }
        ]

      _ ->
        []
    end
  end

  def conversation_mcp_servers(_conversation_id, _token), do: []

  # ownership: system-level call from ConversationServer, which owns the
  # conversation; the tools re-scope every read/write by the token's user.
  defp fetch_conv(conversation_id) do
    Conversations._unsafe_get_conversation(conversation_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  One entry per agent on the team, most recently active first.

  Each entry is `%{agent: %Agent{}, conversation: %Conversation{}, last_turn:
  %Turn{} | nil, name: String.t(), usage_total: %{input: n, output: n}}` — the conversation is the newest live one
  for that agent, or, when none is live, the newest terminated/failed one (so
  the last transcript still shows). The conversation carries `turn_count` and
  `last_active_at`; `last_turn` is what the list previews; `name` is what the
  teammate is called — the conversation's title when it was given one at add
  time, else the agent's name.
  """
  def list_teammates(user_id) when is_binary(user_id) do
    groups =
      user_id
      |> Conversations.list_channel_conversations(@channel)
      |> Enum.reject(&is_nil(&1.agent))
      |> Enum.group_by(& &1.agent_id)
      |> Enum.map(fn {_agent_id, convs} -> {pick_current(convs), usage_total(convs)} end)

    last_turns = last_turns_by_conversation(Enum.map(groups, fn {conv, _} -> conv.id end))

    groups
    |> Enum.map(fn {conv, usage_total} ->
      %{
        agent: conv.agent,
        conversation: conv,
        last_turn: Map.get(last_turns, conv.id),
        name: teammate_name(conv),
        usage_total: usage_total
      }
    end)
    |> Enum.sort_by(& &1.conversation.last_active_at, {:desc, DateTime})
  end

  # The teammate's tokens across every conversation it has had under the
  # channel (#827) — a replaced conversation's turns still count for the
  # teammate, even though the roster shows only the current one.
  defp usage_total(convs) do
    Enum.reduce(convs, %{input: 0, output: 0}, fn c, acc ->
      %{
        input: acc.input + (c.usage_input_tokens || 0),
        output: acc.output + (c.usage_output_tokens || 0)
      }
    end)
  end

  @doc "What the teammate is called: the conversation's title, else the agent's name."
  def teammate_name(%Conversation{title: title}) when is_binary(title) and title != "", do: title
  def teammate_name(%Conversation{agent: %{name: name}}), do: name

  # The newest turn of each conversation in one query (DISTINCT ON). The ids
  # come from the tenant-scoped listing above, which is what scopes this.
  defp last_turns_by_conversation([]), do: %{}

  defp last_turns_by_conversation(conv_ids) do
    from(t in Turn,
      where: t.conversation_id in ^conv_ids,
      distinct: t.conversation_id,
      order_by: [asc: t.conversation_id, desc: t.turn_number]
    )
    |> Repo.all()
    |> Map.new(&{&1.conversation_id, &1})
  end

  @doc "The teammate for `agent_id`, or nil when that agent is not on the team."
  def get_teammate(user_id, agent_id) when is_binary(user_id) and is_binary(agent_id) do
    user_id
    |> list_teammates()
    |> Enum.find(&(&1.agent.id == agent_id))
  end

  # `list_channel_conversations/2` returns newest-first, so the first live one
  # (or, failing that, the first at all) is the current binding.
  defp pick_current(convs) do
    Enum.find(convs, &live?/1) || hd(convs)
  end

  @doc "Whether the teammate's current conversation can still take a message."
  def live?(%Conversation{status: status}), do: status not in ["terminated", "failed"]

  @doc """
  Add `agent_id` to the team: open its conversation (and so its sandbox).

  `attrs` is optional and string-keyed: `"name"` (what the teammate is
  called; blank means the agent's name), `"environment_id"` (provision from
  this environment instead of the agent's own) and `"vault_id"` (layer this
  vault's secrets on top). The two ids go through the same checks as any
  launch — owned by the user, and on the agent's allowlist when it has one —
  so the errors are `start_conversation/2`'s: `:environment_not_found`,
  `:environment_not_allowed`, `:vault_not_found`, `:vault_not_allowed`.

  Idempotent — an agent already on the team gets its existing live
  conversation back, `attrs` ignored, and nothing is recorded, since nothing
  changed. Returns `{:ok, conv}` or the `start_conversation/2` error
  (`:not_found`, `:insufficient_credits`, `{:sandbox_quota_exceeded, _}`,
  ...). `opts` is audit attribution, plus an optional `:source` (`"ui"` or
  `"api"`, default `"ui"`) recorded on the conversation.
  """
  def add_teammate(user_id, agent_id, attrs \\ %{}, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) and is_map(attrs) and is_list(opts) do
    case get_teammate(user_id, agent_id) do
      %{conversation: conv} ->
        if live?(conv), do: {:ok, conv}, else: open_teammate(user_id, agent_id, attrs, opts)

      nil ->
        open_teammate(user_id, agent_id, attrs, opts)
    end
  end

  defp open_teammate(user_id, agent_id, attrs, opts) do
    attrs = %{
      "agent_id" => agent_id,
      "user_id" => user_id,
      "channel_id" => @channel,
      "source" => Keyword.get(opts, :source, "ui"),
      "title" => blank_to_nil(attrs["name"]),
      "environment_id" => blank_to_nil(attrs["environment_id"]),
      "vault_id" => blank_to_nil(attrs["vault_id"])
    }

    case Launch.start_or_resume_conversation(attrs, opts) do
      {:ok, conv, :created} ->
        record(user_id, "team.member.added", conv, opts)
        broadcast_changed(user_id)
        {:ok, conv}

      {:ok, conv, :resumed} ->
        {:ok, conv}

      {:error, _} = err ->
        err
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  The environments and vaults a teammate built on `agent` may be given at add
  time: `%{environments: [%Environment{}], vaults: [%Vault{}]}`.

  Both lists are the user's own, narrowed by the agent's policies the way
  `start_conversation/2` will enforce them. The agent's own environment is
  always offered — naming it is not an override — and is what a blank pick
  means.
  """
  def addable_options(user_id, %Agents.Agent{} = agent) when is_binary(user_id) do
    %{
      environments:
        user_id
        |> Fountain.Environments.list_environments()
        |> Enum.filter(&Agents.Agent.environment_allowed?(agent, &1.id)),
      vaults:
        user_id
        |> Fountain.Vaults.list_vaults()
        |> Enum.filter(&Agents.Agent.vault_allowed?(agent, &1.id))
    }
  end

  @doc """
  Remove `agent_id` from the team.

  Terminates the live conversation (its sandbox goes with it) and unbinds
  every conversation this agent had under the team channel — the rows stay in
  the user's history, they just stop being the teammate. `{:error, :not_found}`
  when the agent is not on the team; nothing is recorded then.
  """
  def remove_teammate(user_id, agent_id, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) do
    case get_teammate(user_id, agent_id) do
      nil ->
        {:error, :not_found}

      %{conversation: conv} ->
        # `audit: false`: the removal below is the thing the user asked for;
        # the terminate is how it is carried out, not a second action.
        if live?(conv), do: Termination.terminate_conversation(conv.id, audit: false)

        {_n, _} =
          Repo.update_all(
            from(c in Conversation,
              where:
                c.user_id == ^user_id and c.agent_id == ^agent_id and c.channel_id == ^@channel
            ),
            set: [channel_id: nil]
          )

        # The teammate's schedules go with it: they name this teammate, and a
        # schedule that fires "not on the team" every morning is a defect,
        # not a record. Covered by the membership event, not per row.
        # ownership: the scoped get_teammate above found this agent for user_id;
        # the delete is bounded by the same user_id + agent_id.
        _ = Fountain.Team.Schedules._unsafe_delete_for_teammate(user_id, agent_id)

        record(user_id, "team.member.removed", conv, opts)
        broadcast_changed(user_id)
        :ok
    end
  end

  @doc """
  Send `text` (and optional decoded `images`) to the teammate for `agent_id`.

  Goes through `ConversationServer.send_prompt/4`, which wakes a parked or
  reaped sandbox itself. When the current conversation is past resuming
  (`terminated`/`failed`, or the server answers `:gone`), a fresh conversation
  is opened under the same binding with this as its first prompt — the agent
  gets a new computer and the message is not lost.

  Returns `{:ok, conv}` with the conversation the message went to, or the
  `send_prompt`/`start_conversation` error unchanged (`:busy`,
  `:provisioning`, `:insufficient_credits`, ...).
  """
  def send_message(user_id, agent_id, text, images \\ [], opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) and is_binary(text) do
    case get_teammate(user_id, agent_id) do
      nil ->
        {:error, :not_found}

      %{conversation: conv} ->
        if live?(conv) do
          # Labels before the prompt (#1637): merged first, so a label the
          # limits refuse means nothing happened at all rather than "the
          # message went and the labels did not".
          with {:ok, conv} <- label(conv, opts) do
            case ConversationServer.send_prompt(conv.id, text, images, opts) do
              :ok -> {:ok, Conversations.get_conversation(conv.id, user_id) || conv}
              {:error, :gone} -> start_fresh(user_id, agent_id, conv, text, images, opts)
              {:error, _} = err -> err
            end
          end
        else
          start_fresh(user_id, agent_id, conv, text, images, opts)
        end
    end
  end

  # `opts[:labels]` goes onto the conversation the message lands on (#1637).
  # On the fresh path they ride in the create attrs instead, so a conversation
  # that never existed is not labelled twice.
  #
  # Through `Conversations.set_conversation_labels/4`, not the writer beneath
  # it: this route accepts a sandbox's own `sprite` token, and the teammate's
  # conversation is somebody else's conversation as far as that token is
  # concerned. The door is where the rule lives, so the refusal is the same
  # one `PATCH .../labels` gives.
  defp label(%Conversation{} = conv, opts) do
    case Keyword.get(opts, :labels) do
      nil -> {:ok, conv}
      labels -> Conversations.set_conversation_labels(conv.id, conv.user_id, labels, opts)
    end
  end

  # A new conversation under the team binding, seeded with the message. Not
  # `start_or_resume`: we are here precisely because the bound conversation
  # cannot be resumed, and `find_channel_conversation` would agree — but
  # saying so directly keeps the intent readable. The name, environment and
  # vault are the teammate's, not the dead computer's, so they carry over.
  defp start_fresh(user_id, agent_id, %Conversation{} = prev, text, images, opts) do
    result =
      Launch.start_conversation(
        %{
          "agent_id" => agent_id,
          "user_id" => user_id,
          "channel_id" => @channel,
          "source" => Keyword.get(opts, :source, "ui"),
          "prompt" => text,
          "images" => images,
          "title" => prev.title,
          "environment_id" => prev.environment_id,
          "vault_id" => prev.vault_id,
          "labels" => Keyword.get(opts, :labels) || %{}
        },
        opts
      )

    with {:ok, _} <- result, do: broadcast_changed(user_id)
    result
  end

  @doc """
  Rename the teammate for `agent_id` (#831): `name` becomes its current
  conversation's title — what the roster shows and what `start_fresh/6`
  carries onto the next conversation when this one is past resuming. Blank
  or nil clears it, so the teammate reads as its agent's name again.
  `{:error, :not_found}` when the agent is not on the team; a changeset
  error when the name is too long. Audited as `team.renamed` (the field,
  never the value); broadcasts the roster change.
  """
  def rename_teammate(user_id, agent_id, name, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) do
    case get_teammate(user_id, agent_id) do
      nil ->
        {:error, :not_found}

      %{conversation: conv} ->
        title = blank_to_nil(name)

        # Ownership: `conv` came from the tenant-scoped get_teammate above.
        case Conversations.update_conversation(conv, %{"title" => title}) do
          {:ok, updated} ->
            if updated.title != conv.title do
              record(user_id, "team.renamed", updated, opts, %{
                "fields" => ["name"],
                "cleared" => is_nil(title)
              })

              broadcast_changed(user_id)
            end

            {:ok, updated}

          {:error, _} = err ->
            err
        end
    end
  end

  # What a teammate is, in one map: the public attribute name, and the
  # conversation column it lands on.
  @bindings [{"name", :title}, {"environment_id", :environment_id}, {"vault_id", :vault_id}]

  @doc """
  Reconcile the teammate for `agent_id` against `attrs` (#1636).

  `attrs` is string-keyed and takes the same three keys `add_teammate/4`
  does: `"name"`, `"environment_id"` and `"vault_id"`. A key that is absent
  leaves that binding alone; a blank value clears it, which for the two ids
  means the agent's own environment and no vault. Bulk apply
  (`Fountain.Manifest`) always sends all three, so a Teammate document that
  names no environment clears the override rather than keeping the last one.
  Both ids go through the agent's allowlists, as an add does, so a teammate
  cannot be bound to an environment or vault its agent refuses.

  The three live on the teammate's current conversation, where they already
  are, so `open_fresh_conversation/3` and `start_fresh/6` build the next
  computer from them.

  A home is keyed on `(user, agent, environment, vault)`, so moving either id
  moves the teammate's computer out from under it: the next launch looks
  under the new key, finds nothing and provisions a fresh machine, while the
  old one stays `ready` holding a concurrency slot and a disk carrying the
  old environment's secrets (#1084). This is the hazard
  `Fountain.Agents.update_agent/3` refuses, and it is refused the same way —
  `{:error, :sandbox_mid_turn}` while a turn is running on that machine, and
  the orphan retired through `reset_sandbox/2` once the new binding is the
  committed one. An ephemeral computer is a conversation's own and is left
  alone.

  A rebinding onto an identity the agent already has a live home for is
  refused with `{:error, :destination_home_occupied}`, and nothing is written.
  There is one home per `(user, agent, environment, vault)`, and the wake path
  builds a home rather than attaching to one, so writing the binding anyway
  would leave a teammate that cannot wake at all. Merging the teammate onto
  the machine that is already there is deliberately not done here; it needs
  the readiness, runtime and quota checks `attach_conversation/3` makes.

  Returns `{:ok, conv, :updated}`, or `{:ok, conv, :unchanged}` when `attrs`
  matched the teammate already. `{:error, :not_found}` when the agent is not
  on the team, `{:error, :environment_not_allowed}` / `{:error,
  :vault_not_allowed}` when an id is not the caller's own or not on the
  agent's allowlist, `{:error, :sandbox_mid_turn}` and `{:error,
  :destination_home_occupied}` as above. Audited as `team.updated` with the
  changed field names, and nothing is recorded when nothing changed.

  The second argument is the agent's id, or the teammate map a caller already
  holds from `get_teammate/2` or `list_teammates/1` for the same `user_id` —
  listing the roster is several queries, and bulk apply has just done it.
  """
  def update_teammate(user_id, agent_or_teammate, attrs, opts \\ [])

  def update_teammate(user_id, agent_id, attrs, opts)
      when is_binary(user_id) and is_binary(agent_id) and is_map(attrs) do
    case get_teammate(user_id, agent_id) do
      nil -> {:error, :not_found}
      teammate -> update_teammate(user_id, teammate, attrs, opts)
    end
  end

  def update_teammate(user_id, %{agent: agent, conversation: conv}, attrs, opts)
      when is_binary(user_id) and is_map(attrs) and is_list(opts) do
    changes = binding_changes(attrs, conv)
    identity = effective_identity(conv, agent, changes)
    # Ownership: `conv` and `agent` came from the scoped get_teammate.
    orphans = homes_orphaned_by_rebinding(conv, identity)

    with :ok <- bindings_allowed(user_id, agent, changes),
         :ok <- destination_free(user_id, agent, conv, identity),
         :ok <- no_home_mid_turn(orphans) do
      write_bindings(user_id, conv, changes, orphans, opts)
    end
  end

  # Only what actually moves: a value the conversation already holds is not a
  # change, which is what lets a re-apply say it wrote nothing.
  defp binding_changes(attrs, %Conversation{} = conv) do
    @bindings
    |> Enum.filter(fn {key, _field} -> Map.has_key?(attrs, key) end)
    |> Enum.map(fn {key, field} -> {field, blank_to_nil(attrs[key])} end)
    |> Enum.reject(fn {field, value} -> Map.get(conv, field) == value end)
    |> Map.new()
  end

  # The pair a machine for this teammate would be built from once `changes`
  # land. A cleared override falls back to the agent's own environment, which
  # is what a sandbox row carries and what `_unsafe_find_home/4` looks up by.
  defp effective_identity(%Conversation{} = conv, %Agents.Agent{} = agent, changes) do
    {Map.get(changes, :environment_id, conv.environment_id) || agent.environment_id,
     Map.get(changes, :vault_id, conv.vault_id)}
  end

  # The teammate's computer, when the new binding no longer names it. Nothing
  # moves for a name-only change, and nothing is orphaned by a rebinding that
  # keeps the same pair.
  defp homes_orphaned_by_rebinding(%Conversation{sandbox: %Sandbox{} = home}, identity) do
    if home.mode == "persistent" and home.status not in ["terminated", "failed"] and
         {home.environment_id, home.vault_id} != identity do
      [home]
    else
      []
    end
  end

  defp homes_orphaned_by_rebinding(_conv, _identity), do: []

  # One live home per identity, enforced by `sandboxes_home_identity_index`.
  # If the agent already has a home for the pair this rebinding moves to, the
  # teammate would be written onto an identity it cannot wake into: the wake
  # path provisions a *new* home rather than attaching to an existing one, and
  # the index rejects the insert, so the teammate is stranded and re-applying
  # the same manifest reports `unchanged` and does not recover it.
  #
  # Refused rather than merged. Attaching to the machine that is already there
  # is the other half of this and needs its own change — readiness, the
  # runtime the disk was shaped for, and the quota a second tenant of that
  # machine implies are all checks `attach_conversation/3` makes and this
  # function does not. Refusing cannot strand anybody; attaching wrongly can.
  #
  # Ownership: `agent` and `conv` came from the scoped get_teammate, and a
  # home carries the same `user_id` as the identity it is keyed on.
  defp destination_free(user_id, %Agents.Agent{} = agent, %Conversation{} = conv, identity) do
    {env_id, vault_id} = identity

    if identity == effective_identity(conv, agent, %{}) do
      :ok
    else
      case Conversations._unsafe_find_home(user_id, agent.id, env_id, vault_id) do
        nil -> :ok
        %Sandbox{id: id} when id == conv.sandbox_id -> :ok
        %Sandbox{} -> {:error, :destination_home_occupied}
      end
    end
  end

  # Asked before anything is written, so a mid-turn refusal costs the caller
  # nothing. Ownership: the homes came from the scoped get_teammate's
  # conversation.
  defp no_home_mid_turn(homes) do
    if Conversations._unsafe_any_home_mid_turn?(homes),
      do: {:error, :sandbox_mid_turn},
      else: :ok
  end

  defp bindings_allowed(user_id, %Agents.Agent{} = agent, changes) do
    options = addable_options(user_id, agent)

    with :ok <-
           binding_allowed(
             changes,
             :environment_id,
             options.environments,
             :environment_not_allowed
           ) do
      binding_allowed(changes, :vault_id, options.vaults, :vault_not_allowed)
    end
  end

  defp binding_allowed(changes, field, allowed, refusal) do
    case Map.get(changes, field) do
      nil -> :ok
      id -> if Enum.any?(allowed, &(&1.id == id)), do: :ok, else: {:error, refusal}
    end
  end

  defp write_bindings(_user_id, conv, changes, _orphans, _opts) when map_size(changes) == 0,
    do: {:ok, conv, :unchanged}

  defp write_bindings(user_id, conv, changes, orphans, opts) do
    case Conversations.update_conversation(conv, changes) do
      {:ok, updated} ->
        fields = for {key, field} <- @bindings, Map.has_key?(changes, field), do: key
        record(user_id, "team.updated", updated, opts, %{"fields" => fields})

        # Only once the new binding is the committed one: a machine torn down
        # against a write that then failed would be rebuilt for nothing.
        # Ownership: established above, by the scoped get_teammate.
        _ = Conversations._unsafe_retire_orphaned_homes(orphans, "teammate_rebound", opts)

        broadcast_changed(user_id)
        {:ok, updated, :updated}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Open a fresh conversation for the teammate on its current computer.

  The current conversation is released — `terminated`, past resuming, listed
  behind the new one in `list_teammate_conversations/2` — and a new one is
  opened under the same binding, carrying the teammate's name, environment
  and vault, and pointing at the **same sandbox**: the agent's next message
  wakes it through the ordinary reattach path and starts a new runtime
  session there, so the context is fresh but the disk is not. Nothing is
  provisioned, and the sandbox is not touched at all (a parked one stays
  parked until that message).

  When the computer is gone — the sandbox `terminated` or `failed`, or the
  current conversation already past resuming — there is nothing to keep, and
  the new conversation is opened the way `add_teammate/4` opens one: a fresh
  sandbox, provisioning now. Either way the caller gets the conversation that
  is current from here on.

  Returns `{:ok, conv}`; `{:error, :not_found}` off the team; `{:error,
  :busy}` while a turn is running (nothing is interrupted — interrupt first);
  `{:error, :provisioning}` while the computer is still starting; else the
  `start_conversation/2` errors on the fallback path. Audited as
  `team.conversation.rotated` (with `conversation.created` underneath);
  broadcasts the roster change, so a client following the stream re-lists
  and follows the new conversation.
  """
  def open_fresh_conversation(user_id, agent_id, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) and is_list(opts) do
    case get_teammate(user_id, agent_id) do
      nil ->
        {:error, :not_found}

      %{conversation: conv} ->
        # Ownership: `conv` (and its preloaded sandbox) came from the
        # tenant-scoped get_teammate above.
        with :ok <- releasable(conv) do
          rotate(user_id, agent_id, conv, opts)
        end
    end
  end

  # A computer mid-provision cannot change hands: the server holding it is
  # inside the provision and will mark the row ready or failed on its own.
  defp releasable(%Conversation{sandbox: %{status: s}}) when s in ["pending", "starting"],
    do: {:error, :provisioning}

  defp releasable(_conv), do: :ok

  defp rotate(user_id, agent_id, %Conversation{} = prev, opts) do
    keep? = live?(prev) and reusable_sandbox?(prev.sandbox)

    # **The computer's door is asked before the live conversation is
    # released** (round 1, surfaces review). The release is the irreversible
    # step of a rotation: with it committed `live?(prev)` is false, so `keep?`
    # is false on the retry and the next call provisions a *new* computer,
    # abandoning the disk this route's own description promises to keep ("same
    # computer, new session"). Before stage 8b nothing on this path could
    # refuse, so the order never mattered; `Machine.attach/3` can refuse — a
    # reset fence, a mid-operation lease, an identity the computer no longer
    # matches — and a client that did what the 503 told it to would have lost
    # its files.
    #
    # The verdict is a courtesy read on the row `get_teammate/2` preloaded,
    # exactly as `Launch.attach_conversation/3` takes one; the decision is
    # still the one `Machine.attach/3` makes under the machine's lock. The
    # window rule 16 asks about is the refusal that arrives *after* the
    # release commits — a lease claimed in between — and it is the one the
    # residual in the PR body names: the teammate is left with no live
    # conversation, its computer keeps its binding-less row, and the next
    # rotation builds a new one while `Machines.Policy`'s idle verdict parks
    # or reclaims the old.
    #
    # Release second (a running turn refuses there, before anything is
    # created); a conversation already past resuming has nothing to release.
    # `audit: false`: the rotation below is what the user asked for.
    result =
      with :ok <- door_open?(user_id, agent_id, prev, keep?),
           :ok <- release_previous(prev) do
        if keep?,
          do: open_on_sandbox(user_id, agent_id, prev, opts),
          else: open_on_new_sandbox(user_id, agent_id, prev, opts)
      end

    with {:ok, conv} <- result do
      record(user_id, "team.conversation.rotated", conv, opts, %{
        "previous_conversation_id" => prev.id,
        "computer_kept" => keep?
      })

      broadcast_changed(user_id)
    end

    result
  end

  defp reusable_sandbox?(%{status: s}) when s in ["ready", "suspended"], do: true
  defp reusable_sandbox?(_sandbox), do: false

  # The attach door's verdict, taken before the release. Only the keep path has
  # a door to ask: a rotation onto a new computer provisions its own, and
  # `Launch.start_conversation/2` makes every check there itself.
  #
  # Ownership: `agent_id`/`user_id` are the caller's, and `prev` (with its
  # preloaded sandbox) came from the tenant-scoped `get_teammate/2`.
  defp door_open?(_user_id, _agent_id, _prev, false), do: :ok

  defp door_open?(user_id, agent_id, %Conversation{} = prev, true) do
    case Agents.get_agent(agent_id, user_id) do
      nil -> {:error, :not_found}
      agent -> Binding.attachable(prev.sandbox, agent, prev.vault_id, prev.environment_id)
    end
  end

  defp release_previous(%Conversation{} = prev) do
    if live?(prev),
      do: Termination.release_conversation(prev.id, audit: false),
      else: :ok
  end

  # The same sandbox, a new conversation row: `idle` with no server, which is
  # exactly what a parked teammate looks like — `ConversationServer.send_prompt/4`
  # finds no server, `Conversations.wake_conversation/2` probes the sandbox and
  # reattaches. The runtime session id is left nil on purpose: that is the
  # fresh start. `runtime` is snapshotted from the agent as start_conversation
  # does, so a later change of the agent's runtime does not rewrite history.
  defp open_on_sandbox(user_id, agent_id, %Conversation{} = prev, opts) do
    agent = Agents.get_agent(agent_id, user_id)

    attrs = %{
      sandbox_id: prev.sandbox_id,
      agent_id: agent_id,
      # Ownership: agent came from the scoped get_agent above (nil-safe —
      # a deleted agent leaves the version unstamped, like the runtime).
      agent_version_id: agent && Agents._unsafe_current_version_id(agent.id),
      vault_id: prev.vault_id,
      environment_id: prev.environment_id,
      user_id: user_id,
      runtime: (agent && agent.runtime) || prev.runtime,
      status: "idle",
      source: Keyword.get(opts, :source, "ui"),
      channel_id: @channel,
      title: prev.title
    }

    # Through the machine's owner (ADR 0058 stage 8b): the successor is a new
    # binding to the same computer, and it gets the attach door's checks —
    # identity, status, fence, a live lease — which `create_conversation/1`
    # never made. A teammate whose agent has been deleted cannot be rotated
    # onto its computer any more (`:not_found`); its next prompt could not
    # have run without one either.
    with {:ok, conv, _allowance} <-
           Machine.attach(prev.sandbox_id, attrs, Keyword.take(opts, [:actor, :request_ip])) do
      Audit.record(%{
        user_id: user_id,
        action: "conversation.created",
        resource_type: "conversation",
        resource_id: conv.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{
          "agent_id" => agent_id,
          "agent_name" => agent && agent.name,
          "source" => conv.source,
          "with_prompt" => false,
          "sandbox_reused_from" => prev.id
        }
      })

      {:ok, Conversations.get_conversation(conv.id, user_id) || conv}
    end
  end

  # The computer is gone: a new one, provisioning now — what add_teammate does.
  defp open_on_new_sandbox(user_id, agent_id, %Conversation{} = prev, opts) do
    Launch.start_conversation(
      %{
        "agent_id" => agent_id,
        "user_id" => user_id,
        "channel_id" => @channel,
        "source" => Keyword.get(opts, :source, "ui"),
        "title" => prev.title,
        "environment_id" => prev.environment_id,
        "vault_id" => prev.vault_id
      },
      opts
    )
  end

  @doc """
  Every conversation `agent_id` has had on the team (#832): the current one
  first (`live?/1`, else the newest), then the retired ones newest first — a previous computer's thread, still bound to the channel until the
  teammate is removed. `[]` when the agent is not on the team.
  """
  def list_teammate_conversations(user_id, agent_id, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) do
    case user_id
         |> Conversations.list_channel_conversations(@channel, opts)
         |> Enum.filter(&(&1.agent_id == agent_id)) do
      [] ->
        []

      convs ->
        # The current one first, whatever its age — the roster's pick — then
        # the rest as listed (newest first).
        current = pick_current(convs)
        [current | Enum.reject(convs, &(&1.id == current.id))]
    end
  end

  # Membership events. Named after the team, not the conversation: the
  # conversation events (`conversation.created`, `.terminated`) still fire
  # underneath where they apply, and describe the sandbox side of the same
  # action; these describe the team side.
  defp record(user_id, action, %Conversation{} = conv, opts, extra \\ %{}) do
    Audit.record(%{
      user_id: user_id,
      action: action,
      resource_type: "conversation",
      resource_id: conv.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata:
        Map.merge(
          %{
            "agent_id" => conv.agent_id,
            "agent_name" => conv.agent && conv.agent.name
          },
          extra
        )
    })
  end
end
