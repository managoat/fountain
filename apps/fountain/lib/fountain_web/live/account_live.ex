defmodule FountainWeb.Live.AccountLive do
  @moduledoc """
  `/account` — the account's own settings: API keys, OAuth apps (#1125),
  change password (#448) and delete the account (#479).

  Each section is collapsed until the person opens it. Which sections are
  open is server state (`@open`), toggled by `phx-click`, rather than a
  `<details>` element: the delete form re-renders on every keystroke of its
  confirmation, and a re-render would reset a client-only `open` attribute
  and fold the form shut mid-typing.

  A collapsed section is hidden, not unmounted. The API keys and OAuth apps
  sections are LiveComponents holding their own state (`AccountLive.ApiKeys`,
  `AccountLive.OAuthApps`), and a just-minted key exists nowhere but in that
  state, so folding the section away must not destroy it.

  `?open=<slug>` expands a section on arrival; the pages these sections
  replaced (`/api-keys`, `/account/oauth-apps`, `/account/security`) redirect
  here with it.

  The password form is a plain HTML POST to `AccountSecurityController` (see
  its moduledoc: session rewrite, rate-limit plug), which redirects back to
  `/account?open=password`. The `open` parameter brings that section back
  expanded, and the controller's flash is shown inside it, next to the form
  it is about, instead of as a toast.

  Deletion delegates to `Fountain.Accounts.Deletion`.
  """

  use FountainWeb, :live_view

  alias Fountain.Accounts.Deletion
  alias FountainWeb.Live.AccountLive.{ApiKeys, OAuthApps}

  @sections ~w(api-keys oauth-apps password delete)

  @impl true
  def mount(params, _session, socket) do
    socket = FountainWeb.Audited.put_client_ip(socket)
    user = socket.assigns.current_user
    open = for s <- List.wrap(params["open"]), s in @sections, into: MapSet.new(), do: s

    {:ok,
     socket
     |> assign(
       page_title: "Account",
       has_password: not is_nil(user.password_hash),
       open: open,
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
      is_nil(notice) or not MapSet.member?(socket.assigns.open, "password") ->
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
  def handle_event("toggle", %{"section" => section}, socket) when section in @sections do
    open = socket.assigns.open

    if MapSet.member?(open, section) do
      {:noreply, socket |> assign(:open, MapSet.delete(open, section)) |> reset(section)}
    else
      {:noreply, assign(socket, :open, MapSet.put(open, section))}
    end
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

  # Folding a section away forgets what was in it, so reopening the delete
  # section never shows an already-armed button.
  defp reset(socket, "delete"), do: assign(socket, delete_confirmation: "", delete_error: nil)
  defp reset(socket, "password"), do: assign(socket, :password_notice, nil)
  # The components keep their state on purpose: a just-minted key must
  # survive the section being folded away.
  defp reset(socket, _section), do: socket

  @impl true
  def handle_info({:account_flash, kind, msg}, socket) when kind in [:info, :error] do
    {:noreply, put_flash(socket, kind, msg)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl space-y-6 px-4 py-8">
      <div>
        <h1 class="text-2xl font-semibold">Account</h1>
        <p class="mt-1 text-sm text-[var(--color-text-secondary)]">
          Signed in as <span class="font-mono">{@current_user.email}</span>
        </p>
      </div>

      <.section
        id="api-keys"
        title="API keys"
        open={MapSet.member?(@open, "api-keys")}
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
        open={MapSet.member?(@open, "oauth-apps")}
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

      <.section id="password" title="Change password" open={MapSet.member?(@open, "password")}>
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
        open={MapSet.member?(@open, "delete")}
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

  # One collapsible card. The header is a real button carrying aria-expanded,
  # so a keyboard or screen-reader user gets the same disclosure a click does;
  # the body is hidden, not removed, while collapsed, so the state of what is
  # in it survives (see the moduledoc).
  defp section(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "rounded-lg border bg-[var(--color-bg-1)] shadow-sm",
        if(@danger, do: "border-[var(--color-error)]", else: "border-[var(--color-border)]")
      ]}
    >
      <h2>
        <button
          type="button"
          id={"#{@id}-toggle"}
          phx-click="toggle"
          phx-value-section={@id}
          aria-expanded={to_string(@open)}
          aria-controls={"#{@id}-body"}
          class="flex w-full items-start justify-between gap-4 rounded-lg p-6 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-focus-ring)]"
        >
          <span>
            <span class={[
              "block text-lg font-medium",
              @danger && "text-[var(--color-error-text)]"
            ]}>
              {@title}
            </span>
            <span class="mt-1 block text-sm font-normal text-[var(--color-text-secondary)]">
              {render_slot(@summary)}
            </span>
          </span>
          <svg
            class={[
              "mt-1 size-4 shrink-0 text-[var(--color-text-secondary)] transition-transform",
              @open && "rotate-180"
            ]}
            viewBox="0 0 20 20"
            fill="currentColor"
            aria-hidden="true"
          >
            <path
              fill-rule="evenodd"
              d="M5.22 8.22a.75.75 0 0 1 1.06 0L10 11.94l3.72-3.72a.75.75 0 1 1 1.06 1.06l-4.25 4.25a.75.75 0 0 1-1.06 0L5.22 9.28a.75.75 0 0 1 0-1.06Z"
              clip-rule="evenodd"
            />
          </svg>
        </button>
      </h2>
      <div id={"#{@id}-body"} hidden={!@open} class="px-6 pb-6">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
