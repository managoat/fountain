defmodule FountainWeb.InferenceCredentialsLive.SubscriptionsCard do
  @moduledoc """
  The **ChatGPT subscriptions** card on `/account/inference-credentials` (ADR
  0060 decision 3): the account's linked subscriptions, one row each, and the
  device-code sign-in that links another.

  The card holds nothing a reload would lose. `load/1` reads the grants and
  the open sign-ins from `Fountain.ChatGPTAccounts`; the page calls it on
  mount and again on every `{:chatgpt_grants_changed, _}`, so a sign-in begun
  in another tab, finished by the job or ended by a disconnect elsewhere shows
  up here, and a fresh mount renders a pending sign-in's code from its row.

  What reaches the assigns is `load/1`'s projection and never a context view
  whole: a subscription is its id, name, state, plan, email and times, and an
  open sign-in is its id, what it is for, its user code, its page and its
  expiry. No token, claim, provider account id, generation or device id is
  assigned or rendered. The user code is there only while the sign-in is
  pending, because the context only answers it then.

  Every event calls the context with the owner the page was mounted for. An
  id in an event is the client's word: another account's id is the context's
  `:not_found`, and reads here as "no longer on this account".
  """

  use FountainWeb, :live_component

  alias Fountain.ChatGPTAccounts

  # Where a device code is approved. The row's URL is rendered as a link only
  # when it is `https` on one of these hosts; anything else is shown as the
  # page to type, from the constant below and not from the row.
  @verification_hosts ~w(auth.openai.com)
  @verification_page "https://auth.openai.com/codex/device"

  @doc """
  What the card renders for `user_id`, read fresh: the one place this page
  reads `Fountain.ChatGPTAccounts`. `:visible?` is the gate (ADR 0060,
  "Implementation sequence"): the card is there when the account may link,
  and stays there for an account that already holds a subscription or has a
  sign-in open, so turning linking off strands nothing.
  """
  @spec load(String.t()) :: map()
  def load(user_id) when is_binary(user_id) do
    grants = user_id |> ChatGPTAccounts.list_for_user() |> Enum.map(&grant/1)
    attempts = user_id |> ChatGPTAccounts.list_pending_attempts_for_user() |> Enum.map(&attempt/1)
    linking? = ChatGPTAccounts.linking_enabled_for?(user_id)

    %{
      grants: grants,
      attempts: attempts,
      count: length(grants),
      limit: ChatGPTAccounts.grant_ceiling(),
      linking?: linking?,
      visible?: linking? or grants != [] or attempts != []
    }
  end

  # Named key by key, so a field the context adds to its view does not reach
  # the page by default.
  defp grant(view) do
    %{
      id: view.grant_id,
      name: view.name,
      state: grant_state(view),
      plan_type: view.plan_type,
      account_email: view.account_email,
      last_refreshed_at: view.last_refreshed_at,
      exhausted_until: view.exhausted_until
    }
  end

  # What resolution would say of the grant (`Resolver.grant_state/1`), less
  # the deployment's broker, which is not the subscription's state.
  defp grant_state(view) do
    cond do
      view.status == "disconnected" -> :disconnected
      view.status == "revoked" -> :revoked
      view.status == "expired" -> :expired
      view.status != "active" or not view.refreshable -> :reconnect_required
      view.account_id in [nil, ""] -> :reconnect_required
      match?(%DateTime{}, view.exhausted_until) -> :exhausted
      true -> :connected
    end
  end

  defp attempt(%ChatGPTAccounts.AttemptView{} = view) do
    %{
      id: view.id,
      kind: view.kind,
      name: view.name,
      grant_id: view.grant_id,
      user_code: view.user_code,
      verification_link: verification_link(view.verification_url),
      expires_at: view.expires_at
    }
  end

  defp verification_link(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, port: 443}}
      when host in @verification_hosts ->
        url

      _ ->
        nil
    end
  end

  defp verification_link(_url), do: nil

  @impl true
  def update(assigns, socket) do
    previous = socket.assigns[:subscriptions]

    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:message, fn -> nil end)
     |> assign_new(:notices, fn -> [] end)
     |> note_ended(previous)}
  end

  # A sign-in this page was showing is no longer open: say how it ended. Read
  # from its row, by the owner, so the sentence is the same whichever tab,
  # job or API call ended it. One the page never showed says nothing, and
  # neither does a cancel, which somebody asked for.
  defp note_ended(socket, nil), do: socket

  defp note_ended(socket, %{attempts: before}) do
    open = MapSet.new(socket.assigns.subscriptions.attempts, & &1.id)

    notices =
      before
      |> Enum.reject(&MapSet.member?(open, &1.id))
      |> Enum.flat_map(&ended_notice(&1, socket.assigns))

    assign(socket, :notices, Enum.take(notices ++ socket.assigns.notices, 3))
  end

  defp ended_notice(attempt, assigns) do
    label = attempt_label(attempt, assigns.subscriptions.grants)

    case ChatGPTAccounts.get_attempt_for_user(attempt.id, assigns.user_id) do
      {:ok, %{state: "completed"}} ->
        [{:info, "#{label} is connected."}]

      {:ok, %{state: "expired"}} ->
        [
          {:error,
           "The sign-in code for #{label} expired before it was approved. Nothing was " <>
             "linked; start again when you are ready."}
        ]

      {:ok, %{state: "failed", failure: failure}} ->
        [{:error, failure_text(failure, label)}]

      _cancelled_or_gone ->
        []
    end
  end

  # One sentence per `LinkAttempt.failure_reasons/0`, and a plain one for a
  # reason a later stage adds before it adds the sentence.
  defp failure_text(%{reason: reason}, label) do
    case reason do
      "grant_limit_reached" ->
        "The sign-in for #{label} was approved, but this account already holds as many " <>
          "subscriptions as it may. Nothing was linked; remove a disconnected one and start again."

      "grant_not_found" ->
        "The sign-in for #{label} was approved, but that subscription had been removed. " <>
          "Nothing was linked."

      "name_taken" ->
        "The sign-in was approved, but another subscription took the name #{label} first. " <>
          "Nothing was linked; start again under another name."

      "owner_ineligible" ->
        "The sign-in for #{label} was approved, but this account may not link a subscription " <>
          "right now: that takes a verified account that is not suspended. Nothing was linked."

      "tenant_key_unavailable" ->
        "The sign-in for #{label} could not be stored: this account's encryption key did not " <>
          "load. Nothing was linked; start again shortly."

      "invalid_sign_in" ->
        "ChatGPT approved the code for #{label} but did not hand back a sign-in Fountain can " <>
          "renew. Nothing was linked; start again."

      reason when reason in ["authorization_failed", "exchange_failed"] ->
        "ChatGPT refused the sign-in for #{label}. Nothing was linked. Check that device-code " <>
          "sign-in is enabled in the ChatGPT account's security settings, and start again."

      _ ->
        "The sign-in for #{label} did not finish. Nothing was linked; start again."
    end
  end

  defp failure_text(_failure, label),
    do: "The sign-in for #{label} did not finish. Nothing was linked; start again."

  defp attempt_label(%{kind: :link, name: name}, _grants), do: name

  defp attempt_label(%{grant_id: grant_id}, grants) do
    case Enum.find(grants, &(&1.id == grant_id)) do
      %{name: name} -> name
      nil -> "that subscription"
    end
  end

  # ── events ───────────────────────────────────────────────────────────────

  @impl true
  def handle_event("connect", %{"name" => name}, socket) when is_binary(name) do
    case ChatGPTAccounts.start_attempt_for_user(
           socket.assigns.user_id,
           %{name: String.trim(name)},
           socket.assigns.attribution
         ) do
      {:ok, _attempt} -> {:noreply, socket |> assign(:notices, []) |> message(nil)}
      {:error, reason} -> {:noreply, message(socket, {:error, error_text(reason, :sign_in)})}
    end
  end

  def handle_event("cancel_attempt", %{"id" => id}, socket) when is_binary(id) do
    case ChatGPTAccounts.cancel_attempt_for_user(
           id,
           socket.assigns.user_id,
           socket.assigns.attribution
         ) do
      {:ok, _attempt} -> {:noreply, message(socket, {:info, "Sign-in cancelled."})}
      {:error, reason} -> {:noreply, message(socket, {:error, error_text(reason, :sign_in)})}
    end
  end

  def handle_event("rename", %{"grant_id" => id, "name" => name}, socket)
      when is_binary(id) and is_binary(name) do
    case ChatGPTAccounts.rename_for_user(
           id,
           socket.assigns.user_id,
           String.trim(name),
           socket.assigns.attribution
         ) do
      {:ok, grant} ->
        {:noreply, message(socket, {:info, "Renamed to #{grant.name}."})}

      {:error, reason} ->
        {:noreply, message(socket, {:error, error_text(reason, name_of(socket, id))})}
    end
  end

  def handle_event("disconnect", %{"id" => id}, socket) when is_binary(id) do
    name = name_of(socket, id)

    case ChatGPTAccounts.disconnect_for_user(
           id,
           socket.assigns.user_id,
           socket.assigns.attribution
         ) do
      :ok -> {:noreply, message(socket, {:info, "Disconnected #{name}."})}
      {:error, reason} -> {:noreply, message(socket, {:error, error_text(reason, name)})}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) when is_binary(id) do
    name = name_of(socket, id)

    case ChatGPTAccounts.remove_for_user(id, socket.assigns.user_id, socket.assigns.attribution) do
      :ok -> {:noreply, message(socket, {:info, "Removed #{name}."})}
      {:error, reason} -> {:noreply, message(socket, {:error, error_text(reason, name)})}
    end
  end

  # An event this card does not send, or one without the id it names.
  def handle_event(_event, _params, socket),
    do: {:noreply, message(socket, {:error, "That request was not understood."})}

  defp message(socket, message), do: assign(socket, :message, message)

  # The name the page is showing for the id, for the sentence only: whether
  # the id is this account's is the context's to say.
  defp name_of(socket, id) do
    case Enum.find(socket.assigns.subscriptions.grants, &(&1.id == id)) do
      %{name: name} -> name
      nil -> "that subscription"
    end
  end

  # Every refusal `Fountain.ChatGPTAccounts` documents for the calls above,
  # and a plain sentence for one it does not: never the term itself.
  defp error_text(:not_found, :sign_in), do: "That sign-in is no longer open."
  defp error_text(:not_found, _name), do: "That subscription is no longer on this account."

  defp error_text(:subscriptions_not_enabled, _subject),
    do: "Linking a ChatGPT subscription is not available on this account."

  defp error_text(:ineligible_owner, _subject),
    do:
      "This account cannot link or rename a subscription right now: that takes a verified " <>
        "account that is not suspended."

  defp error_text({:link_attempts_exceeded, %{limit: limit}}, _subject),
    do: "#{limit} sign-ins are already open on this account. Finish or cancel one first."

  defp error_text({:grant_limit_reached, %{count: count, limit: limit}}, _subject),
    do:
      "This account holds #{count} of the #{limit} subscriptions it may. Remove a " <>
        "disconnected one to link another."

  defp error_text({:link_attempt_pending, _}, _subject),
    do: "A sign-in is already open for that subscription. Finish or cancel it first."

  defp error_text({:link_attempt_not_pending, %{state: state}}, _subject),
    do: "That sign-in has already #{ended(state)}, so there is nothing to cancel."

  defp error_text(:tenant_key_unavailable, _subject),
    do: "This account's encryption key did not load, so nothing was started. Try again shortly."

  defp error_text(:auth_unreachable, _subject),
    do: "ChatGPT's sign-in service did not answer. Nothing was started; try again in a moment."

  defp error_text(:invalid_target, _subject), do: "Give the subscription a name."

  defp error_text(:still_connected, name),
    do: "#{name} still holds a sign-in. Disconnect it before removing it."

  defp error_text({:named_by_sets, names}, name) when is_list(names),
    do:
      "#{name} is still named by #{sets(names)}. Point #{them(names)} at another " <>
        "subscription, or at none, and remove it then."

  defp error_text(%Ecto.Changeset{errors: [{_field, {text, opts}} | _]}, _subject),
    do: "Name #{interpolate(text, opts)}."

  defp error_text(_reason, _subject), do: "That did not work, and nothing was changed."

  defp ended("completed"), do: "completed"
  defp ended("expired"), do: "expired"
  defp ended("failed"), do: "failed"
  defp ended(_state), do: "ended"

  defp sets([name]), do: "the credential set #{name}"
  defp sets(names), do: "the credential sets #{Enum.join(names, ", ")}"

  defp them([_one]), do: "it"
  defp them(_names), do: "them"

  # Ecto's `%{count}` in a validation message.
  defp interpolate(text, opts) do
    Enum.reduce(opts, text, fn
      {key, value}, acc when is_integer(value) or is_binary(value) ->
        String.replace(acc, "%{#{key}}", to_string(value))

      _other, acc ->
        acc
    end)
  end

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-5 space-y-4"
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <h2 class="text-base font-medium">ChatGPT subscriptions</h2>
          <p class="text-xs text-[var(--color-text-secondary)] mt-1">
            Sign in with a ChatGPT plan and the codex runtime runs on it instead of an OpenAI API
            key. Fountain holds the sign-in and renews it; a sandbox only ever sees a placeholder.
            A credential set names the subscription its agents use, and nothing switches to
            another one for you.
          </p>
        </div>
        <span
          id={"#{@id}-count"}
          class="shrink-0 text-xs text-[var(--color-text-secondary)]"
        >
          {@subscriptions.count} of {@subscriptions.limit}
        </span>
      </div>

      <p
        :if={@subscriptions.grants == [] and @subscriptions.attempts == []}
        class="text-sm text-[var(--color-text-secondary)]"
      >
        No subscription is linked yet.
      </p>

      <div
        :for={grant <- @subscriptions.grants}
        id={"chatgpt-grant-#{grant.id}"}
        class="rounded-md border border-[var(--color-border)] p-4 space-y-3"
      >
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-sm font-medium">{grant.name}</span>
          <.state_chip state={grant.state} />
          <span :if={grant.account_email} class="text-xs text-[var(--color-text-secondary)]">
            {grant.account_email}<span :if={grant.plan_type}> ({grant.plan_type})</span>
          </span>
        </div>

        <p class="text-xs text-[var(--color-text-secondary)]">
          {state_text(grant)}
        </p>

        <div class="flex flex-wrap items-center gap-2">
          <form phx-submit="rename" phx-target={@myself} class="flex gap-2">
            <input type="hidden" name="grant_id" value={grant.id} />
            <input
              type="text"
              name="name"
              value={grant.name}
              maxlength="200"
              aria-label={"Name of #{grant.name}"}
              class="rounded-md border border-[var(--color-border)] bg-[var(--color-bg-2)] px-3 py-1.5 text-sm"
            />
            <.button type="submit" variant="secondary">Rename</.button>
          </form>

          <.button
            :if={grant.state != :disconnected}
            type="button"
            phx-click="disconnect"
            phx-value-id={grant.id}
            phx-target={@myself}
            data-confirm={"Disconnect #{grant.name}? Fountain forgets its sign-in at once and every conversation running on it stops. Credential sets that name it keep naming it and fail by name until it is reconnected."}
            variant="secondary"
          >
            Disconnect
          </.button>

          <.button
            :if={grant.state == :disconnected}
            type="button"
            phx-click="remove"
            phx-value-id={grant.id}
            phx-target={@myself}
            data-confirm={"Remove #{grant.name} from this account?"}
            variant="secondary"
          >
            Remove
          </.button>
        </div>
      </div>

      <div
        :for={attempt <- @subscriptions.attempts}
        id={"chatgpt-attempt-#{attempt.id}"}
        class="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900 space-y-2"
      >
        <div class="font-medium">
          Connecting {attempt_label(attempt, @subscriptions.grants)}
        </div>
        <div :if={attempt.user_code}>
          <span :if={attempt.verification_link}>
            Open
            <a
              href={attempt.verification_link}
              target="_blank"
              rel="noopener noreferrer"
              class="underline"
            >{attempt.verification_link}</a>
          </span>
          <span :if={!attempt.verification_link}>
            Type <span class="font-mono">{verification_page()}</span> into your browser
          </span>
          and enter the code <code
            id={"chatgpt-code-#{attempt.id}"}
            class="font-mono text-base font-semibold"
          >{attempt.user_code}</code>.
        </div>
        <div :if={!attempt.user_code}>
          The code for this sign-in could not be read. Cancel it and start again.
        </div>
        <div class="text-xs">
          Approve a code only if you started it yourself, on this page: whoever's code you
          approve gets the use of your ChatGPT plan. The code expires at {clock(attempt.expires_at)};
          device-code sign-in must be enabled in the ChatGPT account's security settings.
          This page updates by itself once ChatGPT says the code was approved.
        </div>
        <div class="flex flex-wrap gap-2">
          <.button
            :if={attempt.user_code}
            id={"copy-chatgpt-code-#{attempt.id}"}
            type="button"
            phx-hook="CopyToClipboard"
            data-target={"chatgpt-code-#{attempt.id}"}
            variant="secondary"
          >
            Copy code
          </.button>
          <.button
            type="button"
            phx-click="cancel_attempt"
            phx-value-id={attempt.id}
            phx-target={@myself}
            variant="secondary"
          >
            Cancel
          </.button>
        </div>
      </div>

      <p
        :for={{kind, text} <- @notices}
        class={["text-xs", if(kind == :info, do: "text-emerald-700", else: "text-rose-700")]}
      >
        {text}
      </p>

      <form
        :if={@subscriptions.linking? and @subscriptions.count < @subscriptions.limit}
        id="chatgpt-connect"
        phx-submit="connect"
        phx-target={@myself}
        class="flex flex-wrap gap-2 items-center"
      >
        <input
          type="text"
          name="name"
          placeholder="Name this subscription — “Work ChatGPT”"
          maxlength="200"
          class="flex-1 min-w-[16rem] rounded-md border border-[var(--color-border)] bg-[var(--color-bg-2)] px-3 py-1.5 text-sm"
        />
        <.button type="submit">Connect a subscription</.button>
      </form>

      <p
        :if={@subscriptions.linking? and @subscriptions.count >= @subscriptions.limit}
        class="text-xs text-[var(--color-text-secondary)]"
      >
        This account holds as many subscriptions as it may. A disconnected one still counts:
        remove it to link another.
      </p>

      <p :if={!@subscriptions.linking?} class="text-xs text-[var(--color-text-secondary)]">
        Linking another subscription is not available on this account. The ones above can
        still be renamed, disconnected and removed.
      </p>

      <p
        :if={@message}
        id={"#{@id}-message"}
        class={[
          "text-xs",
          if(elem(@message, 0) == :info, do: "text-emerald-700", else: "text-rose-700")
        ]}
      >
        {elem(@message, 1)}
      </p>
    </section>
    """
  end

  defp verification_page, do: @verification_page

  attr :state, :atom, required: true

  defp state_chip(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
      case @state do
        :connected -> "bg-emerald-100 text-emerald-800"
        :disconnected -> "bg-zinc-100 text-zinc-600"
        _ -> "bg-amber-100 text-amber-800"
      end
    ]}>
      {state_label(@state)}
    </span>
    """
  end

  defp state_label(:connected), do: "Connected"
  defp state_label(:disconnected), do: "Disconnected"
  defp state_label(:exhausted), do: "Usage spent"
  defp state_label(_needs_sign_in), do: "Reconnect required"

  defp state_text(%{state: :connected} = grant) do
    case grant.last_refreshed_at do
      %DateTime{} = at -> "Last renewed #{stamp(at)}."
      nil -> "Connected."
    end
  end

  defp state_text(%{state: :exhausted, exhausted_until: until}),
    do:
      "This plan has used its Codex allowance until #{stamp(until)}. Runs that name it are " <>
        "refused until then; nothing else is used in its place."

  defp state_text(%{state: :disconnected}),
    do:
      "Fountain holds no sign-in for this subscription. Credential sets that name it fail by " <>
        "name until it is connected again."

  defp state_text(%{state: :revoked}),
    do: "OpenAI no longer accepts this sign-in. Runs that name it are refused."

  defp state_text(%{state: :expired}),
    do: "This sign-in has expired. Runs that name it are refused."

  defp state_text(%{state: _reconnect_required}),
    do: "This sign-in can no longer be renewed. Runs that name it are refused."

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M UTC")
end
