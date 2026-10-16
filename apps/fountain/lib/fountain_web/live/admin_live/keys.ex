defmodule FountainWeb.AdminLive.Keys do
  @moduledoc "Session-authenticated key management; ordinary OAuth never grants admin scope."
  use FountainWeb, :live_view
  import FountainWeb.AdminLive.Shell

  def mount(_params, _session, socket) do
    {:ok, socket |> FountainWeb.Audited.put_client_ip() |> assign(:page_title, "Admin keys")}
  end

  def handle_info({:account_flash, kind, msg}, socket),
    do: {:noreply, put_flash(socket, kind, msg)}

  def render(assigns) do
    ~H"""
    <.admin_header title="Admin keys" current={:keys} />
    <p class="my-4">
      Admin keys grant operator access. Ordinary account app tokens cannot mint them.
    </p>
    <.live_component
      module={FountainWeb.AdminLive.ApiKeys}
      id="admin-api-keys"
      current_user={@current_user}
      client_ip={@client_ip}
    />
    """
  end
end
