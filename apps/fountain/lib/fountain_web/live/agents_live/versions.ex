defmodule FountainWeb.AgentsLive.Versions do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.Agents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user_id = socket.assigns.current_user.id
    agent = Agents.get_agent!(id, user_id)

    {:ok,
     socket
     |> assign(:page_title, "History — #{agent.name}")
     |> assign(:user_id, user_id)
     |> assign(:agent, agent)
     |> load_versions()}
  end

  @impl true
  def handle_event("rollback", %{"version" => version}, socket) do
    %{agent: agent, user_id: user_id} = socket.assigns

    with {version, ""} <- Integer.parse(version),
         %_{} = target <- Agents.get_agent_version(agent.id, version, user_id),
         {:ok, agent} <-
           Agents.rollback_agent(agent, target, FountainWeb.Audited.attribution(socket)) do
      {:noreply,
       socket
       |> assign(:agent, agent)
       |> load_versions()
       |> put_flash(:info, "Rolled back to version #{version}")}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        # The old config is re-validated on the way back in, so a snapshot
        # that references since-removed infrastructure is refused, not
        # silently restored.
        {:noreply, put_flash(socket, :error, "Cannot roll back: #{rollback_error(cs)}")}

      # Integer.parse :error / trailing garbage, or no such version (nil).
      # Same user-facing answer either way.
      _ ->
        {:noreply, put_flash(socket, :error, "Version not found")}
    end
  end

  defp load_versions(socket) do
    versions = Agents.list_agent_versions(socket.assigns.agent.id, socket.assigns.user_id)

    # Each version is paired with its predecessor so the template renders a
    # per-version diff without recomputing neighbours.
    diffed = Enum.zip(versions, Enum.drop(versions, 1) ++ [nil])

    assign(socket, :versions, diffed)
  end

  defp rollback_error(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {k, msgs} -> "#{k}: #{Enum.join(msgs, ", ")}" end)
  end

  defp changed_fields(%{config: config}, nil), do: Enum.sort(Map.keys(config))

  defp changed_fields(%{config: config}, %{config: prev}) do
    (Map.keys(config) ++ Map.keys(prev))
    |> Enum.uniq()
    |> Enum.filter(fn key -> Map.get(config, key) != Map.get(prev, key) end)
    |> Enum.sort()
  end

  defp render_value(nil), do: "—"
  defp render_value(value) when is_binary(value), do: value
  defp render_value(value), do: Jason.encode!(value, pretty: true)

  defp current?(socket_versions, version) do
    case socket_versions do
      [{latest, _} | _] -> latest.version == version
      _ -> false
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">History — {@agent.name}</h1>
        <.link navigate={~p"/agents/#{@agent.id}/edit"}>
          <.button variant="secondary">Back to agent</.button>
        </.link>
      </div>

      <p class="text-sm text-zinc-500">
        A version is written on every config change. Rolling back applies that
        version's config as a new edit — history is never rewritten.
      </p>

      <div
        :for={{version, previous} <- @versions}
        class="bg-white rounded shadow border border-zinc-200 p-6 space-y-3"
        id={"agent-version-#{version.version}"}
      >
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-3">
            <span class="font-semibold">Version {version.version}</span>
            <span :if={current?(@versions, version.version)} class="text-xs text-emerald-600">
              current
            </span>
            <span class="text-xs text-zinc-400">
              {Calendar.strftime(version.inserted_at, "%Y-%m-%d %H:%M UTC")}
            </span>
          </div>
          <.button
            :if={not current?(@versions, version.version)}
            variant="secondary"
            phx-click="rollback"
            phx-value-version={version.version}
            data-confirm={"Apply version #{version.version}'s config as a new edit?"}
          >
            Roll back to this
          </.button>
        </div>

        <div :if={previous == nil} class="text-sm text-zinc-500">
          Initial version.
        </div>

        <table :if={previous != nil} class="w-full text-sm">
          <thead>
            <tr class="text-left text-xs text-zinc-400">
              <th class="py-1 pr-4 w-40">Field</th>
              <th class="py-1 pr-4">Before</th>
              <th class="py-1">After</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={field <- changed_fields(version, previous)}
              class="border-t border-zinc-100 align-top"
            >
              <td class="py-2 pr-4 font-mono text-xs">{field}</td>
              <td class="py-2 pr-4">
                <pre class="whitespace-pre-wrap break-all text-xs text-rose-700 bg-rose-50 rounded p-2">{render_value(Map.get(previous.config, field))}</pre>
              </td>
              <td class="py-2">
                <pre class="whitespace-pre-wrap break-all text-xs text-emerald-700 bg-emerald-50 rounded p-2">{render_value(Map.get(version.config, field))}</pre>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
