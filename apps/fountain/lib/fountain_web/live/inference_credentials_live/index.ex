defmodule FountainWeb.InferenceCredentialsLive.Index do
  @moduledoc """
  Settings page for per-user inference provider credentials (BYO, ADR 0008).

  One row per provider (Anthropic, Claude OAuth, OpenAI, Gemini). Each row
  shows set/not-set status; the form accepts a paste of the credential and
  validates by pinging the provider before persisting (encrypted with the
  per-tenant DEK). An account holds one record of those four (ADR 0053's
  2026-10-14 addendum).

  Plaintext is never displayed after save.
  """

  use FountainWeb, :live_view

  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Validator
  alias FountainWeb.ChatGPTSubscriptionCard

  @providers [
    {:anthropic_api_key, "Anthropic API key", "ANTHROPIC_API_KEY",
     "For the Claude runtime (when no OAuth is set). Get from console.anthropic.com."},
    {:claude_code_oauth_token, "Claude OAuth token", "CLAUDE_CODE_OAUTH_TOKEN",
     "Preferred for the Claude runtime — bills against your Claude.ai Pro/Team plan instead of metered API. Generate via 'claude setup-token'."},
    {:openai_api_key, "OpenAI API key", "OPENAI_API_KEY",
     "For the codex runtime. Get from platform.openai.com/api-keys."},
    {:gemini_api_key, "Gemini API key", "GEMINI_API_KEY",
     "For the gemini runtime. Get from aistudio.google.com/apikey."}
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Inference credentials")
     |> assign(:user_id, user.id)
     |> assign(:providers, @providers)
     |> assign(:provider_messages, %{})
     |> ChatGPTSubscriptionCard.assign_card({:user, user.id})
     |> load_status()}
  end

  defp load_status(socket),
    do: assign(socket, :status, InferenceCredentials.status_for_user(socket.assigns.user_id))

  @impl true
  def handle_event("chatgpt_" <> _ = event, params, socket),
    do: ChatGPTSubscriptionCard.handle_event(event, params, socket)

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
        case write(socket, dek, provider, nil) do
          {:ok, _} ->
            {:noreply,
             socket
             |> load_status()
             |> put_provider_message(provider, :info, "Credential cleared.")}

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

  defp persist_and_flash(socket, provider, value) do
    with {:ok, dek} <- load_dek(socket.assigns.user_id),
         {:ok, _cred} <- write(socket, dek, provider, value) do
      {:noreply,
       socket
       |> load_status()
       |> put_provider_message(provider, :info, "Saved and validated.")}
    else
      {:error, reason} ->
        {:noreply,
         put_provider_message(socket, provider, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  defp write(socket, dek, provider, value) do
    InferenceCredentials.put_credential(
      socket.assigns.user_id,
      dek,
      provider,
      value,
      FountainWeb.Audited.attribution(socket)
    )
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
  def handle_info({:chatgpt_poll, _ref} = message, socket),
    do: ChatGPTSubscriptionCard.handle_poll(message, socket)

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

      <ChatGPTSubscriptionCard.card
        owner={@chatgpt_owner}
        sub={@chatgpt_sub}
        device={@chatgpt_device}
        message={@chatgpt_message}
        brokered?={@chatgpt_brokered?}
      />

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
