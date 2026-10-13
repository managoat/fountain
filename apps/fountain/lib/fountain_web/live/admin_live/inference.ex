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
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.PlatformInference

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Inference")
     |> assign_keys()}
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

  defp assign_keys(socket) do
    socket
    |> assign(:keys, PlatformInference.status())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Inference" current={:inference}>
        <:subtitle>
          The keys Fountain runs a tenant on when they have none of their own. A key set here
          wins over its environment variable and needs no restart.
        </:subtitle>
      </.admin_header>

      <section class="space-y-3">
        <div
          :for={key <- @keys}
          class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] px-4 py-3"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="space-y-1">
              <div class="font-medium">{provider_label(key.provider)}</div>
              <div class="text-sm text-[var(--color-text-primary)]">
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
              <label class="block text-xs text-[var(--color-text-secondary)]">
                New key
                <input
                  type="password"
                  name="value"
                  autocomplete="off"
                  spellcheck="false"
                  placeholder={placeholder(key.provider)}
                  class="block mt-1 w-80 max-w-full rounded border-[var(--color-border-strong)] bg-[var(--color-bg-1)] text-sm font-mono text-[var(--color-text-primary)]"
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
              class="px-3 py-1.5 text-sm rounded border border-[var(--color-border-strong)] hover:border-red-400 hover:text-[var(--color-error-text)]"
            >
              Clear
            </button>
          </div>
        </div>
      </section>

      <p class="text-xs text-[var(--color-text-secondary)]">
        A tenant's own credential always wins over these. Nothing limits what a platform key
        spends: every tenant without a credential of their own runs on it, billed to this
        deployment's provider account.
      </p>
    </div>
    """
  end

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

  defp source_badge_class(:none),
    do: "bg-[var(--color-bg-2)] text-[var(--color-text-secondary)] border-[var(--color-border)]"
end
