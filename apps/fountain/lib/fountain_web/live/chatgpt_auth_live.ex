defmodule FountainWeb.ChatGPTAuthLive do
  @moduledoc "Server-side ChatGPT subscription authentication, linked from the account app."
  use FountainWeb, :live_view
  alias FountainWeb.ChatGPTSubscriptionCard

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> FountainWeb.Audited.put_client_ip()
     |> assign(:page_title, "ChatGPT sign-in")
     |> ChatGPTSubscriptionCard.assign_card(socket.assigns.current_user.id)}
  end

  def handle_event(event, params, socket),
    do: ChatGPTSubscriptionCard.handle_event(event, params, socket)

  def handle_info(message, socket), do: ChatGPTSubscriptionCard.handle_poll(message, socket)

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl space-y-6 py-8">
      <h1 class="text-2xl font-semibold">ChatGPT subscription</h1>
      <ChatGPTSubscriptionCard.card
        sub={@chatgpt_sub}
        device={@chatgpt_device}
        message={@chatgpt_message}
      />
      <.link href={~p"/account/inference-credentials"}>Back to account</.link>
    </div>
    """
  end
end
