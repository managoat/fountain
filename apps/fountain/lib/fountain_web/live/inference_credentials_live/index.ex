defmodule FountainWeb.InferenceCredentialsLive.Index do
  @moduledoc """
  Settings page for per-user inference provider credentials (BYO, ADR 0008).

  One row per provider (Anthropic, Claude OAuth, OpenAI, Gemini). Each row
  shows set/not-set status; the form accepts a paste of the credential and
  validates by pinging the provider before persisting (encrypted with the
  per-tenant DEK).

  An account holds one or more named **sets** of those four (ADR 0053
  decision 1), exactly one of them the default. The four provider rows are
  always about the selected set, and an account that never makes a second one
  sees what it saw before: its default set, under the name it was given.

  Under the rows is the account's **ChatGPT subscriptions** card (ADR 0060
  decision 3), a component of its own, `SubscriptionsCard`. This page reads
  what the card shows, on mount and again whenever
  `Fountain.ChatGPTAccounts` says the account's grants or sign-ins changed.

  Plaintext is never displayed after save.
  """

  use FountainWeb, :live_view

  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Validator
  alias FountainWeb.InferenceCredentialsLive.SubscriptionsCard

  @providers [
    {:anthropic_api_key, "Anthropic API key", "ANTHROPIC_API_KEY",
     "For the Claude runtime (when no OAuth is set) and opencode against anthropic/* models. Get from console.anthropic.com."},
    {:claude_code_oauth_token, "Claude OAuth token", "CLAUDE_CODE_OAUTH_TOKEN",
     "Preferred for the Claude runtime — bills against your Claude.ai Pro/Team plan instead of metered API. Generate via 'claude setup-token'."},
    {:openai_api_key, "OpenAI API key", "OPENAI_API_KEY",
     "For the codex runtime and opencode against openai/* models. Get from platform.openai.com/api-keys."},
    {:gemini_api_key, "Gemini API key", "GEMINI_API_KEY",
     "For the gemini runtime and opencode against google/* models. Get from aistudio.google.com/apikey."}
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # The card's state is rows: a sign-in finished by its job, or anything
    # done in another tab or over the API, arrives as this message.
    if connected?(socket), do: Fountain.ChatGPTAccounts.subscribe(user.id)

    {:ok,
     socket
     |> assign(:page_title, "Inference credentials")
     |> assign(:user_id, user.id)
     |> assign(:providers, @providers)
     |> assign(:provider_messages, %{})
     |> assign(:set_message, nil)
     |> assign(:attribution, FountainWeb.Audited.attribution(socket))
     |> load_subscriptions()
     |> load_sets()}
  end

  defp load_subscriptions(socket),
    do: assign(socket, :subscriptions, SubscriptionsCard.load(socket.assigns.user_id))

  # The sets, and which one the provider rows are about. Re-read after every
  # write rather than patched in place: `set_default/2` moves a flag on a row
  # this socket is not holding, and a stale `is_default` on the selected set
  # would offer "make default" on the set that already is.
  defp load_sets(socket, select_id \\ nil) do
    sets = InferenceCredentials.list_sets(socket.assigns.user_id)
    keep = select_id || (socket.assigns[:set] && socket.assigns.set.id)
    selected = Enum.find(sets, &(&1.id == keep)) || List.first(sets)

    if select_id && not Enum.any?(sets, &(&1.id == select_id)) do
      unavailable_selection(socket)
    else
      socket
      |> assign(:sets, sets)
      |> assign(:set, selected)
      |> assign(:invalid_set_selection, false)
      |> assign(:status, InferenceCredentials.status_for_set(selected))
    end
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{invalid_set_selection: true}} = socket)
      when event in ["rename_set", "make_default", "delete_set", "save", "clear"] do
    {:noreply, unavailable_selection(socket)}
  end

  def handle_event("select_set", %{"id" => id}, socket) do
    case InferenceCredentials.get_set(id, socket.assigns.user_id) do
      nil ->
        {:noreply, unavailable_selection(socket)}

      _set ->
        {:noreply,
         socket
         |> assign(:provider_messages, %{})
         |> assign(:set_message, nil)
         |> load_sets(id)}
    end
  end

  def handle_event("create_set", %{"name" => name}, socket) do
    case InferenceCredentials.create_set(
           socket.assigns.user_id,
           String.trim(name || ""),
           FountainWeb.Audited.attribution(socket)
         ) do
      {:ok, set} ->
        {:noreply,
         socket
         |> assign(:set_message, {:info, "Created #{set.name}."})
         |> load_sets(set.id)}

      {:error, changeset} ->
        {:noreply, assign(socket, :set_message, {:error, set_error(changeset)})}
    end
  end

  def handle_event("rename_set", %{"name" => name}, socket) do
    case InferenceCredentials.rename_set(
           socket.assigns.set,
           String.trim(name || ""),
           FountainWeb.Audited.attribution(socket)
         ) do
      {:ok, set} ->
        {:noreply,
         socket
         |> assign(:set_message, {:info, "Renamed to #{set.name}."})
         |> load_sets(set.id)}

      {:error, :not_found} ->
        {:noreply, unavailable_selection(socket)}

      {:error, changeset} ->
        {:noreply, assign(socket, :set_message, {:error, set_error(changeset)})}
    end
  end

  def handle_event("make_default", _params, socket) do
    case InferenceCredentials.set_default(
           socket.assigns.set,
           FountainWeb.Audited.attribution(socket)
         ) do
      {:ok, set} ->
        {:noreply,
         socket
         |> assign(:set_message, {:info, "#{set.name} is now the default."})
         |> load_sets(set.id)}

      {:error, :not_found} ->
        {:noreply, unavailable_selection(socket)}

      {:error, _} ->
        {:noreply, assign(socket, :set_message, {:error, "Could not change the default."})}
    end
  end

  def handle_event("delete_set", _params, socket) do
    case InferenceCredentials.delete_set(
           socket.assigns.set,
           FountainWeb.Audited.attribution(socket)
         ) do
      {:ok, set} ->
        {:noreply,
         socket
         |> assign(:set_message, {:info, "Deleted #{set.name}."})
         |> load_sets()}

      {:error, :not_found} ->
        {:noreply, unavailable_selection(socket)}

      {:error, :is_default} ->
        {:noreply,
         assign(
           socket,
           :set_message,
           {:error, "The default set cannot be deleted. Make another one the default first."}
         )}

      {:error, _} ->
        {:noreply, assign(socket, :set_message, {:error, "Could not delete the set."})}
    end
  end

  def handle_event("save", %{"provider" => provider_str, "value" => value}, socket) do
    provider = String.to_existing_atom(provider_str)
    value = String.trim(value || "")

    cond do
      value == "" ->
        {:noreply,
         socket
         |> put_provider_message(provider, :error, "Paste a value before saving.")}

      true ->
        case Validator.validate(provider, value) do
          :ok ->
            persist_and_flash(socket, provider, value)

          {:error, :invalid, %{status: status}} ->
            {:noreply,
             put_provider_message(
               socket,
               provider,
               :error,
               "Provider rejected the credential (HTTP #{status}). Check that you copied the full token."
             )}

          {:error, :timeout} ->
            {:noreply,
             put_provider_message(
               socket,
               provider,
               :error,
               "Validation timed out. Provider may be slow — try again, or save anyway from the API."
             )}

          {:error, reason} ->
            {:noreply,
             put_provider_message(
               socket,
               provider,
               :error,
               "Could not reach provider (#{inspect(reason)}). Check your network."
             )}
        end
    end
  end

  def handle_event("clear", %{"provider" => provider_str}, socket) do
    provider = String.to_existing_atom(provider_str)

    case load_dek(socket.assigns.user_id) do
      {:ok, dek} ->
        case write_into_selected(socket, dek, provider, nil) do
          {:ok, _} ->
            {:noreply,
             socket
             |> load_sets()
             |> put_provider_message(provider, :info, "Credential cleared.")}

          {:error, :credential_set_unavailable} ->
            {:noreply, unavailable_selection(socket)}

          {:error, _cs} ->
            {:noreply,
             put_provider_message(socket, provider, :error, "Could not clear credential.")}
        end

      {:error, reason} ->
        {:noreply,
         put_provider_message(
           socket,
           provider,
           :error,
           "Could not load tenant key (#{inspect(reason)})."
         )}
    end
  end

  # The message carries nothing: read again, scoped by this page's owner.
  @impl true
  def handle_info({:chatgpt_grants_changed, _user_id}, socket),
    do: {:noreply, load_subscriptions(socket)}

  defp persist_and_flash(socket, provider, value) do
    with {:ok, dek} <- load_dek(socket.assigns.user_id),
         {:ok, _cred} <- write_into_selected(socket, dek, provider, value) do
      {:noreply,
       socket
       |> load_sets()
       |> put_provider_message(provider, :info, "Saved and validated.")}
    else
      {:error, :credential_set_unavailable} ->
        {:noreply, unavailable_selection(socket)}

      {:error, reason} ->
        {:noreply,
         put_provider_message(socket, provider, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  # Into the selected set, or through `put_credential/5` when the account has
  # none yet -- that path creates the default set on a first write, which is
  # what an account visiting this page for the first time does.
  defp write_into_selected(%{assigns: %{invalid_set_selection: true}}, _dek, _provider, _value),
    do: {:error, :credential_set_unavailable}

  defp write_into_selected(%{assigns: %{set: nil}} = socket, dek, provider, value) do
    InferenceCredentials.put_credential(
      socket.assigns.user_id,
      dek,
      provider,
      value,
      FountainWeb.Audited.attribution(socket)
    )
  end

  defp write_into_selected(socket, dek, provider, value) do
    with %{} = set <-
           InferenceCredentials.get_set(socket.assigns.set.id, socket.assigns.user_id) ||
             {:error, :credential_set_unavailable} do
      case InferenceCredentials.put_credential_in(
             set,
             dek,
             provider,
             value,
             FountainWeb.Audited.attribution(socket)
           ) do
        {:error, :not_found} -> {:error, :credential_set_unavailable}
        result -> result
      end
    end
  rescue
    Ecto.StaleEntryError -> {:error, :credential_set_unavailable}
  end

  # Refresh the choices without adopting another set for a pending mutation.
  # A later explicit selection (or creation) is what makes writes eligible again.
  defp unavailable_selection(socket) do
    socket
    |> assign(:sets, InferenceCredentials.list_sets(socket.assigns.user_id))
    |> assign(:set, nil)
    |> assign(:invalid_set_selection, true)
    |> assign(:status, InferenceCredentials.status_for_set(nil))
    |> assign(:provider_messages, %{})
    |> assign(
      :set_message,
      {:error, "That credential set is no longer available. Choose another set before saving."}
    )
  end

  defp set_error(%Ecto.Changeset{} = changeset) do
    case changeset.errors do
      [{_field, {message, _}} | _] -> "Name #{message}."
      _ -> "Could not save the set."
    end
  end

  defp load_dek(user_id) do
    Crypto.load_tenant_key(user_id)
  end

  defp put_provider_message(socket, provider, kind, msg) do
    update(socket, :provider_messages, fn map ->
      Map.put(map, provider, {kind, msg})
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 max-w-2xl">
      <div>
        <h1 class="text-2xl font-semibold">Inference credentials</h1>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1">
          Bring your own provider tokens. Sandboxes use these to call Anthropic, OpenAI, and Gemini directly — Fountain never sees your traffic and you pay providers directly.
          Tokens are encrypted at rest with your per-tenant key and decrypted only inside the conversation that needs them.
        </p>
      </div>

      <%!-- The sets, and which one the four rows below are about (ADR 0053
            decision 1). Hidden entirely for an account with at most one:
            somebody who has never wanted a second subscription should not
            have to learn the concept to paste a key. --%>
      <div
        :if={length(@sets) > 1 or @set_message}
        class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-5 space-y-3"
      >
        <div class="flex flex-wrap items-center gap-2">
          <button
            :for={set <- @sets}
            type="button"
            phx-click="select_set"
            phx-value-id={set.id}
            class={[
              "rounded-full px-3 py-1 text-xs font-medium border",
              if(@set && set.id == @set.id,
                do: "border-zinc-900 bg-zinc-900 text-white",
                else: "border-[var(--color-border)] text-[var(--color-text-secondary)]"
              )
            ]}
          >
            {set.name}<span :if={set.is_default} class="ml-1 opacity-70">· default</span>
          </button>
        </div>

        <div :if={@set} class="flex flex-wrap items-center gap-2">
          <form phx-submit="rename_set" class="flex gap-2">
            <input
              type="text"
              name="name"
              value={@set.name}
              maxlength="200"
              class="rounded-md border border-[var(--color-border)] bg-[var(--color-bg-2)] px-3 py-1.5 text-sm"
            />
            <.button type="submit" variant="secondary">Rename</.button>
          </form>

          <.button :if={!@set.is_default} type="button" phx-click="make_default" variant="secondary">
            Make default
          </.button>

          <.button
            :if={!@set.is_default}
            type="button"
            phx-click="delete_set"
            data-confirm={"Delete #{@set.name} and its credentials? Conversations bound to this set cannot resume."}
            variant="secondary"
          >
            Delete
          </.button>
        </div>

        <.provider_message message={@set_message} />
      </div>

      <div class="rounded-lg border border-dashed border-[var(--color-border)] p-4">
        <form phx-submit="create_set" class="flex flex-wrap gap-2 items-center">
          <input
            type="text"
            name="name"
            placeholder="Name a second set — “Work subscription”"
            maxlength="200"
            class="flex-1 min-w-[16rem] rounded-md border border-[var(--color-border)] bg-[var(--color-bg-2)] px-3 py-1.5 text-sm"
          />
          <.button type="submit" variant="secondary">Add credential set</.button>
        </form>
        <p class="text-xs text-[var(--color-text-secondary)] mt-2">
          A second set holds a second subscription. Point an agent at it from the agent
          form, or name it when you start a conversation. Your existing keys stay where
          they are.
        </p>
      </div>

      <p :if={@set} class="text-xs text-[var(--color-text-secondary)]">
        The four rows below are the <strong>{@set.name}</strong> set.
      </p>

      <div
        :for={{provider, label, env_name, hint} <- @providers}
        class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-5 space-y-3"
      >
        <div class="flex items-start justify-between gap-3">
          <div>
            <div class="flex items-center gap-2">
              <h2 class="text-base font-medium">{label}</h2>
              <.status_chip set?={Map.get(@status, provider, false)} />
            </div>
            <p class="text-xs text-[var(--color-text-secondary)] mt-1">{hint}</p>
            <p class="text-xs text-[var(--color-text-secondary)] mt-0.5">
              Sandbox env var: <code class="font-mono">{env_name}</code>
            </p>
          </div>
        </div>

        <form id={"credential-#{provider}"} phx-submit="save" class="space-y-2">
          <input type="hidden" name="provider" value={Atom.to_string(provider)} />
          <div class="flex gap-2">
            <input
              type="password"
              name="value"
              placeholder={
                if Map.get(@status, provider, false),
                  do: "Paste a new value to replace",
                  else: "Paste your token"
              }
              autocomplete="off"
              class="flex-1 rounded-md border border-[var(--color-border)] bg-[var(--color-bg-2)] px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-zinc-900"
            />
            <.button type="submit">Save</.button>
            <.button
              :if={Map.get(@status, provider, false)}
              type="button"
              phx-click="clear"
              phx-value-provider={Atom.to_string(provider)}
              variant="secondary"
            >
              Clear
            </.button>
          </div>
        </form>

        <.provider_message message={Map.get(@provider_messages, provider)} />
      </div>

      <.live_component
        :if={@subscriptions.visible?}
        module={SubscriptionsCard}
        id="chatgpt-subscriptions"
        user_id={@user_id}
        attribution={@attribution}
        subscriptions={@subscriptions}
      />
    </div>
    """
  end

  attr :set?, :boolean, required: true

  defp status_chip(%{set?: true} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-full bg-emerald-100 text-emerald-800 px-2 py-0.5 text-xs font-medium">
      Set
    </span>
    """
  end

  defp status_chip(assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-full bg-zinc-100 text-zinc-600 px-2 py-0.5 text-xs font-medium">
      Not set
    </span>
    """
  end

  attr :message, :any, required: true

  defp provider_message(%{message: nil} = assigns), do: ~H""

  defp provider_message(%{message: {:info, _}} = assigns) do
    ~H"""
    <p class="text-xs text-emerald-700">{elem(@message, 1)}</p>
    """
  end

  defp provider_message(%{message: {:error, _}} = assigns) do
    ~H"""
    <p class="text-xs text-rose-700">{elem(@message, 1)}</p>
    """
  end
end
