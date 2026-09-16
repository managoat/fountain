defmodule FountainWeb.AdminLive.Inference do
  @moduledoc """
  `/admin/inference` — the deployment's own inference keys (ADR 0038
  decision 3), one row per provider.

  Until this page the keys were `PLATFORM_<PROVIDER>_API_KEY` and nothing
  else, so rotating one meant a secret-store edit and a rollout. A key set
  here is stored encrypted under the master key and wins over the variable
  from the next conversation on, with no restart; clearing it hands the
  provider back to the variable. The page shows where each provider's live
  key comes from and its last four characters, which is what an operator
  needs to answer "is the new key in yet?" — and nothing more of the value.

  Every mutation goes through `Fountain.PlatformInference`, which records
  the `admin.platform_inference_key.*` event; the page only says who asked.

  The "ChatGPT account (codex)" row (ADR 0047) is the same shape over
  `Fountain.ChatGPTAccounts`: paste, workspace token, device code and
  disconnect, each recorded by the context. The device flow runs in a
  supervised task and reports back as `{:platform_chatgpt_device, _}`.
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.ChatGPTAccounts
  alias Fountain.PlatformInference

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Inference")
     |> assign(:credits_enabled, Fountain.Credits.enabled?())
     |> assign(:device, nil)
     |> assign_keys()
     |> assign_chatgpt()}
  end

  @impl true
  def handle_event("set_key", %{"provider" => provider, "value" => value}, socket) do
    case PlatformInference.put_key(provider, value, actor_user_id: socket.assigns.current_user.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_keys()
         |> put_flash(
           :info,
           "#{provider_label(provider)} key saved — in use from the next conversation"
         )}

      {:error, :invalid_key} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That does not look like a key: paste one value with no spaces, or use Clear to remove it"
         )}
    end
  end

  def handle_event("clear_key", %{"provider" => provider}, socket) do
    :ok = PlatformInference.clear_key(provider, actor_user_id: socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign_keys()
     |> put_flash(:info, "#{provider_label(provider)} key cleared")}
  end

  # ── the ChatGPT account for codex (ADR 0047) ─────────────────────────────

  def handle_event("chatgpt_paste", %{"auth_json" => json}, socket) do
    case ChatGPTAccounts.platform_connect_from_auth_json(json,
           actor_user_id: socket.assigns.current_user.id
         ) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign_chatgpt()
         |> put_flash(:info, "ChatGPT account connected as #{account.account_email || "unknown"}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, chatgpt_error(reason))}
    end
  end

  def handle_event("chatgpt_workspace_token", %{"value" => value} = params, socket) do
    expires_on =
      case Date.from_iso8601(Map.get(params, "expires_on", "")) do
        {:ok, date} -> date
        _ -> nil
      end

    case ChatGPTAccounts.platform_connect_workspace_token(value, expires_on,
           actor_user_id: socket.assigns.current_user.id,
           account_id: Map.get(params, "account_id")
         ) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> assign_chatgpt()
         |> put_flash(
           :info,
           "Workspace access token saved — in use from the next codex conversation"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, chatgpt_error(reason))}
    end
  end

  def handle_event("chatgpt_connect_device", _params, socket) do
    case Fountain.PlatformChatGPT.Device.start(
           notify: self(),
           actor_user_id: socket.assigns.current_user.id
         ) do
      {:ok, pid} ->
        # Monitored, so a task that dies without reporting (a crash, a
        # constraint from a paste in another tab) frees the button.
        ref = Process.monitor(pid)
        {:noreply, assign(socket, :device, %{state: :starting, ref: ref})}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not start the device flow: #{inspect(reason)}")}
    end
  end

  def handle_event("chatgpt_disconnect", _params, socket) do
    :ok = ChatGPTAccounts.platform_disconnect(actor_user_id: socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign_chatgpt()
     |> assign(:device, nil)
     |> put_flash(:info, "ChatGPT account disconnected")}
  end

  @impl true
  def handle_info({:platform_chatgpt_device, {:code, code}}, socket) do
    {:noreply,
     assign(
       socket,
       :device,
       Map.merge(socket.assigns.device || %{}, %{state: :waiting, code: code})
     )}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    case socket.assigns.device do
      %{ref: ^ref} when reason != :normal ->
        {:noreply,
         socket
         |> assign(:device, nil)
         |> assign_chatgpt()
         |> put_flash(:error, "Device sign-in stopped: #{inspect(reason)}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:platform_chatgpt_device, {:connected, _status}}, socket) do
    {:noreply,
     socket
     |> assign(:device, nil)
     |> assign_chatgpt()
     |> put_flash(:info, "ChatGPT account connected")}
  end

  def handle_info({:platform_chatgpt_device, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:device, nil)
     |> put_flash(:error, "Device sign-in failed: #{chatgpt_error(reason)}")}
  end

  defp assign_chatgpt(socket), do: assign(socket, :chatgpt, ChatGPTAccounts.platform_status())

  defp chatgpt_error(:invalid_auth_json), do: "That is not an auth.json codex wrote"

  defp chatgpt_error(:not_a_chatgpt_login),
    do:
      "That auth.json must explicitly set auth_mode to chatgpt. " <>
        "Sign in again with Codex 0.93.0 or newer using file storage, then paste the new auth.json."

  defp chatgpt_error(:no_refresh_token), do: "That sign-in carries no refresh token"
  defp chatgpt_error(:invalid_id_token), do: "That sign-in carries no account id"
  defp chatgpt_error(:invalid_token), do: "Paste one token with no spaces"

  defp chatgpt_error(:no_account_id),
    do: "Enter the workspace's account id beside an opaque token; codex sends it on every request"

  defp chatgpt_error(:abandoned), do: "the page that asked for the code went away"
  defp chatgpt_error(:device_timeout), do: "the code was not approved within fifteen minutes"
  defp chatgpt_error(other), do: inspect(other)

  defp assign_keys(socket) do
    socket
    |> assign(:keys, PlatformInference.status())
    |> assign(:ceiling_cents, PlatformInference.daily_ceiling_cents())
    |> assign(:spent_today_cents, Fountain.Billing.platform_inference_spend_today())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Inference" current={:inference} credits_enabled={@credits_enabled}>
        <:subtitle>
          The keys Fountain runs a tenant on when they have none of their own. A key set here
          wins over its environment variable and needs no restart.
        </:subtitle>
      </.admin_header>

      <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3 text-sm space-y-1">
        <div class="font-medium">Daily ceiling</div>
        <div class="text-zinc-700">
          <span class="font-semibold tabular-nums">
            {Fountain.Credits.format_cents(@ceiling_cents)}
          </span>
          across every tenant per UTC day (<code class="text-xs">PLATFORM_INFERENCE_DAILY_CENTS</code>).
          <span :if={@spent_today_cents != nil}>
            Spent today:
            <span class="font-semibold tabular-nums">
              {Fountain.Credits.format_cents(@spent_today_cents)}
            </span>
          </span>
          <span :if={@spent_today_cents == nil} class="text-zinc-500">
            Credits are off, so nothing is counted against it.
          </span>
        </div>
      </div>

      <section class="space-y-3">
        <div :for={key <- @keys} class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="space-y-1">
              <div class="font-medium">{provider_label(key.provider)}</div>
              <div class="text-sm text-zinc-700">
                <.source key={key} />
              </div>
            </div>
            <span class={[
              "text-xs px-2 py-0.5 rounded border",
              source_badge_class(key.source)
            ]}>
              {source_label(key.source)}
            </span>
          </div>

          <div class="mt-3 flex flex-wrap items-end gap-2">
            <form phx-submit="set_key" class="flex flex-wrap items-end gap-2">
              <input type="hidden" name="provider" value={key.provider} />
              <label class="block text-xs text-zinc-500">
                New key
                <input
                  type="password"
                  name="value"
                  autocomplete="off"
                  spellcheck="false"
                  placeholder={placeholder(key.provider)}
                  class="block mt-1 w-80 max-w-full rounded border-zinc-300 text-sm font-mono"
                />
              </label>
              <button
                type="submit"
                class="px-3 py-1.5 text-sm rounded bg-zinc-900 text-white hover:bg-zinc-700"
              >
                Save
              </button>
            </form>
            <button
              :if={key.source in [:stored, :undecryptable]}
              type="button"
              phx-click="clear_key"
              phx-value-provider={key.provider}
              data-confirm={"Clear the stored #{provider_label(key.provider)} key? The provider falls back to #{key.env_var}, or to off if that is blank."}
              class="px-3 py-1.5 text-sm rounded border border-zinc-300 hover:border-red-400 hover:text-red-700"
            >
              Clear
            </button>
          </div>
        </div>
      </section>

      <p class="text-xs text-zinc-500">
        A tenant's own credential always wins over these. Tokens on a platform key burn the
        tenant's credit at the provider's list price; the finance page shows the total.
      </p>

      <section class="bg-white rounded shadow border border-zinc-200 px-4 py-3 space-y-3">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="space-y-1">
            <div class="font-medium">ChatGPT account (codex)</div>
            <div class="text-sm text-zinc-700">
              <.chatgpt_status chatgpt={@chatgpt} />
            </div>
          </div>
          <span class={["text-xs px-2 py-0.5 rounded border", chatgpt_badge_class(@chatgpt)]}>
            {chatgpt_label(@chatgpt)}
          </span>
        </div>

        <p class="text-xs text-zinc-500">
          A codex agent whose tenant has no OpenAI key runs on this sign-in, before the OpenAI
          platform key. Fountain holds the refresh token and renews it; a sandbox sees only a
          placeholder. A ChatGPT Business or Enterprise workspace access token is the
          sanctioned credential; a personal sign-in shares one subscription across every
          tenant and is an operator's own risk.
        </p>

        <div :if={@device} class="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm">
          <div :if={@device.state == :starting}>Asking ChatGPT for a device code…</div>
          <div :if={@device.state == :waiting} class="space-y-1">
            <div>
              Open
              <a href={@device.code.verification_url} target="_blank" rel="noopener" class="underline">{@device.code.verification_url}</a>
              and enter the code <code class="font-mono text-base font-semibold">{@device.code.user_code}</code>.
            </div>
            <div class="text-xs text-zinc-600">
              Waiting for approval. The code expires in fifteen minutes; device-code sign-in must be
              enabled in the account's ChatGPT security settings.
            </div>
          </div>
        </div>

        <div class="flex flex-wrap items-start gap-4">
          <button
            type="button"
            phx-click="chatgpt_connect_device"
            disabled={@device != nil}
            class="px-3 py-1.5 text-sm rounded bg-zinc-900 text-white hover:bg-zinc-700 disabled:opacity-50"
          >
            Connect with a device code
          </button>

          <form phx-submit="chatgpt_paste" class="flex flex-wrap items-end gap-2">
            <label class="block text-xs text-zinc-500">
              Paste auth.json from a fresh Codex 0.93.0 or newer ChatGPT sign-in.
              Use file storage as described in <a
                href="/docs/configuration#the-chatgpt-account-for-the-codex-runtime"
                class="link"
              >the configuration guide</a>. <textarea
                name="auth_json"
                rows="3"
                autocomplete="off"
                spellcheck="false"
                placeholder={~s({"auth_mode":"chatgpt","tokens":{...}})}
                class="block mt-1 w-96 max-w-full rounded border-zinc-300 text-xs font-mono"
              ></textarea>
            </label>
            <button
              type="submit"
              class="px-3 py-1.5 text-sm rounded border border-zinc-300 hover:border-zinc-500"
            >
              Connect from file
            </button>
          </form>

          <form phx-submit="chatgpt_workspace_token" class="flex flex-wrap items-end gap-2">
            <label class="block text-xs text-zinc-500">
              Workspace access token
              <input
                type="password"
                name="value"
                autocomplete="off"
                spellcheck="false"
                placeholder="CODEX_ACCESS_TOKEN"
                class="block mt-1 w-64 max-w-full rounded border-zinc-300 text-sm font-mono"
              />
            </label>
            <label class="block text-xs text-zinc-500">
              Expires on
              <input
                type="date"
                name="expires_on"
                class="block mt-1 rounded border-zinc-300 text-sm"
              />
            </label>
            <label class="block text-xs text-zinc-500">
              Account id
              <input
                type="text"
                name="account_id"
                autocomplete="off"
                spellcheck="false"
                class="block mt-1 w-48 max-w-full rounded border-zinc-300 text-sm font-mono"
              />
            </label>
            <button
              type="submit"
              class="px-3 py-1.5 text-sm rounded border border-zinc-300 hover:border-zinc-500"
            >
              Save token
            </button>
          </form>

          <button
            :if={@chatgpt != :not_connected}
            type="button"
            phx-click="chatgpt_disconnect"
            data-confirm="Disconnect the ChatGPT account? Codex conversations with no tenant key fall back to the OpenAI platform key, or to no credential."
            class="px-3 py-1.5 text-sm rounded border border-zinc-300 hover:border-red-400 hover:text-red-700"
          >
            Disconnect
          </button>
        </div>
      </section>
    </div>
    """
  end

  attr :chatgpt, :any, required: true

  defp chatgpt_status(%{chatgpt: :not_connected} = assigns) do
    ~H"""
    Not connected. Codex agents with no tenant key use the OpenAI platform key, or nothing.
    """
  end

  defp chatgpt_status(%{chatgpt: %{status: "active"}} = assigns) do
    ~H"""
    Connected as
    <span class="font-medium">{@chatgpt.account_email || @chatgpt.account_id || "workspace"}</span>
    ({@chatgpt.plan_type || "unknown plan"}){if @chatgpt.updated_by,
      do: ", by #{@chatgpt.updated_by}"}. Last renewed {format_ts(@chatgpt.last_refreshed_at)}{if @chatgpt.access_expires_at,
      do: "; the access token expires #{format_ts(@chatgpt.access_expires_at)}"}.
    <span :if={@chatgpt.exhausted_until} class="block mt-1 text-amber-800">
      The account has hit its Codex usage limit until {format_ts(@chatgpt.exhausted_until)} UTC.
      Until then, new codex conversations on a new sandbox run on the OpenAI platform key when one
      is set, billed per token under the daily ceiling. Existing persistent homes and their
      conversations stay on the source they were bound to, here and again after the reset:
      launches onto them fail with codex_inference_conflict until the home is reset.
    </span>
    """
  end

  defp chatgpt_status(%{chatgpt: %{status: "revoked"}} = assigns) do
    ~H"""
    Sign-in lost: the auth server refused the refresh token
    (<code class="font-mono">{@chatgpt.revoked_reason}</code>). Reconnect.
    """
  end

  defp chatgpt_status(%{chatgpt: %{status: "expired"}} = assigns) do
    ~H"""
    The token expired{if @chatgpt.access_expires_at,
      do: " on #{format_ts(@chatgpt.access_expires_at)}"}. Reconnect, or paste a new one.
    """
  end

  defp chatgpt_label(:not_connected), do: "not connected"
  defp chatgpt_label(%{status: "active", exhausted_until: %DateTime{}}), do: "usage limit"
  defp chatgpt_label(%{status: "active", kind: "workspace_token"}), do: "workspace token"
  defp chatgpt_label(%{status: "active"}), do: "connected"
  defp chatgpt_label(%{status: "revoked"}), do: "revoked"
  defp chatgpt_label(%{status: "expired"}), do: "expired"

  defp chatgpt_badge_class(:not_connected), do: "bg-zinc-100 text-zinc-500 border-zinc-200"

  defp chatgpt_badge_class(%{status: "active", exhausted_until: %DateTime{}}),
    do: "bg-amber-100 text-amber-800 border-amber-200"

  defp chatgpt_badge_class(%{status: "active"}),
    do: "bg-green-100 text-green-800 border-green-200"

  defp chatgpt_badge_class(%{status: "revoked"}), do: "bg-red-100 text-red-700 border-red-200"

  defp chatgpt_badge_class(%{status: "expired"}),
    do: "bg-amber-100 text-amber-800 border-amber-200"

  attr :key, :map, required: true

  defp source(%{key: %{source: :stored}} = assigns) do
    ~H"""
    Set here{if @key.updated_at, do: " on #{format_ts(@key.updated_at)}"}{if @key.updated_by,
      do: " by #{@key.updated_by}"}. Ends in <code class="font-mono">…{@key.hint}</code>.
    """
  end

  defp source(%{key: %{source: :environment}} = assigns) do
    ~H"""
    From <code class="font-mono">{@key.env_var}</code>
    in the environment. Ends in <code class="font-mono">…{@key.hint}</code>. Saving a key here overrides it.
    """
  end

  defp source(%{key: %{source: :undecryptable}} = assigns) do
    ~H"""
    A key is stored but does not decrypt under the current <code class="font-mono">MASTER_SECRETS_KEY</code>. Set it again, or clear it to fall back
    to <code class="font-mono">{@key.env_var}</code>.
    """
  end

  defp source(assigns) do
    ~H"""
    Not set. Tenants must bring their own credential for this provider, or set <code class="font-mono">{@key.env_var}</code>.
    """
  end

  defp provider_label("anthropic"), do: "Anthropic"
  defp provider_label("openai"), do: "OpenAI"
  defp provider_label("google"), do: "Google"
  defp provider_label(other), do: other

  defp placeholder("anthropic"), do: "sk-ant-…"
  defp placeholder("openai"), do: "sk-…"
  defp placeholder("google"), do: "AIza…"
  defp placeholder(_), do: ""

  defp source_label(:stored), do: "set in admin"
  defp source_label(:environment), do: "from environment"
  defp source_label(:undecryptable), do: "cannot decrypt"
  defp source_label(:none), do: "not set"

  defp source_badge_class(:stored), do: "bg-green-100 text-green-800 border-green-200"
  defp source_badge_class(:environment), do: "bg-blue-100 text-blue-800 border-blue-200"
  defp source_badge_class(:undecryptable), do: "bg-red-100 text-red-700 border-red-200"
  defp source_badge_class(:none), do: "bg-zinc-100 text-zinc-500 border-zinc-200"
end
