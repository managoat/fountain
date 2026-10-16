defmodule FountainWeb.Live.AccountLive do
  @moduledoc """
  Session-authenticated account settings with one selected section. Components
  remain mounted when hidden so unsaved forms and freshly minted keys survive
  navigation. Legacy `open=` links select the corresponding section.
  """

  use FountainWeb, :live_view

  alias Fountain.Accounts.Deletion

  alias FountainWeb.Live.AccountLive.{
    ApiKeys,
    Connections,
    OAuthApps,
    InferenceCredentials,
    SecretBindings
  }

  @sections [
    {"api-keys", "API keys", "Access"},
    {"oauth-apps", "OAuth apps", "Access"},
    {"connections", "Connections", "Integrations"},
    {"inference-credentials", "Inference credentials", "Integrations"},
    {"bindings", "Secret bindings", "Integrations"},
    {"security", "Security", "Account"}
  ]

  defp normalize_section(value) when value in ["password", "delete"], do: "security"

  defp normalize_section(value),
    do: if(Enum.any?(@sections, &(elem(&1, 0) == value)), do: value, else: "api-keys")

  @impl true
  def mount(params, _session, socket) do
    socket = FountainWeb.Audited.put_client_ip(socket)
    user = socket.assigns.current_user
    selected = normalize_section(params["open"])

    {:ok,
     socket
     |> assign(
       page_title: "Settings",
       has_password: not is_nil(user.password_hash),
       section: selected,
       sections: @sections,
       password_notice: nil,
       delete_error: nil,
       delete_confirmation: "",
       deleting: false
     )
     |> take_password_notice()}
  end

  # The controller's redirect back from a password POST carries its outcome
  # as a flash. Shown in the section it is about rather than as a toast.
  #
  # The flash the connected mount sees is whatever the disconnected render
  # left in it, so clearing it there would lose the message. Instead the
  # disconnected render re-files it under a key the layout's toast does not
  # render, and the connected mount reads it from there.
  @notice_keys [error: "password_error", info: "password_info"]

  defp take_password_notice(socket) do
    flash = socket.assigns.flash

    notice =
      Enum.find_value(@notice_keys, fn {kind, key} ->
        msg = Phoenix.Flash.get(flash, kind) || Phoenix.Flash.get(flash, key)
        msg && {kind, msg}
      end)

    cond do
      is_nil(notice) or socket.assigns.section != "security" ->
        socket

      connected?(socket) ->
        socket |> assign(:password_notice, notice) |> clear_flash()

      true ->
        {kind, msg} = notice

        socket
        |> assign(:password_notice, notice)
        |> clear_flash()
        |> put_flash(Keyword.fetch!(@notice_keys, kind), msg)
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected = normalize_section(params["open"])

    socket =
      if selected != socket.assigns.section,
        do: assign(socket, delete_confirmation: "", delete_error: nil),
        else: socket

    {:noreply, assign(socket, :section, selected)}
  end

  @impl true
  def handle_event("select_section", %{"section" => selected}, socket) do
    {:noreply, push_patch(socket, to: Fountain.Apps.account_url(normalize_section(selected)))}
  end

  def handle_event("confirm_delete_input", %{"email" => email}, socket) do
    {:noreply, assign(socket, delete_confirmation: email, delete_error: nil)}
  end

  # Typing the account's own email is the confirmation. It is not a security
  # control — the session already proves who this is — it is a speed bump, so
  # the irreversible button cannot be hit by reflex.
  def handle_event("delete_account", %{"email" => email}, socket) do
    user = socket.assigns.current_user

    cond do
      email != user.email ->
        {:noreply, assign(socket, :delete_error, "Type your email address exactly to confirm.")}

      socket.assigns.deleting ->
        {:noreply, socket}

      true ->
        socket = assign(socket, :deleting, true)

        case Deletion.delete_user(user,
               actor: "self",
               request_ip: socket.assigns[:client_ip]
             ) do
          {:ok, _summary} ->
            # Straight out through the controller so the session is dropped;
            # a LiveView cannot clear the session cookie itself.
            {:noreply, redirect(socket, to: ~p"/auth/logout?deleted=1")}

          {:error, _reason} ->
            {:noreply,
             assign(socket,
               deleting: false,
               delete_error: "Account deletion failed. Nothing was deleted."
             )}
        end
    end
  end

  @impl true
  def handle_info({:account_flash, kind, msg}, socket) when kind in [:info, :error] do
    {:noreply, put_flash(socket, kind, msg)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-semibold">Settings</h1>
        <p class="mt-1 text-sm text-[var(--color-text-secondary)]">
          Signed in as <span class="font-mono">{@current_user.email}</span>
        </p>
      </div>

      <div class="grid gap-8 md:grid-cols-[190px_minmax(0,1fr)]" id="account-settings">
        <nav aria-label="Settings sections" class="hidden md:block space-y-6">
          <div :for={group <- ["Access", "Integrations", "Account"]}>
            <p class="mb-2 px-3 text-xs font-medium uppercase tracking-wide text-[var(--color-text-muted)]">
              {group}
            </p>
            <.link
              :for={{id, title, item_group} <- @sections}
              :if={item_group == group}
              patch={Fountain.Apps.account_url(id)}
              data-section={id}
              aria-current={if @section == id, do: "page"}
              class={[
                "block rounded-md px-3 py-2 text-sm",
                if(@section == id,
                  do: "bg-[var(--color-bg-2)] font-medium text-[var(--color-brand)]",
                  else: "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)]"
                )
              ]}
            >{title}</.link>
          </div>
        </nav>
        <form id="account-section-form" phx-change="select_section" class="md:hidden">
          <label for="section-picker" class="block mb-2 text-sm">Settings section</label>
          <select
            id="section-picker"
            name="section"
            class="w-full rounded-md border border-[var(--color-border)] bg-[var(--color-bg-1)] p-2"
          >
            <option :for={{id, title, _} <- @sections} value={id} selected={@section == id}>
              {title}
            </option>
          </select>
        </form>
        <div class="min-w-0" id="settings-content">
          <.section
            id="api-keys"
            title="API keys"
            open={@section == "api-keys"}
          >
            <:summary>
              Authenticate requests to the Managoat API. A key is shown once, when it is created.
            </:summary>
            <.live_component
              module={ApiKeys}
              id="api-keys-component"
              current_user={@current_user}
              client_ip={@client_ip}
            />
          </.section>

          <.section
            id="oauth-apps"
            title="OAuth apps"
            open={@section == "oauth-apps"}
          >
            <:summary>
              Apps you are building that offer "Sign in with Managoat" against this server.
            </:summary>
            <.live_component
              module={OAuthApps}
              id="oauth-apps-component"
              current_user={@current_user}
              client_ip={@client_ip}
            />
          </.section>

          <.section
            id="connections"
            title="Connections"
            open={@section == "connections"}
          >
            <:summary>
              Remote MCP servers that sign in with OAuth, such as Linear. Agents name them; the
              token stays on this server.
            </:summary>
            <.live_component
              module={Connections}
              id="connections-component"
              current_user={@current_user}
              client_ip={@client_ip}
            />
          </.section>

          <section id="inference-credentials" hidden={@section != "inference-credentials"}>
            <.live_component
              module={InferenceCredentials}
              id="inference-credentials-component"
              current_user={@current_user}
              client_ip={@client_ip}
            />
          </section>
          <section id="bindings" hidden={@section != "bindings"}>
            <.live_component
              module={SecretBindings}
              id="bindings-component"
              current_user={@current_user}
              client_ip={@client_ip}
            />
          </section>
          <div id="security" hidden={@section != "security"} class="space-y-10">
            <.section id="password" title="Change password" open={@section == "security"}>
              <:summary>
                Every other session is signed out when the password changes; this one stays.
              </:summary>

              <.notice :if={@password_notice} id="password-notice" kind={elem(@password_notice, 0)}>
                {elem(@password_notice, 1)}
              </.notice>

              <p :if={!@has_password} class="text-sm text-[var(--color-text-secondary)]">
                This account signs in with GitHub and has no password, so there is
                nothing to change here. To add a password, use
                <.link navigate={~p"/auth/forgot-password"} class="underline">password reset</.link>
                with your account's email address.
              </p>

              <form
                :if={@has_password}
                method="post"
                action={~p"/account/security/password"}
                class="space-y-3"
                id="change-password"
              >
                <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                <div>
                  <label
                    for="current-password"
                    class="mb-1 block text-sm font-medium text-[var(--color-text-primary)]"
                  >
                    Current password
                  </label>
                  <input
                    id="current-password"
                    type="password"
                    name="current_password"
                    autocomplete="current-password"
                    class="w-full rounded-md border border-[var(--color-border-strong)] bg-[var(--color-bg-1)] px-3 py-2 text-sm"
                  />
                </div>
                <div>
                  <label
                    for="new-password"
                    class="mb-1 block text-sm font-medium text-[var(--color-text-primary)]"
                  >
                    New password
                  </label>
                  <input
                    id="new-password"
                    type="password"
                    name="new_password"
                    placeholder="At least 8 characters"
                    autocomplete="new-password"
                    class="w-full rounded-md border border-[var(--color-border-strong)] bg-[var(--color-bg-1)] px-3 py-2 text-sm"
                  />
                </div>
                <.button type="submit">Update password</.button>
              </form>
            </.section>

            <.section
              id="delete"
              title="Delete account"
              open={@section == "security"}
              danger
            >
              <:summary>Permanently deletes this account and everything in it.</:summary>

              <p class="mb-4 text-sm text-[var(--color-text-secondary)]">
                Destroys every running sandbox, and permanently
                deletes your agents, environments, vaults, conversations and stored secrets.
                Secrets are encrypted with a key held only for your account; deleting the
                account destroys that key, so they cannot be recovered afterwards by anyone.
                <strong>This cannot be undone.</strong>
              </p>

              <.notice :if={@delete_error} id="delete-error" kind={:error}>
                {@delete_error}
              </.notice>

              <form id="delete-account" phx-submit="delete_account" class="space-y-3">
                <label class="block text-sm text-[var(--color-text-secondary)]">
                  Type <span class="font-mono font-semibold">{@current_user.email}</span>
                  to confirm
                  <input
                    type="text"
                    name="email"
                    autocomplete="off"
                    value={@delete_confirmation}
                    phx-change="confirm_delete_input"
                    class="mt-1 block w-full rounded border-[var(--color-border-strong)] bg-[var(--color-bg-1)] text-sm text-[var(--color-text-primary)] shadow-sm"
                  />
                </label>

                <button
                  type="submit"
                  disabled={@delete_confirmation != @current_user.email or @deleting}
                  class="rounded bg-red-600 px-4 py-2 text-sm font-medium text-white disabled:cursor-not-allowed disabled:bg-[var(--color-bg-3)]"
                >
                  {if @deleting, do: "Deleting…", else: "Delete my account"}
                </button>
              </form>
            </.section>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :kind, :atom, values: [:info, :error], required: true
  slot :inner_block, required: true

  # An outcome shown beside the form it is about. Unlike a toast it stays put
  # until the next action, because it is the thing the person came back to.
  defp notice(assigns) do
    ~H"""
    <div
      id={@id}
      role={if @kind == :error, do: "alert", else: "status"}
      class={[
        "mb-4 rounded-lg border px-4 py-3 text-sm",
        if(@kind == :error,
          do: "border-[var(--color-error)] bg-[var(--color-error-bg)] text-[var(--color-error-text)]",
          else:
            "border-[var(--color-success)] bg-[var(--color-success-bg)] text-[var(--color-success-text)]"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :open, :boolean, required: true
  attr :danger, :boolean, default: false
  slot :summary, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <section id={@id} hidden={!@open} class="space-y-5">
      <div>
        <h2 class={["text-xl font-semibold", @danger && "text-[var(--color-error-text)]"]}>
          {@title}
        </h2>
        <p class="mt-2 text-sm text-[var(--color-text-secondary)]">{render_slot(@summary)}</p>
      </div>
      <div id={"#{@id}-body"}>{render_slot(@inner_block)}</div>
    </section>
    """
  end
end
