defmodule FountainWeb.DeviceLive do
  @moduledoc """
  The human half of device authorization (#1305): `fountain auth login
  --device` prints a short code and this page's URL; the signed-in user types
  (or arrives with) the code, sees what approving means, and decides. The
  polling CLI then collects an API key minted for this account.
  """
  use FountainWeb, :live_view

  alias Fountain.OAuth
  alias FountainWeb.Plugs.RateLimit

  @lookup_limit %{max: 20, window_ms: 60_000}

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Device login")
      |> assign(:stage, :enter)
      |> assign(:grant, nil)
      |> assign(:code_value, params["code"] || "")

    # A ?code= arrival (verification_uri_complete) skips the typing but not
    # the decision. Only the connected mount looks up the code, so the static
    # render neither exposes code validity nor charges a second lookup.
    socket =
      if connected?(socket) do
        case params["code"] do
          code when is_binary(code) and code != "" -> lookup(socket, code)
          _ -> socket
        end
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("lookup", %{"code" => code}, socket) do
    {:noreply, lookup(assign(socket, :code_value, code), code)}
  end

  def handle_event("approve", _params, socket) do
    case socket.assigns.grant do
      nil ->
        {:noreply, assign(socket, :stage, :enter)}

      grant ->
        case OAuth.approve_device_grant(
               grant.user_code,
               socket.assigns.current_user.id,
               FountainWeb.Audited.attribution(socket)
             ) do
          :ok ->
            {:noreply, socket |> assign(:stage, :approved) |> assign(:grant, nil)}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> assign(:stage, :enter)
             |> assign(:grant, nil)
             |> put_flash(:error, "That code is no longer waiting for approval.")}
        end
    end
  end

  def handle_event("deny", _params, socket) do
    case socket.assigns.grant do
      nil ->
        {:noreply, assign(socket, :stage, :enter)}

      grant ->
        _ =
          OAuth.deny_device_grant(
            grant.user_code,
            socket.assigns.current_user.id,
            FountainWeb.Audited.attribution(socket)
          )

        {:noreply, socket |> assign(:stage, :denied) |> assign(:grant, nil)}
    end
  end

  defp lookup(socket, code) do
    RateLimit.ensure_table()

    # Audited assigns the trusted peer/proxy address in the authentication hook.
    # Keep one bucket across accounts, sessions, and LiveView reconnects.
    key = {"device-lookup", socket.assigns[:client_ip] || "unknown"}

    case RateLimit.bump(key, @lookup_limit) do
      :ok ->
        lookup_grant(socket, code)

      {:limited, retry_after} ->
        socket
        |> assign(:stage, :enter)
        |> assign(:grant, nil)
        |> put_flash(:error, "Too many code lookups. Try again in #{retry_after} seconds.")
    end
  end

  defp lookup_grant(socket, code) do
    case OAuth.get_device_grant_for_approval(code) do
      {:ok, grant} ->
        socket |> assign(:stage, :confirm) |> assign(:grant, grant)

      {:error, :not_found} ->
        socket
        |> assign(:stage, :enter)
        |> assign(:grant, nil)
        |> put_flash(:error, "Code not found, expired, or already used. Check it and try again.")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto space-y-6">
      <div>
        <h1 class="text-2xl font-semibold">Device login</h1>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1">
          Approve a <code>fountain auth login --device</code> request from your terminal.
        </p>
      </div>

      <form :if={@stage == :enter} phx-submit="lookup" class="space-y-3">
        <.form_field
          id="code"
          label="Code shown in your terminal"
          name="code"
          type="text"
          placeholder="BCDF-GHJK"
          value={@code_value}
          errors={[]}
          required
        />
        <.button type="submit">Continue</.button>
      </form>

      <div
        :if={@stage == :confirm && @grant}
        class="rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] p-6 space-y-4"
      >
        <p class="text-sm">
          A device holding the code below is asking for an API key for <span class="font-medium">{@current_user.email}</span>.
        </p>
        <code class="block text-center text-2xl font-mono tracking-widest py-2">
          {OAuth.format_user_code(@grant.user_code)}
        </code>
        <p class="text-sm text-[var(--color-text-secondary)]">
          Only approve if you just ran <code>fountain auth login --device</code>
          on a machine you control and this code matches your terminal.
          The key has full access to your account.
        </p>
        <div class="flex gap-2">
          <.button phx-click="approve">Approve</.button>
          <.button phx-click="deny" variant="secondary">Deny</.button>
        </div>
      </div>

      <div
        :if={@stage == :approved}
        class="rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] p-6"
      >
        <p class="text-sm font-medium">Approved.</p>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1">
          Return to your terminal — the CLI picks the key up on its next poll.
          It lists under <.link navigate={~p"/account?open=api-keys"} class="underline">API keys</.link>,
          where you can revoke it any time.
        </p>
      </div>

      <div
        :if={@stage == :denied}
        class="rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] p-6"
      >
        <p class="text-sm font-medium">Denied.</p>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1">
          The device gets <code>access_denied</code> and no key was created.
        </p>
      </div>
    </div>
    """
  end
end
