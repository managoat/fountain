defmodule FountainWeb.ChatGPTSubscriptionCard do
  @moduledoc """
  The ChatGPT subscription card (ADR 0070): a user's on
  `/account/inference-credentials`, the deployment's on `/admin/inference`.

  Not a LiveComponent: the device-code sign-in is polled by the page's own
  LiveView process (`Process.send_after/3`), and a component cannot receive
  messages. Each page calls `assign_card/2` at mount and forwards
  `"chatgpt_*"` events and `{:chatgpt_poll, ref}` messages to `handle_poll/2`. The device
  code lives in the socket's assigns and nowhere else, so leaving the page
  abandons the sign-in.
  """

  use FountainWeb, :html

  alias Fountain.ChatGPT
  alias Fountain.ChatGPT.OAuth

  # Codex gives a device code fifteen minutes; so does this.
  @device_deadline_ms 15 * 60 * 1_000

  @doc "Assign the card for `owner`: `{:user, user_id}` or `:platform`."
  def assign_card(socket, owner) do
    socket
    |> assign(:chatgpt_owner, owner)
    |> assign(:chatgpt_device, nil)
    |> assign(:chatgpt_message, nil)
    |> load()
  end

  defp load(socket) do
    socket
    |> assign(:chatgpt_sub, ChatGPT.get(socket.assigns.chatgpt_owner))
    |> assign(:chatgpt_brokered?, Fountain.Broker.configured?())
  end

  def handle_event("chatgpt_device_start", _params, socket) do
    case OAuth.device_start() do
      {:ok, started} ->
        ref = make_ref()
        Process.send_after(self(), {:chatgpt_poll, ref}, started.interval * 1_000)

        device =
          started
          |> Map.put(:ref, ref)
          |> Map.put(:deadline, System.monotonic_time(:millisecond) + @device_deadline_ms)

        {:noreply, socket |> assign(:chatgpt_device, device) |> assign(:chatgpt_message, nil)}

      {:error, _reason} ->
        {:noreply, message(socket, :error, "OpenAI did not start a sign-in. Try again shortly.")}
    end
  end

  def handle_event("chatgpt_device_cancel", _params, socket),
    do: {:noreply, assign(socket, :chatgpt_device, nil)}

  def handle_event("chatgpt_paste", %{"auth_json" => json}, socket) do
    case ChatGPT.connect_auth_json(socket.assigns.chatgpt_owner, json, attribution(socket)) do
      {:ok, _sub} ->
        {:noreply, socket |> load() |> message(:info, "ChatGPT subscription linked.")}

      {:error, reason} ->
        {:noreply, message(socket, :error, paste_error(reason))}
    end
  end

  def handle_event("chatgpt_disconnect", _params, socket) do
    :ok = ChatGPT.disconnect(socket.assigns.chatgpt_owner, attribution(socket))

    {:noreply,
     socket
     |> load()
     |> message(:info, "Disconnected. Conversations on it stop at their next prompt.")}
  end

  @doc "One poll of the open device-code sign-in; a poll for a closed one is dropped."
  def handle_poll(
        {:chatgpt_poll, ref},
        %{assigns: %{chatgpt_device: %{ref: ref} = device}} = socket
      ) do
    cond do
      System.monotonic_time(:millisecond) >= device.deadline ->
        {:noreply,
         socket
         |> assign(:chatgpt_device, nil)
         |> message(:error, "The code expired before it was approved. Start again.")}

      true ->
        poll(socket, device)
    end
  end

  def handle_poll({:chatgpt_poll, _stale}, socket), do: {:noreply, socket}

  defp poll(socket, device) do
    with {:ok, grant} <- OAuth.device_poll(device.device_auth_id, device.user_code),
         {:ok, tokens} <- OAuth.device_exchange(grant),
         {:ok, _sub} <-
           ChatGPT.connect(
             socket.assigns.chatgpt_owner,
             tokens,
             [method: "device_code"] ++ attribution(socket)
           ) do
      {:noreply,
       socket
       |> assign(:chatgpt_device, nil)
       |> load()
       |> message(:info, "ChatGPT subscription linked.")}
    else
      :pending ->
        Process.send_after(self(), {:chatgpt_poll, device.ref}, device.interval * 1_000)
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:chatgpt_device, nil)
         |> message(:error, "The sign-in did not complete. Start again.")}
    end
  end

  defp attribution(socket) do
    case socket.assigns.chatgpt_owner do
      :platform -> [actor_user_id: socket.assigns.current_user.id]
      {:user, _} -> FountainWeb.Audited.attribution(socket)
    end
  end

  defp message(socket, kind, text), do: assign(socket, :chatgpt_message, {kind, text})

  defp paste_error(:not_a_chatgpt_login),
    do: "That file is not a ChatGPT sign-in. Run `codex login` and choose ChatGPT."

  defp paste_error(:no_refresh_token),
    do: "That file has no refresh token. Run `codex login` again."

  defp paste_error(:invalid_id_token), do: "That file's id_token names no ChatGPT account."
  defp paste_error(_), do: "That is not a codex auth.json. Paste the whole file."

  attr :owner, :any, required: true
  attr :sub, :any, required: true
  attr :device, :any, required: true
  attr :message, :any, required: true
  attr :brokered?, :boolean, required: true

  def card(assigns) do
    ~H"""
    <div
      id="chatgpt-subscription"
      class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-5 space-y-3"
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <h2 class="text-base font-medium">
            {if @owner == :platform,
              do: "The deployment's ChatGPT subscription",
              else: "ChatGPT subscription"}
          </h2>
          <p class="text-xs text-[var(--color-text-secondary)] mt-1">
            <%= if @owner == :platform do %>
              Codex runs on this for every account that has not linked its own, ahead of any OpenAI API key.
            <% else %>
              Codex runs on your ChatGPT plan when one is linked, ahead of any OpenAI API key. Without one it uses the deployment's, if an admin linked it.
            <% end %>
            The token stays with Fountain's egress broker and never enters a sandbox.
          </p>
        </div>
        <span
          :if={@sub}
          class={[
            "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
            if(@sub.status == "active",
              do: "bg-emerald-100 text-emerald-800",
              else: "bg-rose-100 text-rose-800"
            )
          ]}
        >
          {if @sub.status == "active", do: "Linked", else: "Reconnect"}
        </span>
      </div>

      <p :if={not @brokered?} class="text-xs text-amber-700">
        This deployment has no egress broker, so a subscription is not used: codex would need the token inside the sandbox.
      </p>

      <div :if={@sub} class="text-sm space-y-1">
        <p>
          Plan: <strong>{@sub.plan_type || "unknown"}</strong>. Last refreshed {Calendar.strftime(
            @sub.last_refreshed_at,
            "%Y-%m-%d %H:%M UTC"
          )}.
        </p>
        <p :if={@sub.status == "revoked"} class="text-rose-700">
          OpenAI refused the sign-in ({@sub.revoked_reason}). Link it again below.
        </p>
      </div>

      <div class="flex flex-wrap gap-2">
        <.button type="button" phx-click="chatgpt_device_start">
          {if @sub, do: "Link again", else: "Link with a code"}
        </.button>
        <.button
          :if={@sub}
          type="button"
          variant="secondary"
          phx-click="chatgpt_disconnect"
          data-confirm="Disconnect this ChatGPT subscription? Conversations on it stop at their next prompt."
        >
          Disconnect
        </.button>
      </div>

      <details class="text-sm">
        <summary class="cursor-pointer text-[var(--color-text-secondary)]">
          Or paste the auth.json from <code class="font-mono">codex login</code>
        </summary>
        <form id="chatgpt-paste" phx-submit="chatgpt_paste" class="mt-2 space-y-2">
          <textarea
            name="auth_json"
            rows="4"
            autocomplete="off"
            spellcheck="false"
            placeholder="Contents of ~/.codex/auth.json"
            class="w-full rounded-md border border-[var(--color-border)] bg-[var(--color-bg-2)] px-3 py-2 text-xs font-mono"
          ></textarea>
          <p class="text-xs text-[var(--color-text-secondary)]">
            Linking with a code is better. A pasted file shares one refresh token with the machine it came from, and whichever side refreshes second can be signed out: run
            <code class="font-mono">codex login</code>
            there again afterwards.
          </p>
          <.button type="submit" variant="secondary">Link</.button>
        </form>
      </details>

      <p
        :if={@message}
        class={[
          "text-xs",
          if(elem(@message, 0) == :info, do: "text-emerald-700", else: "text-rose-700")
        ]}
      >
        {elem(@message, 1)}
      </p>

      <div :if={@device} id="chatgpt-device" class="relative z-50" role="dialog" aria-modal="true">
        <div class="fixed inset-0 bg-black/50" aria-hidden="true"></div>
        <div class="fixed inset-0 flex items-center justify-center p-4">
          <div class="w-full max-w-md rounded-xl shadow-xl bg-[var(--color-bg-1)] border border-[var(--color-border)] p-6 space-y-4">
            <h2 class="text-base font-semibold">Sign in to ChatGPT</h2>
            <p class="text-sm">
              Open <a href={@device.verification_url} target="_blank" rel="noopener" class="underline">{@device.verification_url}</a>, sign in, and enter this code:
            </p>
            <p id="chatgpt-user-code" class="text-2xl font-mono tracking-widest text-center">
              {@device.user_code}
            </p>
            <p class="text-xs text-[var(--color-text-secondary)]">
              This page is waiting for the approval. The code is good for fifteen minutes.
            </p>
            <div class="flex justify-end">
              <.button type="button" variant="secondary" phx-click="chatgpt_device_cancel">
                Cancel
              </.button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
