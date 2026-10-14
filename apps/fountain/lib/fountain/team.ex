defmodule Fountain.Team do
  @moduledoc """
  The team: the agents a user talks to as people, one persistent
  conversation each.

  A teammate is not a new kind of thing. It is a conversation — one per
  agent — bound to the reserved channel `"fountain:team"`, exactly the way
  any client binds a conversation through `channel_id` (#774). Adding an
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
  alias Fountain.Conversations.{Conversation, ConversationServer, Launch, Termination}
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
  (`:not_found`, `:fleet_full`, ...). `opts` is audit attribution, plus an optional `:source` (`"ui"` or
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
  `:provisioning`, ...).
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

  The teammate's current computer is left as it is: it was built from the
  old binding and keeps serving the conversation on it. The next computer,
  from `open_fresh_conversation/3`, is built from the new one.

  Returns `{:ok, conv, :updated}`, or `{:ok, conv, :unchanged}` when `attrs`
  matched the teammate already. `{:error, :not_found}` when the agent is not
  on the team, `{:error, :environment_not_allowed}` / `{:error,
  :vault_not_allowed}` when an id is not the caller's own or not on the
  agent's allowlist. Audited as `team.updated` with the
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

    # Ownership: `conv` and `agent` came from the scoped get_teammate.
    with :ok <- bindings_allowed(user_id, agent, changes) do
      write_bindings(user_id, conv, changes, opts)
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

  defp write_bindings(_user_id, conv, changes, _opts) when map_size(changes) == 0,
    do: {:ok, conv, :unchanged}

  defp write_bindings(user_id, conv, changes, opts) do
    case Conversations.update_conversation(conv, changes) do
      {:ok, updated} ->
        fields = for {key, field} <- @bindings, Map.has_key?(changes, field), do: key
        record(user_id, "team.updated", updated, opts, %{"fields" => fields})
        broadcast_changed(user_id)
        {:ok, updated, :updated}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Open a fresh conversation for the teammate, on a fresh computer.

  The current conversation is ended — `terminated`, past resuming, listed
  behind the new one in `list_teammate_conversations/2` — and its computer is
  destroyed, since every conversation has a sandbox of its own (#2676). The
  new one is opened the way `add_teammate/4` opens one, under the same
  binding, carrying the teammate's name, environment and vault: a fresh
  sandbox, provisioning now. The caller gets the conversation that is
  current from here on.

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
    # Release first (a running turn refuses there, before anything is
    # created); a conversation already past resuming has nothing to release.
    # `audit: false`: the rotation below is what the user asked for.
    result =
      with :ok <- end_previous(prev, opts),
           do: open_on_new_sandbox(user_id, agent_id, prev, opts)

    with {:ok, conv} <- result do
      record(user_id, "team.conversation.rotated", conv, opts, %{
        "previous_conversation_id" => prev.id,
        "computer_kept" => false
      })

      broadcast_changed(user_id)
    end

    result
  end

  # The release refuses a running turn without interrupting it, and keeps the
  # machine; nobody else can be on it, so it is destroyed right after, in the
  # background, as a terminate's is (`Termination.destroy_after_terminate/2`).
  defp end_previous(%Conversation{} = prev, opts) do
    if live?(prev) do
      with :ok <- Termination.release_conversation(prev.id, audit: false) do
        _ =
          Termination.retire_terminated_sandbox(
            prev,
            [destroy: :background] ++ Keyword.take(opts, [:actor, :request_ip])
          )

        :ok
      end
    else
      :ok
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
