defmodule FountainWeb.AgentsLive.Form do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.{Agents, AvatarGenerator, Environments, InferenceCredentials}
  alias Fountain.Agents.Agent
  alias Managoat.ACP.Permissions
  alias Managoat.Runtimes.ACP
  alias Managoat.Runtimes.Model
  alias Fountain.Agents.ModelCatalog

  @impl true
  def mount(params, _session, socket) do
    user_id = socket.assigns.current_user.id
    envs = Environments.list_environments(user_id)
    {agent, action} = load(params, user_id)

    {:ok,
     socket
     |> assign(:page_title, page_title(action))
     |> assign(:user_id, user_id)
     |> assign(
       :missing_credential,
       InferenceCredentials.missing_for_model(user_id, credential_model(agent))
     )
     |> assign(:credential_message, nil)
     |> assign(:envs, envs)
     |> assign(:sandbox_providers, Fountain.SandboxProviders.enabled_providers())
     |> assign(:action, action)
     |> assign(:agent, agent)
     |> assign(:form, agent_to_form(agent))
     |> assign(:errors, %{})
     |> assign(:skills, agent_to_skill_list(agent.skills || []))
     |> assign(:mcp_servers, agent_to_mcp_server_list(agent.mcp_servers || %{}))
     |> assign(:connections, connections_for(user_id))
     |> assign(:avatar_tab, :upload)
     |> assign(:avatar_base, "robot")
     |> assign(:avatar_mood, "serious")
     |> assign(:generating_avatar, false)
     |> assign(:generated_avatar_data, nil)
     |> assign(:generated_avatar_preview, nil)
     |> assign(:avatar_error, nil)
     |> allow_upload(:avatar,
       accept: ~w(image/jpeg image/png image/gif image/webp),
       max_entries: 1,
       max_file_size: 5_242_880
     )}
  end

  defp load(%{"id" => id}, user_id), do: {Agents.get_agent!(id, user_id), :edit}
  defp load(_, _user_id), do: {%Agent{}, :new}

  defp page_title(:new), do: "New agent"
  defp page_title(:edit), do: "Edit agent"

  defp agent_to_form(%Agent{} = a) do
    %{
      "name" => a.name || "",
      "description" => a.description || "",
      "system" => a.system || "",
      "model" => a.model || default_model(a.runtime),
      "runtime" => a.runtime || "claude",
      "runtime_command" => a.runtime_command || "",
      "sandbox_provider" => a.sandbox_provider || "",
      "sandbox_mode" => a.sandbox_mode || "ephemeral",
      "environment_id" => a.environment_id || "",
      "permission_default" => Permissions.verdict_for(a.permission_policy, nil),
      "permission_kinds" => permission_kind_form(a.permission_policy)
    }
  end

  # The per-kind half of the policy, as the form holds it: every ACP kind, with
  # "" meaning "whatever the default says". Only the kinds are offered here —
  # a title key matches one invocation of one command on the runtime every
  # agent runs (#958), so a form that invited one would be inviting a rule that
  # never fires.
  defp permission_kind_form(policy) do
    policy = policy || %{}
    Map.new(Permissions.tool_kinds(), fn kind -> {kind, Map.get(policy, kind, "")} end)
  end

  # The other direction: form state back to the map the changeset takes. An
  # empty default plus no overrides is an empty policy rather than
  # `%{"default" => "auto_allow"}`, so an agent nobody has touched keeps the
  # empty map it has always had.
  #
  # `previous` is the policy as stored. The form knows only the tool half, so
  # a key that names something else (`ask_timeout`, #1635) is carried across
  # rather than dropped by a save from a screen that cannot show it.
  defp form_to_permission_policy(params, previous) do
    kinds =
      params
      |> Map.get("permission_kinds", %{})
      |> Enum.filter(fn {_kind, verdict} -> verdict in Permissions.verdicts() end)
      |> Map.new()

    case Map.get(params, "permission_default") do
      verdict when verdict in ["ask", "auto_deny"] -> Map.put(kinds, "default", verdict)
      _ -> kinds
    end
    |> Fountain.PermissionPolicy.keep_reserved(previous)
  end

  defp asks_permission?(runtime), do: ACP.asks_permission?(runtime || "claude")

  # A new agent lands on claude, so it gets claude's model prefilled. An acp
  # agent gets none: the field is optional there and nothing reads it, so a
  # prefilled value would be a suggestion to configure something inert.
  defp default_model("acp"), do: ""
  defp default_model(_runtime), do: "anthropic/claude-sonnet-5"

  # Which model the credential card asks about (#841). A new agent has none
  # yet and lands on claude, so it is asked about claude's default. An acp
  # agent has none and needs none, and asking its owner for an Anthropic key
  # would claim its conversations cannot start until they set one (#1634).
  defp credential_model(agent) do
    cond do
      is_binary(agent.model) -> agent.model
      model_required?(agent.runtime) -> default_model(agent.runtime)
      true -> nil
    end
  end

  defp model_required?(runtime), do: Fountain.RuntimeDispatch.model_required?(runtime || "claude")
  defp command_runtime?(runtime), do: Fountain.RuntimeDispatch.command_required?(runtime)

  # The command belongs to the acp runtime alone, and the changeset refuses it
  # on any other. Sending nil rather than whatever the form last held is what
  # lets someone switch an agent off acp without hitting that refusal.
  defp runtime_command_param(params) do
    if Fountain.RuntimeDispatch.command_required?(params["runtime"]),
      do: params["runtime_command"],
      else: nil
  end

  defp permission_override_count(form) do
    form
    |> Map.get("permission_kinds", %{})
    |> Enum.count(fn {_kind, verdict} -> verdict not in [nil, ""] end)
  end

  defp agent_to_skill_list(skills) do
    Enum.map(skills, fn skill ->
      if Map.has_key?(skill, "content") or Map.has_key?(skill, :content) do
        %{
          "type" => "inline",
          "name" => skill["name"] || skill[:name] || "",
          "content" => skill["content"] || skill[:content] || "",
          "source" => ""
        }
      else
        %{
          "type" => "github",
          "source" => skill["source"] || skill[:source] || "",
          "name" => skill["name"] || skill[:name] || "",
          "content" => ""
        }
      end
    end)
  end

  # Three shapes an entry can have: a stdio server the form edits field by
  # field; a connection (#1178) that names a Google account Fountain holds
  # the credential for; and anything else (an HTTP/SSE server written
  # through the API), carried through untouched so saving the form does not
  # silently drop it.
  defp agent_to_mcp_server_list(mcp_servers) do
    Enum.map(mcp_servers, fn
      {name, %{"connection" => id} = config} when is_binary(id) ->
        %{
          "name" => name,
          "kind" => "connection",
          "connection" => id,
          "url" => config["url"] || "",
          "command" => "",
          "args" => "",
          "env_vars" => []
        }

      {name, %{"command" => _} = config} ->
        stdio_server(name, config)

      {name, config} when is_map(config) and map_size(config) > 0 ->
        %{
          "name" => name,
          "kind" => "raw",
          "raw" => config,
          "command" => "",
          "args" => "",
          "env_vars" => []
        }

      {name, config} ->
        stdio_server(name, config || %{})
    end)
  end

  defp stdio_server(name, config) do
    args_str = (config["args"] || []) |> Enum.join("\n")
    env_vars = (config["env"] || %{}) |> Enum.map(fn {k, v} -> %{"key" => k, "value" => v} end)

    %{
      "name" => name,
      "kind" => "stdio",
      "command" => config["command"] || "",
      "args" => args_str,
      "env_vars" => env_vars
    }
  end

  # The active connections the form can offer, only where connections exist
  # (a brokered account). Elsewhere the select is not rendered. The rollout
  # flag is not asked: naming a connection the account already holds is not
  # connecting a new one, and an agent must stay editable after the flag goes
  # off (#1693).
  defp connections_for(user_id) do
    if Fountain.Connections.manageable_for?(),
      do: Fountain.Connections.active_connections(user_id),
      else: []
  end

  # Each runtime but opencode only reaches one provider, and the changeset
  # rejects a mismatched prefix (#553). Track the selected runtime so the hint
  # can't lead someone into that error.
  defp model_placeholder("codex"), do: "openai/gpt-6-astra"
  defp model_placeholder("gemini"), do: "google/gemini-3.1-pro-preview"
  defp model_placeholder(_runtime), do: "anthropic/claude-sonnet-5"

  # A model id off the curated list is legitimate — new models ship between
  # deploys — so say it will be used rather than flagging it as wrong. Stay
  # quiet while the value is unparseable or the provider is unknown: those are
  # real errors and `error_msg` says so on submit.
  defp unknown_model?(model) do
    case Model.split(model) do
      {nil, nil} -> false
      {provider, _id} -> Model.known_provider?(provider) and not ModelCatalog.known?(model)
    end
  end

  @impl true
  def handle_event("validate", %{"agent" => params}, socket) do
    skills = extract_skills_from_params(params, socket.assigns.skills)
    mcp_servers = extract_mcp_servers_from_params(params, socket.assigns.mcp_servers)

    {:noreply,
     socket
     |> assign(:form, params)
     |> assign(:skills, skills)
     |> assign(:mcp_servers, mcp_servers)
     |> assign(
       :missing_credential,
       # Keyed on the runtime, not only on the model box: picking acp must
       # clear the card in the same render, and the box may still hold the
       # value it had a moment ago (#1634).
       if(model_required?(params["runtime"]),
         do: InferenceCredentials.missing_for_model(socket.assigns.user_id, params["model"]),
         else: nil
       )
     )}
  end

  # The model needs a provider this account has no credential for: collect
  # it right here, the first time it matters (#841), rather than after a
  # conversation fails to start inside the sandbox.
  def handle_event("save_credential", %{"provider" => provider_str, "value" => value}, socket) do
    provider = String.to_existing_atom(provider_str)

    case FountainWeb.InferenceCredentialSave.save(socket, provider, value) do
      {:ok, msg} ->
        {:noreply,
         socket
         |> assign(:credential_message, {:info, msg})
         |> assign(
           :missing_credential,
           InferenceCredentials.missing_for_model(
             socket.assigns.user_id,
             socket.assigns.form["model"]
           )
         )}

      {:error, msg} ->
        {:noreply, assign(socket, :credential_message, {:error, msg})}
    end
  end

  def handle_event("add_skill", _, socket) do
    skills =
      socket.assigns.skills ++
        [%{"type" => "github", "source" => "", "name" => "", "content" => ""}]

    {:noreply, assign(socket, :skills, skills)}
  end

  def handle_event("remove_skill", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    {:noreply, assign(socket, :skills, List.delete_at(socket.assigns.skills, index))}
  end

  def handle_event("set_skill_type", %{"index" => index_str, "type" => type}, socket)
      when type in ["github", "inline"] do
    index = String.to_integer(index_str)
    skills = List.update_at(socket.assigns.skills, index, &Map.put(&1, "type", type))
    {:noreply, assign(socket, :skills, skills)}
  end

  def handle_event("add_mcp_server", _, socket) do
    servers =
      socket.assigns.mcp_servers ++
        [%{"name" => "", "kind" => "stdio", "command" => "", "args" => "", "env_vars" => []}]

    {:noreply, assign(socket, :mcp_servers, servers)}
  end

  def handle_event("remove_mcp_server", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    {:noreply, assign(socket, :mcp_servers, List.delete_at(socket.assigns.mcp_servers, index))}
  end

  def handle_event("add_mcp_env_var", %{"server" => server_idx_str}, socket) do
    server_idx = String.to_integer(server_idx_str)

    servers =
      List.update_at(socket.assigns.mcp_servers, server_idx, fn s ->
        Map.update(s, "env_vars", [%{"key" => "", "value" => ""}], fn evs ->
          evs ++ [%{"key" => "", "value" => ""}]
        end)
      end)

    {:noreply, assign(socket, :mcp_servers, servers)}
  end

  def handle_event(
        "remove_mcp_env_var",
        %{"server" => server_idx_str, "index" => idx_str},
        socket
      ) do
    server_idx = String.to_integer(server_idx_str)
    idx = String.to_integer(idx_str)

    servers =
      List.update_at(socket.assigns.mcp_servers, server_idx, fn s ->
        Map.update(s, "env_vars", [], &List.delete_at(&1, idx))
      end)

    {:noreply, assign(socket, :mcp_servers, servers)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :avatar, ref)}
  end

  def handle_event("remove_avatar", _, socket) do
    agent = socket.assigns.agent

    if agent.id do
      Agents.delete_avatar(agent, FountainWeb.Audited.attribution(socket))
      {:noreply, assign(socket, :agent, %{agent | avatar_media_type: nil})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("switch_avatar_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :avatar_tab, String.to_existing_atom(tab))}
  end

  def handle_event("set_avatar_base", %{"base" => base}, socket)
      when base in ["robot", "human", "alien"] do
    {:noreply, assign(socket, :avatar_base, base)}
  end

  def handle_event("set_avatar_mood", %{"mood" => mood}, socket)
      when mood in ["serious", "casual", "goofy"] do
    {:noreply, assign(socket, :avatar_mood, mood)}
  end

  def handle_event("generate_avatar", _params, socket) do
    user_id = socket.assigns.user_id
    base = socket.assigns.avatar_base
    mood = socket.assigns.avatar_mood

    socket =
      socket
      |> assign(:generating_avatar, true)
      |> assign(:avatar_error, nil)
      |> assign(:generated_avatar_data, nil)
      |> assign(:generated_avatar_preview, nil)

    {:noreply,
     start_async(socket, :generate_avatar, fn ->
       AvatarGenerator.generate(user_id, base, mood)
     end)}
  end

  def handle_event("discard_generated_avatar", _, socket) do
    {:noreply,
     socket
     |> assign(:generated_avatar_data, nil)
     |> assign(:generated_avatar_preview, nil)
     |> assign(:avatar_error, nil)}
  end

  def handle_event("submit", %{"agent" => params}, socket) do
    skills_list = extract_skills_from_params(params, socket.assigns.skills)
    mcp_servers_list = extract_mcp_servers_from_params(params, socket.assigns.mcp_servers)

    with :ok <- validate_skills_list(skills_list),
         :ok <- validate_mcp_servers(mcp_servers_list) do
      skills =
        Enum.map(skills_list, fn s ->
          case s["type"] do
            "github" ->
              m = %{"source" => s["source"] || ""}
              if (s["name"] || "") != "", do: Map.put(m, "name", s["name"]), else: m

            "inline" ->
              %{"name" => s["name"] || "", "content" => s["content"] || ""}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      mcp_map =
        Map.new(mcp_servers_list, fn s -> {s["name"] || "", mcp_server_config(s)} end)
        |> Map.reject(fn {k, _} -> k == "" end)

      attrs =
        params
        |> Map.put("skills", skills)
        |> Map.put("mcp_servers", mcp_map)
        |> Map.put(
          "permission_policy",
          form_to_permission_policy(params, socket.assigns.agent.permission_policy)
        )
        |> Map.put("user_id", socket.assigns.user_id)
        |> Map.put("runtime_command", runtime_command_param(params))
        |> nil_if_blank("environment_id")
        |> nil_if_blank("sandbox_provider")
        |> nil_if_blank("runtime_command")
        # Blank means "no model", which is a legal state on the acp runtime
        # and a "can't be blank" on every other one. Left as "" it would be a
        # format error instead, which points at the wrong thing.
        |> nil_if_blank("model")

      case save(socket, attrs) do
        {:ok, socket} -> {:noreply, socket}
        {:error, socket} -> {:noreply, socket}
      end
    else
      {:error, field, msg} ->
        {:noreply, assign(socket, :errors, %{field => msg})}
    end
  end

  @impl true
  def handle_async(:generate_avatar, {:ok, {:ok, data}}, socket) do
    preview = "data:image/png;base64," <> Base.encode64(data)

    {:noreply,
     socket
     |> assign(:generating_avatar, false)
     |> assign(:generated_avatar_data, data)
     |> assign(:generated_avatar_preview, preview)
     |> assign(:avatar_error, nil)}
  end

  def handle_async(:generate_avatar, {:ok, {:error, :no_openai_key}}, socket) do
    {:noreply,
     socket
     |> assign(:generating_avatar, false)
     |> assign(:avatar_error, "No OpenAI API key found. Add one in Settings \u2192 Credentials.")}
  end

  def handle_async(:generate_avatar, {:ok, {:error, reason}}, socket)
      when is_binary(reason) do
    {:noreply,
     socket
     |> assign(:generating_avatar, false)
     |> assign(:avatar_error, reason)}
  end

  def handle_async(:generate_avatar, {:ok, {:error, _reason}}, socket) do
    {:noreply,
     socket
     |> assign(:generating_avatar, false)
     |> assign(:avatar_error, "Avatar generation failed. Please try again.")}
  end

  def handle_async(:generate_avatar, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:generating_avatar, false)
     |> assign(:avatar_error, "Avatar generation failed. Please try again.")}
  end

  defp save(%{assigns: %{action: :new}} = socket, attrs) do
    case Agents.create_agent(attrs, FountainWeb.Audited.attribution(socket)) do
      {:ok, agent} ->
        maybe_set_avatar(socket, agent)

        {:ok,
         socket
         |> put_flash(:info, "Agent created")
         |> push_navigate(to: ~p"/agents")}

      {:error, cs} ->
        {:error, assign(socket, :errors, changeset_errors(cs))}
    end
  end

  defp save(%{assigns: %{action: :edit, agent: existing}} = socket, attrs) do
    case Agents.update_agent(existing, attrs, FountainWeb.Audited.attribution(socket)) do
      {:ok, saved} ->
        maybe_set_avatar(socket, saved)

        {:ok,
         socket
         |> put_flash(:info, "Agent updated")
         |> push_navigate(to: ~p"/agents")}

      # Moving the environment retires the homes built on the old one, and
      # that cannot happen under a running turn (#1084). Not a field error —
      # the form is fine, the timing is not.
      {:error, :sandbox_mid_turn} ->
        {:error,
         put_flash(
           socket,
           :error,
           "This agent is running a turn on its own machine right now. Changing its " <>
             "environment rebuilds that machine, so wait for the turn to finish, or " <>
             "interrupt it, then save again."
         )}

      {:error, cs} ->
        {:error, assign(socket, :errors, changeset_errors(cs))}
    end
  end

  # sobelow_skip ["Traversal.FileModule"] — path is the Phoenix-managed
  # upload tempfile, not client-supplied.
  defp maybe_set_avatar(socket, agent) do
    uploaded =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
        data = File.read!(path)

        Agents.upload_avatar(
          agent,
          data,
          entry.client_type,
          FountainWeb.Audited.attribution(socket)
        )

        {:ok, :uploaded}
      end)

    if uploaded == [] do
      case socket.assigns.generated_avatar_data do
        nil ->
          :ok

        data ->
          Agents.upload_avatar(agent, data, "image/png", FountainWeb.Audited.attribution(socket))
      end
    end
  end

  defp extract_skills_from_params(params, current_skills) do
    case params["skills"] do
      nil ->
        current_skills

      skills_map when is_map(skills_map) ->
        skills_map
        |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
        |> Enum.map(fn {_, s} -> s end)

      _ ->
        current_skills
    end
  end

  defp extract_mcp_servers_from_params(params, current_servers) do
    case params["mcp_servers"] do
      nil ->
        current_servers

      servers_map when is_map(servers_map) ->
        servers_map
        |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
        |> Enum.map(fn {k, s} ->
          env_vars =
            case s["env_vars"] do
              nil ->
                []

              evs when is_map(evs) ->
                evs
                |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
                |> Enum.map(fn {_, r} -> r end)

              _ ->
                []
            end

          # A pass-through entry has no editable fields, so its config is not
          # in the params: carry it over from the row it came from.
          current = Enum.at(current_servers, String.to_integer(k)) || %{}

          s
          |> Map.put("env_vars", env_vars)
          |> Map.put_new("kind", current["kind"] || "stdio")
          |> then(&if &1["kind"] == "raw", do: Map.put(&1, "raw", current["raw"]), else: &1)
        end)

      _ ->
        current_servers
    end
  end

  defp validate_skills_list([]), do: :ok

  defp validate_skills_list(skills) do
    Enum.reduce_while(skills, :ok, fn skill, _acc ->
      case skill["type"] do
        "github" ->
          if (skill["source"] || "") == "" do
            {:halt, {:error, "skills_json", "each GitHub skill must have a source (owner/repo)"}}
          else
            {:cont, :ok}
          end

        "inline" ->
          cond do
            (skill["name"] || "") == "" ->
              {:halt, {:error, "skills_json", "each inline skill must have a name"}}

            (skill["content"] || "") == "" ->
              {:halt, {:error, "skills_json", "each inline skill must have content"}}

            true ->
              {:cont, :ok}
          end

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_mcp_servers([]), do: :ok

  defp validate_mcp_servers(servers) do
    names = Enum.map(servers, &(&1["name"] || ""))

    cond do
      Enum.any?(names, &(&1 == "")) ->
        {:error, "mcp_servers_json", "each server must have a name"}

      length(names) != length(Enum.uniq(names)) ->
        {:error, "mcp_servers_json", "server names must be unique"}

      Enum.any?(servers, &(&1["kind"] == "connection" and (&1["connection"] || "") == "")) ->
        {:error, "mcp_servers_json", "pick a connection for each connection server"}

      true ->
        :ok
    end
  end

  # The stored shape for one form row (the inverse of agent_to_mcp_server_list/1).
  # A connection entry is either the Fountain-served server (a bare
  # connection) or a remote server of the tenant's (URL + connection, #1186).
  defp mcp_server_config(%{"kind" => "connection"} = s) do
    case String.trim(s["url"] || "") do
      "" -> %{"connection" => s["connection"]}
      url -> %{"type" => "http", "url" => url, "connection" => s["connection"]}
    end
  end

  defp mcp_server_config(%{"kind" => "raw", "raw" => raw}) when is_map(raw), do: raw

  defp mcp_server_config(s) do
    args =
      (s["args"] || "")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    env_map =
      (s["env_vars"] || [])
      |> Map.new(fn %{"key" => k, "value" => v} -> {k, v} end)
      |> Map.reject(fn {k, _} -> k == "" end)

    config = %{"command" => s["command"] || ""}
    config = if args != [], do: Map.put(config, "args", args), else: config
    if map_size(env_map) > 0, do: Map.put(config, "env", env_map), else: config
  end

  defp nil_if_blank(map, key),
    do: Map.update(map, key, nil, fn v -> if v in [nil, ""], do: nil, else: v end)

  defp changeset_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Map.new(fn {k, [first | _]} -> {to_string(k), first} end)
  end

  defp upload_error_to_string(:too_large), do: "File too large (max 5 MB)"
  defp upload_error_to_string(:not_accepted), do: "Unsupported file type"
  defp upload_error_to_string(:too_many_files), do: "Only one avatar allowed"
  defp upload_error_to_string(_), do: "Upload failed"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">{page_title(@action)}</h1>
        <.link
          :if={@action == :edit}
          navigate={~p"/agents/#{@agent.id}/versions"}
          class="text-sm text-zinc-500 hover:text-zinc-700"
        >
          History
        </.link>
      </div>

      <.missing_credential_card
        :if={@missing_credential}
        missing={@missing_credential}
        message={@credential_message}
      />

      <form
        id="agent-form"
        phx-change="validate"
        phx-submit="submit"
        class="space-y-4 bg-white rounded shadow p-6 border border-zinc-200"
      >
        <.input id="name" name="agent[name]" label="Name" value={@form["name"]} autofocus required />
        <.error_msg field="name" errors={@errors} />

        <.input
          id="description"
          name="agent[description]"
          label="Description"
          value={@form["description"]}
        />

        <.input
          id="system"
          name="agent[system]"
          type="textarea"
          rows="6"
          label="System prompt"
          value={@form["system"]}
          placeholder="You are a focused subagent..."
        />

        <div class="grid grid-cols-2 gap-3">
          <div class="space-y-1">
            <label class="block text-sm font-medium text-zinc-700">Runtime</label>
            <select
              name="agent[runtime]"
              class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"
            >
              <option :for={r <- Agent.runtimes()} value={r} selected={@form["runtime"] == r}>
                {r}
              </option>
            </select>
          </div>
          <.input
            id="model"
            name="agent[model]"
            label="Model"
            value={@form["model"]}
            placeholder={model_placeholder(@form["runtime"])}
            list="model-options"
            disabled={not model_required?(@form["runtime"])}
            required={model_required?(@form["runtime"])}
          />
          <datalist id="model-options">
            <option :for={m <- ModelCatalog.suggestions(@form["runtime"])} value={m}></option>
          </datalist>
        </div>
        <.error_msg field="model" errors={@errors} />
        <div :if={command_runtime?(@form["runtime"])} class="space-y-1">
          <.input
            id="runtime_command"
            name="agent[runtime_command]"
            label="Command"
            value={@form["runtime_command"]}
            placeholder="chant acp"
            required
          />
          <.error_msg field="runtime_command" errors={@errors} />
          <p class="text-zinc-500 text-xs">
            The acp runtime runs this shell line inside the sandbox and speaks the Agent
            Client Protocol to it. It needs no model and no inference key. Install the
            program through the environment's packages or its setup script.
          </p>
        </div>
        <p
          :if={not Map.has_key?(@errors, "model") and unknown_model?(@form["model"])}
          class="text-zinc-500 text-xs"
        >
          Not one of the models Fountain lists — it will be passed to the runtime as-is.
        </p>

        <div :if={length(@sandbox_providers) > 1} class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">Sandbox provider</label>
          <select
            name="agent[sandbox_provider]"
            class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"
          >
            <option value="">
              Instance default ({Fountain.SandboxProviders.default_provider()})
            </option>
            <option
              :for={p <- @sandbox_providers}
              value={p}
              selected={@form["sandbox_provider"] == to_string(p)}
            >
              {p}
            </option>
          </select>
          <.error_msg field="sandbox_provider" errors={@errors} />
        </div>

        <div class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">Sandbox</label>
          <select
            name="agent[sandbox_mode]"
            class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"
          >
            <option value="ephemeral" selected={@form["sandbox_mode"] != "persistent"}>
              A fresh sandbox per conversation
            </option>
            <option value="persistent" selected={@form["sandbox_mode"] == "persistent"}>
              One persistent sandbox — the agent's computer
            </option>
          </select>
          <p class="text-xs text-zinc-500">
            Persistent: every conversation of this agent (with the same environment and
            vault) lands on one machine and shares its disk, at the same time. Notes,
            clones and installed tools accrue; so does anything a bad turn leaves
            behind. It survives a conversation ending and is parked, not destroyed, at
            the ceiling. A launch can still ask for the other mode.
          </p>
          <.error_msg field="sandbox_mode" errors={@errors} />
        </div>

        <div class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">Environment</label>
          <select
            name="agent[environment_id]"
            class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"
          >
            <option value="">\u2014 none \u2014</option>
            <option :for={e <- @envs} value={e.id} selected={@form["environment_id"] == e.id}>
              {e.name}
            </option>
          </select>
          <%!-- The provider is per agent (ADR 0018) and the egress policy is
                per environment, so this pairing is the only place both are
                known before a launch (#935). --%>
          <.network_policy_note
            provider={@form["sandbox_provider"]}
            env_id={@form["environment_id"]}
            envs={@envs}
          />
        </div>

        <%!-- Permissions (#939): what answers before the agent runs a tool. --%>
        <div class="space-y-2">
          <label class="block text-sm font-medium text-zinc-700">
            Before the agent runs a tool
          </label>
          <select
            name="agent[permission_default]"
            disabled={not asks_permission?(@form["runtime"])}
            class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm disabled:bg-zinc-100 disabled:text-zinc-500"
          >
            <option value="auto_allow" selected={@form["permission_default"] == "auto_allow"}>
              Run it
            </option>
            <option value="ask" selected={@form["permission_default"] == "ask"}>
              Ask a human, and refuse if nobody answers
            </option>
            <option value="auto_deny" selected={@form["permission_default"] == "auto_deny"}>
              Refuse it
            </option>
          </select>

          <p :if={not asks_permission?(@form["runtime"])} class="text-xs text-amber-700">
            The {@form["runtime"]} runtime decides this inside its own server and never asks
            Fountain, so a policy here would show a restriction it could not enforce.
          </p>

          <details :if={asks_permission?(@form["runtime"])} class="text-sm">
            <summary class="cursor-pointer text-zinc-600">
              Per kind of tool ({permission_override_count(@form)} set)
            </summary>
            <p class="mt-2 text-xs text-zinc-500">
              A kind is the agent's own label for what a tool call does. Leave one alone to
              follow the setting above.
            </p>
            <div class="mt-2 grid grid-cols-2 gap-2">
              <div :for={kind <- Permissions.tool_kinds()} class="flex items-center gap-2">
                <label class="w-20 text-xs text-zinc-600" for={"permission-#{kind}"}>{kind}</label>
                <select
                  id={"permission-#{kind}"}
                  name={"agent[permission_kinds][#{kind}]"}
                  class="flex-1 rounded-md border border-zinc-300 bg-white px-2 py-1 text-xs"
                >
                  <option value="" selected={@form["permission_kinds"][kind] in [nil, ""]}>
                    Same as above
                  </option>
                  <option
                    :for={verdict <- Permissions.verdicts()}
                    value={verdict}
                    selected={@form["permission_kinds"][kind] == verdict}
                  >
                    {verdict}
                  </option>
                </select>
              </div>
            </div>
          </details>

          <p class="text-xs text-zinc-500">
            A conversation may narrow this at launch, never widen it. An unanswered request is
            refused after five minutes, and the turn carries on.
          </p>
          <.error_msg field="permission_policy" errors={@errors} />
        </div>

        <%!-- Avatar --%>
        <div class="space-y-3">
          <label class="block text-sm font-medium text-zinc-700">Avatar</label>

          <div
            :if={@agent.id && @agent.avatar_media_type && !@generated_avatar_preview}
            class="flex items-center gap-3"
          >
            <img
              src={~p"/agents/#{@agent.id}/avatar"}
              class="w-14 h-14 rounded-xl object-cover border border-zinc-200"
              alt="Current avatar"
            />
            <button
              type="button"
              phx-click="remove_avatar"
              class="text-sm text-rose-600 hover:text-rose-800 underline underline-offset-2"
            >
              Remove
            </button>
          </div>

          <div :if={@generated_avatar_preview} class="flex items-center gap-3">
            <img
              src={@generated_avatar_preview}
              class="w-14 h-14 rounded-xl object-cover border border-zinc-200"
              alt="Generated avatar preview"
            />
            <div class="text-sm space-y-0.5">
              <p class="text-zinc-500">Will be saved when you submit.</p>
              <button
                type="button"
                phx-click="discard_generated_avatar"
                class="text-rose-600 hover:text-rose-800 underline underline-offset-2"
              >
                Discard
              </button>
            </div>
          </div>

          <div class="flex gap-0.5 rounded-lg border border-zinc-200 bg-zinc-50 p-0.5 w-fit text-sm">
            <button
              type="button"
              phx-click="switch_avatar_tab"
              phx-value-tab="upload"
              class={[
                "px-3 py-1 rounded-md transition-colors",
                @avatar_tab == :upload && "bg-white shadow-sm font-medium text-zinc-900",
                @avatar_tab != :upload && "text-zinc-500 hover:text-zinc-700"
              ]}
            >
              Upload
            </button>
            <button
              type="button"
              phx-click="switch_avatar_tab"
              phx-value-tab="generate"
              class={[
                "px-3 py-1 rounded-md transition-colors",
                @avatar_tab == :generate && "bg-white shadow-sm font-medium text-zinc-900",
                @avatar_tab != :generate && "text-zinc-500 hover:text-zinc-700"
              ]}
            >
              Generate with AI
            </button>
          </div>

          <div :if={@avatar_tab == :upload} class="space-y-2">
            <.live_file_input
              upload={@uploads.avatar}
              class="block text-sm text-zinc-700 file:mr-3 file:rounded file:border-0
                     file:bg-zinc-100 file:px-3 file:py-1.5 file:text-sm file:font-medium
                     file:cursor-pointer hover:file:bg-zinc-200"
            />
            <p class="text-xs text-zinc-500">JPEG, PNG, GIF, or WebP \u00b7 max 5 MB</p>

            <div :for={entry <- @uploads.avatar.entries} class="flex items-center gap-3">
              <.live_img_preview
                entry={entry}
                class="w-14 h-14 rounded-xl object-cover border border-zinc-200"
              />
              <div class="text-sm text-zinc-600">
                <p class="font-medium">{entry.client_name}</p>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="text-rose-600 hover:text-rose-800 underline underline-offset-2"
                >
                  Remove
                </button>
              </div>
              <p :for={err <- upload_errors(@uploads.avatar, entry)} class="text-rose-600 text-xs">
                {upload_error_to_string(err)}
              </p>
            </div>
          </div>

          <div :if={@avatar_tab == :generate} class="space-y-3">
            <div class="space-y-1.5">
              <p class="text-xs font-medium text-zinc-600">Base</p>
              <div class="flex gap-1.5">
                <button
                  :for={b <- AvatarGenerator.bases()}
                  type="button"
                  phx-click="set_avatar_base"
                  phx-value-base={b}
                  class={[
                    "px-3 py-1.5 rounded-md text-sm border transition-colors",
                    @avatar_base == b && "bg-zinc-900 text-white border-zinc-900",
                    @avatar_base != b && "bg-white text-zinc-600 border-zinc-300 hover:bg-zinc-50"
                  ]}
                >
                  {String.capitalize(b)}
                </button>
              </div>
            </div>

            <div class="space-y-1.5">
              <p class="text-xs font-medium text-zinc-600">Mood</p>
              <div class="flex gap-1.5">
                <button
                  :for={m <- AvatarGenerator.moods()}
                  type="button"
                  phx-click="set_avatar_mood"
                  phx-value-mood={m}
                  class={[
                    "px-3 py-1.5 rounded-md text-sm border transition-colors",
                    @avatar_mood == m && "bg-zinc-900 text-white border-zinc-900",
                    @avatar_mood != m && "bg-white text-zinc-600 border-zinc-300 hover:bg-zinc-50"
                  ]}
                >
                  {String.capitalize(m)}
                </button>
              </div>
            </div>

            <button
              type="button"
              phx-click="generate_avatar"
              disabled={@generating_avatar}
              class="flex items-center gap-2 rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium
                     text-white hover:bg-zinc-700 disabled:opacity-60 disabled:cursor-not-allowed"
            >
              <%= if @generating_avatar do %>
                <svg
                  class="animate-spin h-4 w-4"
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                >
                  <circle
                    class="opacity-25"
                    cx="12"
                    cy="12"
                    r="10"
                    stroke="currentColor"
                    stroke-width="4"
                  >
                  </circle>
                  <path
                    class="opacity-75"
                    fill="currentColor"
                    d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                  >
                  </path>
                </svg>
                Generating\u2026
              <% else %>
                Generate
              <% end %>
            </button>

            <p :if={@avatar_error} class="text-rose-600 text-xs">{@avatar_error}</p>
          </div>
        </div>

        <%!-- Skills --%>
        <div class="space-y-2">
          <label class="block text-sm font-medium text-zinc-700">Skills</label>

          <div :if={@skills == []} class="text-sm text-zinc-400 italic py-1">
            No skills configured.
          </div>

          <div
            :for={{skill, i} <- Enum.with_index(@skills)}
            class="border border-zinc-200 rounded-md p-3 bg-zinc-50 space-y-2"
          >
            <div class="flex items-center justify-between">
              <div class="flex gap-0.5 rounded border border-zinc-200 bg-white p-0.5 text-xs">
                <button
                  type="button"
                  phx-click="set_skill_type"
                  phx-value-index={i}
                  phx-value-type="github"
                  class={[
                    "px-2 py-0.5 rounded-sm transition-colors",
                    skill["type"] == "github" && "bg-zinc-900 text-white",
                    skill["type"] != "github" && "text-zinc-500 hover:text-zinc-700"
                  ]}
                >
                  GitHub
                </button>
                <button
                  type="button"
                  phx-click="set_skill_type"
                  phx-value-index={i}
                  phx-value-type="inline"
                  class={[
                    "px-2 py-0.5 rounded-sm transition-colors",
                    skill["type"] == "inline" && "bg-zinc-900 text-white",
                    skill["type"] != "inline" && "text-zinc-500 hover:text-zinc-700"
                  ]}
                >
                  Inline
                </button>
              </div>
              <button
                type="button"
                phx-click="remove_skill"
                phx-value-index={i}
                class="text-xs text-rose-500 hover:text-rose-700 font-medium"
              >
                Remove
              </button>
            </div>

            <input type="hidden" name={"agent[skills][#{i}][type]"} value={skill["type"]} />

            <div :if={skill["type"] == "github"} class="grid grid-cols-2 gap-2">
              <.input
                id={"skill_#{i}_source"}
                name={"agent[skills][#{i}][source]"}
                label="Source (owner/repo)"
                value={skill["source"] || ""}
                placeholder="anthropics/skills"
              />
              <.input
                id={"skill_#{i}_name"}
                name={"agent[skills][#{i}][name]"}
                label="Name (optional)"
                value={skill["name"] || ""}
                placeholder="brainstorming"
              />
            </div>

            <div :if={skill["type"] == "inline"} class="space-y-2">
              <.input
                id={"skill_#{i}_inline_name"}
                name={"agent[skills][#{i}][name]"}
                label="Name"
                value={skill["name"] || ""}
                placeholder="my-skill"
              />
              <.input
                id={"skill_#{i}_content"}
                name={"agent[skills][#{i}][content]"}
                type="textarea"
                rows="8"
                label="Content (SKILL.md body)"
                value={skill["content"] || ""}
                placeholder="# My Skill&#10;&#10;..."
              />
            </div>
          </div>

          <button
            type="button"
            phx-click="add_skill"
            class="text-sm font-medium text-indigo-600 hover:text-indigo-800"
          >
            + Add skill
          </button>
          <.error_msg field="skills_json" errors={@errors} />

          <div class="text-xs text-zinc-500 space-y-2 mt-1">
            <p>
              GitHub skills are fetched via
              <a href="https://skills.sh" target="_blank" class="underline">skills.sh</a>
              using the <code>source</code>
              (owner/repo) and optional skill <code>name</code>.
              Inline skills embed a full SKILL.md body directly.
              <.link navigate={~p"/help/skills"} class="underline">Skills help \u2192</.link>
            </p>
            <div class="rounded border border-blue-200 bg-blue-50 px-3 py-2 text-blue-900 leading-relaxed">
              <strong>Always included:</strong>
              the built-in <code>fountain</code>
              skill is automatically mounted in every
              conversation \u2014 no need to declare it. It gives the agent <code>$FOUNTAIN_TOKEN</code>, <code>$FOUNTAIN_BASE_URL</code>, and
              <code>$FOUNTAIN_CONVERSATION_ID</code>
              so it can spawn and coordinate sub-agents.
            </div>
          </div>
        </div>

        <%!-- MCP servers --%>
        <div class="space-y-2">
          <label class="block text-sm font-medium text-zinc-700">MCP servers</label>

          <div :if={@mcp_servers == []} class="text-sm text-zinc-400 italic py-1">
            No MCP servers configured.
          </div>

          <div
            :for={{server, i} <- Enum.with_index(@mcp_servers)}
            class="border border-zinc-200 rounded-md p-3 bg-zinc-50 space-y-2"
          >
            <div class="flex items-center justify-between">
              <span class="text-xs font-semibold text-zinc-500 uppercase tracking-wide">
                Server {i + 1}
              </span>
              <button
                type="button"
                phx-click="remove_mcp_server"
                phx-value-index={i}
                class="text-xs text-rose-500 hover:text-rose-700 font-medium"
              >
                Remove
              </button>
            </div>

            <.input
              id={"mcp_#{i}_name"}
              name={"agent[mcp_servers][#{i}][name]"}
              label="Server name"
              value={server["name"] || ""}
              placeholder="github"
            />

            <%!-- A connection (#1178): Fountain serves the server and holds the
                  credential. Only offered where the account has one. --%>
            <div :if={@connections != [] and server["kind"] != "raw"} class="space-y-1">
              <label for={"mcp_#{i}_kind"} class="block text-sm font-medium text-zinc-700">
                Type
              </label>
              <select
                id={"mcp_#{i}_kind"}
                name={"agent[mcp_servers][#{i}][kind]"}
                class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"
              >
                <option
                  :for={
                    {label, kind} <- [
                      {"Command (stdio)", "stdio"},
                      {"Connected account", "connection"}
                    ]
                  }
                  value={kind}
                  selected={(server["kind"] || "stdio") == kind}
                >
                  {label}
                </option>
              </select>
            </div>
            <div :if={server["kind"] == "connection"} class="space-y-1">
              <label for={"mcp_#{i}_connection"} class="block text-sm font-medium text-zinc-700">
                Connection
              </label>
              <select
                id={"mcp_#{i}_connection"}
                name={"agent[mcp_servers][#{i}][connection]"}
                class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"
              >
                <option value="">Pick a connected account</option>
                <option
                  :for={c <- @connections}
                  value={c.id}
                  selected={server["connection"] == c.id}
                >
                  {c.account_email} ({c.provider})
                </option>
              </select>
            </div>
            <.input
              :if={server["kind"] == "connection"}
              id={"mcp_#{i}_url"}
              name={"agent[mcp_servers][#{i}][url]"}
              label="Remote server URL (optional)"
              value={server["url"] || ""}
              placeholder="https://mcp.example.com/mcp"
            />
            <p :if={server["kind"] == "connection"} class="text-xs text-zinc-500">
              With a URL, the sandbox calls that server and the egress broker attaches the
              account's token to it. Without one, a Google account gets the Fountain-served
              Gmail tools; any other provider needs a URL here, or a stdio server that reads
              its brokered env key. Either way no token enters the sandbox.
            </p>

            <div :if={server["kind"] == "raw"} class="text-xs text-zinc-500">
              A remote server defined through the API (kept as is):
              <code class="font-mono">{Jason.encode!(server["raw"])}</code>
            </div>

            <.input
              :if={server["kind"] in [nil, "stdio"]}
              id={"mcp_#{i}_command"}
              name={"agent[mcp_servers][#{i}][command]"}
              label="Command"
              value={server["command"] || ""}
              placeholder="npx"
            />
            <.input
              :if={server["kind"] in [nil, "stdio"]}
              id={"mcp_#{i}_args"}
              name={"agent[mcp_servers][#{i}][args]"}
              type="textarea"
              rows="2"
              label="Args (one per line)"
              value={server["args"] || ""}
              placeholder="-y&#10;@modelcontextprotocol/server-github"
            />

            <div :if={server["kind"] in [nil, "stdio"]} class="space-y-1.5">
              <label class="block text-xs font-medium text-zinc-600">Env vars (optional)</label>

              <div class="space-y-1">
                <div
                  :for={{ev, j} <- Enum.with_index(server["env_vars"] || [])}
                  class="flex gap-2 items-center"
                >
                  <input
                    type="text"
                    name={"agent[mcp_servers][#{i}][env_vars][#{j}][key]"}
                    value={ev["key"] || ""}
                    placeholder="KEY"
                    class="w-32 rounded border border-zinc-300 px-2 py-1 text-xs font-mono"
                  />
                  <span class="text-zinc-400 text-xs select-none">=</span>
                  <input
                    type="text"
                    name={"agent[mcp_servers][#{i}][env_vars][#{j}][value]"}
                    value={ev["value"] || ""}
                    placeholder="value"
                    class="flex-1 rounded border border-zinc-300 px-2 py-1 text-xs"
                  />
                  <button
                    type="button"
                    phx-click="remove_mcp_env_var"
                    phx-value-server={i}
                    phx-value-index={j}
                    class="text-xs text-rose-400 hover:text-rose-600 font-medium shrink-0"
                  >
                    Remove
                  </button>
                </div>
              </div>

              <button
                type="button"
                phx-click="add_mcp_env_var"
                phx-value-server={i}
                class="text-xs font-medium text-indigo-600 hover:text-indigo-800"
              >
                + Add env var
              </button>
            </div>
          </div>

          <button
            type="button"
            phx-click="add_mcp_server"
            class="text-sm font-medium text-indigo-600 hover:text-indigo-800"
          >
            + Add server
          </button>
          <.error_msg field="mcp_servers_json" errors={@errors} />
        </div>

        <div class="flex gap-2">
          <.btn type="submit" phx-disable-with="Saving\u2026">Save</.btn>
          <.link navigate={~p"/agents"}>
            <.btn_secondary>Cancel</.btn_secondary>
          </.link>
        </div>
      </form>
    </div>
    """
  end

  attr :field, :string, required: true
  attr :errors, :map, required: true

  defp error_msg(assigns) do
    ~H"""
    <p :if={Map.has_key?(@errors, @field)} class="text-rose-600 text-xs">
      {Map.get(@errors, @field)}
    </p>
    """
  end

  attr :provider, :any, required: true
  attr :env_id, :any, required: true
  attr :envs, :list, required: true

  defp network_policy_note(assigns) do
    assigns =
      assign(
        assigns,
        :backend,
        unenforceable_network_policy(assigns.provider, assigns.env_id, assigns.envs)
      )

    ~H"""
    <p
      :if={@backend}
      class="rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900"
    >
      <span class="font-medium">{@backend} cannot hold a limited environment.</span>
      This environment sets <code>networking_type: limited</code>, and that backend advertises
      no egress policy. The agent saves, but a conversation on this pairing refuses to start
      rather than run unrestricted.
    </p>
    """
  end

  # The provider that will run this agent, and whether it can enforce the
  # selected environment's egress policy. Returns the provider's name when the
  # pairing cannot work, nil when it can (#935).
  defp unenforceable_network_policy(provider_str, env_id, envs) do
    provider =
      case provider_str do
        p when is_binary(p) and p != "" -> safe_provider(p)
        _ -> Fountain.SandboxProviders.default_provider()
      end

    env = provider && Enum.find(envs, &(&1.id == env_id))

    if env && env.networking_type == "limited" &&
         not Managoat.Sandbox.supports?(provider, :network_policy) do
      to_string(provider)
    end
  end

  # @form is whatever was posted, so the string is only converted when the
  # schema would accept it. Enabledness is not the question here: a stored
  # agent on a provider the operator has since switched off still shows the
  # pairing it will fail on.
  defp safe_provider(str) do
    if str in Fountain.SandboxProviders.known_providers(), do: String.to_existing_atom(str)
  end

  attr :missing, :any, required: true
  attr :message, :any, required: true

  defp missing_credential_card(assigns) do
    {provider, accepted} = assigns.missing
    assigns = assign(assigns, provider: provider, accepted: accepted, first: hd(accepted))

    ~H"""
    <div class="rounded-md border border-amber-300 bg-amber-50 p-3 space-y-2">
      <p class="text-sm text-amber-900">
        <span class="font-medium">
          No {FountainWeb.InferenceCredentialSave.label(@provider)} credential on this account yet.
        </span>
        The agent saves fine, but its conversations cannot start until one is set. Paste it here and it is validated and saved <span :if={
          length(@accepted) > 1
        }>
          (a {Enum.map_join(tl(@accepted), " or ", &FountainWeb.InferenceCredentialSave.label/1)} works too — Settings → Inference credentials)
        </span>:
      </p>
      <form phx-submit="save_credential" class="flex gap-2">
        <input type="hidden" name="provider" value={Atom.to_string(@first)} />
        <input
          type="password"
          name="value"
          placeholder={"#{FountainWeb.InferenceCredentialSave.label(@first)} · from #{FountainWeb.InferenceCredentialSave.source(@first)}"}
          autocomplete="off"
          class="flex-1 rounded-md border border-amber-300 bg-white px-2 py-1.5 text-xs font-mono focus:outline-none focus:ring-2 focus:ring-amber-500"
        />
        <button
          type="submit"
          class="rounded-md bg-zinc-900 text-white px-3 py-1.5 text-xs font-medium hover:bg-zinc-700"
        >
          Save key
        </button>
      </form>
      <%= case @message do %>
        <% nil -> %>
        <% {:info, msg} -> %>
          <p class="text-xs text-emerald-700">{msg}</p>
        <% {:error, msg} -> %>
          <p class="text-xs text-rose-700">{msg}</p>
      <% end %>
    </div>
    """
  end
end
