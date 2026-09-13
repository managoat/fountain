defmodule FountainWeb.ConnectionsLive.Index do
  @moduledoc """
  `/account/connections` — the provider accounts this tenant has signed in
  to, whose credentials Fountain holds (#1178), and the providers those
  accounts come from (#1186): Google, the tenant's own OAuth apps, and the
  remote MCP servers whose authorization Fountain discovered. List,
  connect, reconnect, revoke; add, edit and delete a provider; enter a
  remote MCP server's URL and let discovery do the rest. The OAuth round
  trip itself is `FountainWeb.ConnectionsController`; this page only links
  to it and shows what came back.

  Only on a deployment that runs the broker: the nav link is hidden otherwise,
  and a direct visit is sent to `/account`. The `connections` rollout flag
  decides whether this page can *add* anything. With it off the page still
  lists what the account holds and still revokes and removes it, and every
  control that would connect an account or define a provider is gone (#1693).
  """

  use FountainWeb, :live_view

  alias Fountain.Connections
  alias Fountain.Connections.{Platform, Provider}
  alias FountainWeb.{Audited, ConnectionProviderJSON}

  @blank_form %{
    "kind" => "oauth2",
    "name" => "",
    "slug" => "",
    "authorize_url" => "",
    "token_url" => "",
    "revoke_url" => "",
    "userinfo_url" => "",
    "account_label_path" => "",
    "scopes" => "",
    "client_id" => "",
    "client_secret" => "",
    "token_endpoint_auth" => "client_secret_post",
    "pkce" => "true",
    "env_key" => "",
    "token_hosts" => ""
  }

  # A few well-known app registrations, so a tenant can pick one and paste
  # only the client id and secret. Suggestions, not a catalog: any provider
  # is a matter of typing its endpoints. Slack left this list when it became
  # a platform provider (#1299) — its slug is reserved now, and the platform
  # row is the one that works without an app registration.
  @presets [
    %{
      "slug" => "github",
      "name" => "GitHub",
      "authorize_url" => "https://github.com/login/oauth/authorize",
      "token_url" => "https://github.com/login/oauth/access_token",
      "userinfo_url" => "https://api.github.com/user",
      "account_label_path" => "login",
      "scopes" => "repo read:user",
      "token_hosts" => "api.github.com",
      "pkce" => "false"
    },
    %{
      "slug" => "notion",
      "name" => "Notion",
      "authorize_url" => "https://api.notion.com/v1/oauth/authorize",
      "token_url" => "https://api.notion.com/v1/oauth/token",
      "token_endpoint_auth" => "client_secret_basic",
      "userinfo_url" => "https://api.notion.com/v1/users/me",
      "account_label_path" => "name",
      "scopes" => "",
      "token_hosts" => "api.notion.com",
      "pkce" => "false"
    },
    %{
      "slug" => "linear",
      "name" => "Linear",
      "authorize_url" => "https://linear.app/oauth/authorize",
      "token_url" => "https://api.linear.app/oauth/token",
      "revoke_url" => "https://api.linear.app/oauth/revoke",
      "scopes" => "read write",
      "token_hosts" => "api.linear.app",
      "pkce" => "false"
    }
  ]

  def presets, do: @presets

  # The chips on the MCP box come from the verified registry (#1322), not a
  # second list here: same menu-not-a-gate rule as @presets above, but these
  # entries carry a machine-checked claim, so they live beside the checker.
  def mcp_catalog, do: Fountain.Connections.McpServerCatalog.entries()

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # The page opens for any brokered account, so the connections an account
    # holds can always be seen, revoked and removed. `may_connect?` carries
    # the rollout flag: with it off the page keeps every door that takes a
    # credential away and hides the ones that add one (#1693).
    if Fountain.Connections.manageable_for?() do
      {:ok,
       socket
       |> assign(:page_title, "Connections")
       |> assign(:user_id, user.id)
       |> assign(:may_connect?, Fountain.Connections.enabled_for?(user.id))
       |> assign(:provider_form, nil)
       |> assign(:editing_id, nil)
       |> assign(:provider_errors, [])
       |> assign(:mcp_url, "")
       |> assign(:mcp_client_id, "")
       |> assign(:mcp_client_secret, "")
       |> assign(:discovering, false)
       |> reload()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Connections are not enabled for this account.")
       |> push_navigate(to: ~p"/account")}
    end
  end

  # Every event that would add a way of getting a credential, refused in one
  # place for an account without the rollout flag. The template hides these
  # controls; a hidden control is not a gate, so the event is refused too.
  @adding ~w(new_provider preset edit_provider validate_provider save_provider
             mcp_preset validate_mcp discover rediscover)

  @impl true
  def handle_event(event, _params, %{assigns: %{may_connect?: false}} = socket)
      when event in @adding do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Connections are not enabled for this account. You can still revoke and remove the ones you have."
     )}
  end

  # ── connections ───────────────────────────────────────────────────────────

  def handle_event("revoke", %{"id" => id}, socket) do
    user_id = socket.assigns.user_id

    case Connections.get_connection(id, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That connection is gone.")}

      connection ->
        case Connections.revoke(connection, Audited.attribution(socket)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Revoked #{connection.account_email}. Agents that name it will be told."
             )
             |> reload()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not revoke: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user_id = socket.assigns.user_id

    case Connections.get_connection(id, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That connection is gone.")}

      connection ->
        case Connections.delete(connection, Audited.attribution(socket)) do
          {:ok, _} ->
            {:noreply,
             socket |> put_flash(:info, "Removed #{connection.account_email}.") |> reload()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not remove: #{inspect(reason)}")}
        end
    end
  end

  # ── providers ─────────────────────────────────────────────────────────────

  def handle_event("new_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:provider_form, @blank_form)
     |> assign(:editing_id, nil)
     |> assign(:provider_errors, [])}
  end

  def handle_event("preset", %{"slug" => slug}, socket) do
    form = socket.assigns.provider_form || @blank_form

    case Enum.find(@presets, &(&1["slug"] == slug)) do
      nil -> {:noreply, socket}
      preset -> {:noreply, assign(socket, :provider_form, Map.merge(form, preset))}
    end
  end

  def handle_event("edit_provider", %{"id" => id}, socket) do
    case Connections.get_provider(id, socket.assigns.user_id) do
      %Provider{user_id: uid} = p when is_binary(uid) ->
        {:noreply,
         socket
         |> assign(:provider_form, form_from(p))
         |> assign(:editing_id, p.id)
         |> assign(:provider_errors, [])}

      _ ->
        {:noreply, put_flash(socket, :error, "That provider is gone.")}
    end
  end

  def handle_event("cancel_provider", _params, socket) do
    {:noreply, socket |> assign(:provider_form, nil) |> assign(:editing_id, nil)}
  end

  def handle_event("validate_provider", %{"provider" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :provider_form,
       Map.merge(socket.assigns.provider_form || @blank_form, params)
     )}
  end

  def handle_event("save_provider", %{"provider" => params}, socket) do
    user_id = socket.assigns.user_id
    attrs = attrs_from(params)

    result =
      case socket.assigns.editing_id do
        nil ->
          Connections.create_provider(user_id, attrs, Audited.attribution(socket))

        id ->
          case Connections.get_provider(id, user_id) do
            %Provider{user_id: uid} = p when is_binary(uid) ->
              Connections.update_provider(p, attrs, Audited.attribution(socket))

            _ ->
              {:error, :not_found}
          end
      end

    case result do
      {:ok, p} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Saved #{p.name}. Register #{Connections.redirect_uri(p)} as its redirect URI."
         )
         |> assign(:provider_form, nil)
         |> assign(:editing_id, nil)
         |> assign(:provider_errors, [])
         |> reload()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         socket
         |> assign(:provider_form, Map.merge(socket.assigns.provider_form || @blank_form, params))
         |> assign(:provider_errors, errors(cs))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    case Connections.get_provider(id, socket.assigns.user_id) do
      %Provider{user_id: uid} = p when is_binary(uid) ->
        case Connections.delete_provider(p, Audited.attribution(socket)) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Deleted #{p.name}.") |> reload()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not delete: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "That provider is gone.")}
    end
  end

  # ── remote MCP servers ────────────────────────────────────────────────────

  def handle_event("mcp_preset", %{"slug" => slug}, socket) do
    case Fountain.Connections.McpServerCatalog.get(slug) do
      nil -> {:noreply, socket}
      entry -> {:noreply, assign(socket, :mcp_url, entry.url)}
    end
  end

  def handle_event("validate_mcp", params, socket) do
    {:noreply,
     socket
     |> assign(:mcp_url, params["mcp_url"] || "")
     |> assign(:mcp_client_id, params["client_id"] || "")
     |> assign(:mcp_client_secret, params["client_secret"] || "")}
  end

  def handle_event("discover", params, socket) do
    url = String.trim(params["mcp_url"] || "")

    attrs =
      %{}
      |> put_present("client_id", params["client_id"])
      |> put_present("client_secret", params["client_secret"])

    case Connections.discover_provider(
           socket.assigns.user_id,
           url,
           attrs,
           Audited.attribution(socket)
         ) do
      {:ok, p} ->
        {:noreply,
         socket
         |> put_flash(:info, discovered_message(p))
         |> assign(:mcp_url, "")
         |> assign(:mcp_client_id, "")
         |> assign(:mcp_client_secret, "")
         |> reload()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         put_flash(socket, :error, "Could not save the server: #{errors(cs) |> Enum.join("; ")}")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Discovery failed: #{ConnectionProviderJSON.describe(reason)}")}
    end
  end

  def handle_event("rediscover", %{"id" => id}, socket) do
    case Connections.get_provider(id, socket.assigns.user_id) do
      %Provider{kind: "mcp"} = p ->
        case Connections.rediscover_provider(p, Audited.attribution(socket)) do
          {:ok, p} ->
            {:noreply, socket |> put_flash(:info, discovered_message(p)) |> reload()}

          {:error, %Ecto.Changeset{} = cs} ->
            {:noreply, put_flash(socket, :error, Enum.join(errors(cs), "; "))}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Discovery failed: #{ConnectionProviderJSON.describe(reason)}"
             )}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "That provider is gone.")}
    end
  end

  defp discovered_message(%Provider{client_source: "dcr"} = p),
    do: "Found #{p.issuer} behind #{p.name} and registered a client. Connect it below."

  defp discovered_message(%Provider{client_id: id} = p) when is_binary(id) and id != "",
    do: "Found #{p.issuer} behind #{p.name}. Connect it below."

  defp discovered_message(%Provider{} = p),
    do:
      "Found #{p.issuer} behind #{p.name}, but it offers no client registration. " <>
        "Edit the provider and paste a client id and secret from its developer console."

  # ── helpers ───────────────────────────────────────────────────────────────

  defp reload(socket) do
    user_id = socket.assigns.user_id

    socket
    |> assign(:providers, Connections.all_providers(user_id))
    |> assign(:connections, Connections.list_connections(user_id))
  end

  defp form_from(%Provider{} = p) do
    %{
      "kind" => p.kind,
      "name" => p.name || "",
      "slug" => p.slug || "",
      "authorize_url" => p.authorize_url || "",
      "token_url" => p.token_url || "",
      "revoke_url" => p.revoke_url || "",
      "userinfo_url" => p.userinfo_url || "",
      "account_label_path" => p.account_label_path || "",
      "scopes" => Enum.join(p.scopes, " "),
      "client_id" => p.client_id || "",
      "client_secret" => "",
      "token_endpoint_auth" => p.token_endpoint_auth,
      "pkce" => to_string(p.pkce),
      "env_key" => p.env_key || "",
      "token_hosts" => Enum.join(p.token_hosts, " ")
    }
  end

  defp attrs_from(params) do
    params
    |> Map.take(Map.keys(@blank_form))
    |> Map.update("scopes", [], &split_words/1)
    |> Map.update("token_hosts", [], &split_words/1)
    |> Map.update("pkce", true, &(&1 in ["true", "on"]))
    |> Enum.reject(fn {k, v} ->
      k in ~w(revoke_url userinfo_url account_label_path slug env_key) and v == ""
    end)
    |> Map.new()
  end

  defp split_words(s) when is_binary(s), do: String.split(s, ~r/[\s,]+/, trim: true)
  defp split_words(l) when is_list(l), do: l

  defp put_present(map, _k, v) when v in [nil, ""], do: map
  defp put_present(map, k, v), do: Map.put(map, k, String.trim(v))

  defp errors(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map(fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp configured?(p), do: ConnectionProviderJSON.summary(p).configured

  # A provider that cannot name the account itself asks the tenant for a
  # label at connect time.
  defp asks_label?(%Provider{userinfo_url: url}), do: url in [nil, ""]

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8 max-w-3xl">
      <div>
        <h1 class="text-2xl font-semibold">Connections</h1>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1">
          Sign in to a provider once. Fountain keeps the refresh token, encrypted with your
          tenant key, and hands agents the capability rather than the credential: a
          Fountain-served MCP server that uses the connection on their behalf, a remote MCP
          server of yours with the token attached by the egress broker, or an access token
          brokered to the provider's hosts. No token ever enters a sandbox.
        </p>
        <p
          :if={!@may_connect?}
          data-role="connect-disabled"
          class="mt-3 rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900"
        >
          Connecting a new account is off for this account. The connections you have keep
          working, and you can revoke or remove any of them here.
        </p>
      </div>

      <%!-- ── Providers ─────────────────────────────────────────────────── --%>
      <section class="space-y-3" id="providers">
        <div class="flex items-center justify-between">
          <h2 class="text-lg font-medium">Providers</h2>
          <button
            :if={@may_connect?}
            phx-click="new_provider"
            data-role="new-provider"
            class="rounded-md border border-[var(--color-border)] px-3 py-1.5 text-sm hover:bg-[var(--color-bg-2)]"
          >
            Add an OAuth app
          </button>
        </div>
        <p class="text-xs text-[var(--color-text-secondary)]">
          Google, Microsoft and Slack use Fountain's own OAuth clients. For any other service,
          register an app there with the redirect URI shown here, then paste its client id and
          secret.
        </p>

        <div
          :for={p <- @providers}
          id={"provider-#{p.id}"}
          class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-4 space-y-2"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="space-y-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="font-medium">{p.name}</span>
                <span class="rounded-full bg-[var(--color-bg-2)] px-2 py-0.5 text-xs">{p.kind}</span>
                <span
                  :if={Provider.platform?(p)}
                  class="rounded-full bg-[var(--color-bg-2)] px-2 py-0.5 text-xs"
                >
                  platform
                </span>
                <span
                  :if={p.client_source == "dcr"}
                  class="rounded-full bg-[var(--color-bg-2)] px-2 py-0.5 text-xs"
                >
                  registered automatically
                </span>
              </div>
              <p :if={p.scopes != []} class="text-xs text-[var(--color-text-secondary)]">
                Scopes: <code class="font-mono">{Enum.join(p.scopes, " ")}</code>
              </p>
              <p class="text-xs text-[var(--color-text-secondary)]">
                Brokered as <code class="font-mono">{p.env_key}</code>
                <span :if={p.token_hosts != []}>
                  to <code class="font-mono">{Enum.join(p.token_hosts, ", ")}</code>
                </span>
              </p>
              <p :if={p.mcp_url} class="text-xs text-[var(--color-text-secondary)]">
                Server <code class="font-mono">{p.mcp_url}</code>
                <span :if={p.issuer}>
                  · authorization by <code class="font-mono">{p.issuer}</code>
                </span>
              </p>
              <p :if={!Provider.platform?(p)} class="text-xs text-[var(--color-text-secondary)]">
                Redirect URI
                <code class="font-mono select-all" data-role="redirect-uri">
                  {Connections.redirect_uri(p)}
                </code>
              </p>
            </div>
            <div class="flex flex-col items-end gap-2 shrink-0">
              <a
                :if={@may_connect? and configured?(p) and not asks_label?(p)}
                href={~p"/connections/#{p.id}/start"}
                data-role={"connect-#{p.slug}"}
                class="rounded-md bg-zinc-900 px-3 py-2 text-sm text-white hover:bg-zinc-700"
              >
                Connect {if Provider.platform?(p),
                  do: "a #{Platform.short_name(p)} account",
                  else: "an account"}
              </a>
              <form
                :if={@may_connect? and configured?(p) and asks_label?(p)}
                method="get"
                action={~p"/connections/#{p.id}/start"}
                class="flex gap-1"
              >
                <input
                  type="text"
                  name="label"
                  placeholder="Account name"
                  class="rounded-md border border-zinc-300 px-2 py-1 text-sm w-36"
                />
                <button
                  type="submit"
                  data-role={"connect-#{p.slug}"}
                  class="rounded-md bg-zinc-900 px-3 py-2 text-sm text-white hover:bg-zinc-700"
                >
                  Connect
                </button>
              </form>
              <span
                :if={!configured?(p) and Provider.platform?(p)}
                class="text-xs text-[var(--color-text-secondary)]"
              >
                Not configured on this deployment (<code class="font-mono">{Platform.client_env_var(p)}</code>).
              </span>
              <span :if={!configured?(p) and !Provider.platform?(p)} class="text-xs text-red-700">
                No client yet: edit and paste a client id and secret.
              </span>
              <div :if={!Provider.platform?(p)} class="flex gap-2">
                <button
                  :if={@may_connect? and p.kind == "mcp"}
                  phx-click="rediscover"
                  phx-value-id={p.id}
                  class="text-xs underline"
                >
                  Re-discover
                </button>
                <button
                  :if={@may_connect?}
                  phx-click="edit_provider"
                  phx-value-id={p.id}
                  class="text-xs underline"
                >
                  Edit
                </button>
                <button
                  phx-click="delete_provider"
                  phx-value-id={p.id}
                  data-confirm="Delete this provider and every connection on it?"
                  class="text-xs underline text-red-700"
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- ── Provider form ───────────────────────────────────────────── --%>
        <form
          :if={@provider_form}
          id="provider-form"
          phx-change="validate_provider"
          phx-submit="save_provider"
          class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-4 space-y-3"
        >
          <div class="flex items-center justify-between">
            <h3 class="font-medium">{if @editing_id, do: "Edit provider", else: "New OAuth app"}</h3>
            <div :if={!@editing_id} class="flex gap-1 flex-wrap">
              <span class="text-xs text-[var(--color-text-secondary)] self-center">Prefill:</span>
              <button
                :for={preset <- presets()}
                type="button"
                phx-click="preset"
                phx-value-slug={preset["slug"]}
                class="rounded-md border border-[var(--color-border)] px-2 py-0.5 text-xs"
              >
                {preset["name"]}
              </button>
            </div>
          </div>
          <ul
            :if={@provider_errors != []}
            class="text-sm text-red-700 list-disc pl-5"
            data-role="provider-errors"
          >
            <li :for={e <- @provider_errors}>{e}</li>
          </ul>
          <input type="hidden" name="provider[kind]" value={@provider_form["kind"]} />
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <.input
              name="provider[name]"
              label="Name"
              value={@provider_form["name"]}
              id="provider_name"
            />
            <.input
              name="provider[slug]"
              label="Slug"
              value={@provider_form["slug"]}
              id="provider_slug"
              placeholder="github"
            />
            <.input
              :if={@provider_form["kind"] == "oauth2"}
              name="provider[authorize_url]"
              label="Authorize URL"
              value={@provider_form["authorize_url"]}
              id="provider_authorize_url"
            />
            <.input
              :if={@provider_form["kind"] == "oauth2"}
              name="provider[token_url]"
              label="Token URL"
              value={@provider_form["token_url"]}
              id="provider_token_url"
            />
            <.input
              name="provider[revoke_url]"
              label="Revoke URL (optional)"
              value={@provider_form["revoke_url"]}
              id="provider_revoke_url"
            />
            <.input
              name="provider[userinfo_url]"
              label="Userinfo URL (optional)"
              value={@provider_form["userinfo_url"]}
              id="provider_userinfo_url"
            />
            <.input
              name="provider[account_label_path]"
              label="Account name path in userinfo"
              value={@provider_form["account_label_path"]}
              id="provider_account_label_path"
              placeholder="email"
            />
            <.input
              name="provider[scopes]"
              label="Scopes (space-separated)"
              value={@provider_form["scopes"]}
              id="provider_scopes"
            />
            <.input
              name="provider[client_id]"
              label="Client id"
              value={@provider_form["client_id"]}
              id="provider_client_id"
            />
            <.input
              name="provider[client_secret]"
              type="password"
              label={
                if @editing_id,
                  do: "Client secret (blank keeps the stored one)",
                  else: "Client secret"
              }
              value={@provider_form["client_secret"]}
              id="provider_client_secret"
            />
            <div class="space-y-1">
              <label
                for="provider_token_endpoint_auth"
                class="block text-sm font-medium text-zinc-700"
              >
                Client authentication
              </label>
              <select
                id="provider_token_endpoint_auth"
                name="provider[token_endpoint_auth]"
                class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"
              >
                <option
                  :for={
                    {label, v} <- [
                      {"Secret in the form body", "client_secret_post"},
                      {"HTTP basic", "client_secret_basic"},
                      {"None (public client)", "none"}
                    ]
                  }
                  value={v}
                  selected={@provider_form["token_endpoint_auth"] == v}
                >
                  {label}
                </option>
              </select>
            </div>
            <div class="space-y-1">
              <label for="provider_pkce" class="block text-sm font-medium text-zinc-700">PKCE</label>
              <select
                id="provider_pkce"
                name="provider[pkce]"
                class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"
              >
                <option value="true" selected={@provider_form["pkce"] == "true"}>On (S256)</option>
                <option value="false" selected={@provider_form["pkce"] == "false"}>Off</option>
              </select>
            </div>
            <.input
              name="provider[env_key]"
              label="Env var (blank derives from the slug)"
              value={@provider_form["env_key"]}
              id="provider_env_key"
              placeholder="GITHUB_ACCESS_TOKEN"
            />
            <.input
              name="provider[token_hosts]"
              label="Token hosts (space-separated)"
              value={@provider_form["token_hosts"]}
              id="provider_token_hosts"
              placeholder="api.github.com"
            />
          </div>
          <div class="flex gap-2">
            <button
              type="submit"
              class="rounded-md bg-zinc-900 px-3 py-2 text-sm text-white hover:bg-zinc-700"
              data-role="save-provider"
            >
              Save
            </button>
            <button
              type="button"
              phx-click="cancel_provider"
              class="rounded-md border border-[var(--color-border)] px-3 py-2 text-sm"
            >
              Cancel
            </button>
          </div>
        </form>

        <%!-- ── Remote MCP server ───────────────────────────────────────── --%>
        <form
          :if={@may_connect?}
          id="mcp-discover-form"
          phx-change="validate_mcp"
          phx-submit="discover"
          class="rounded-lg border border-dashed border-[var(--color-border)] p-4 space-y-2"
        >
          <h3 class="font-medium">Connect a remote MCP server</h3>
          <p class="text-xs text-[var(--color-text-secondary)]">
            Enter the server's URL. Fountain reads its authorization metadata and registers a
            client with the authorization server where it offers one, so there is no client id to
            type. Paste one below only for a server without registration.
          </p>
          <div class="flex gap-1 flex-wrap">
            <span class="text-xs text-[var(--color-text-secondary)] self-center">Verified:</span>
            <button
              :for={entry <- mcp_catalog()}
              type="button"
              phx-click="mcp_preset"
              phx-value-slug={entry.slug}
              title={entry.url}
              class="rounded-md border border-[var(--color-border)] px-2 py-0.5 text-xs"
            >
              {entry.name}
            </button>
          </div>
          <div class="flex gap-2">
            <input
              type="url"
              name="mcp_url"
              value={@mcp_url}
              placeholder="https://mcp.example.com/mcp"
              class="flex-1 rounded-md border border-zinc-300 px-3 py-2 text-sm"
              data-role="mcp-url"
            />
            <button
              type="submit"
              class="rounded-md bg-zinc-900 px-3 py-2 text-sm text-white hover:bg-zinc-700"
              data-role="discover"
            >
              Discover
            </button>
          </div>
          <details class="text-xs">
            <summary class="cursor-pointer text-[var(--color-text-secondary)]">
              Client id and secret (optional)
            </summary>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 mt-2">
              <input
                type="text"
                name="client_id"
                value={@mcp_client_id}
                placeholder="Client id"
                class="rounded-md border border-zinc-300 px-3 py-2 text-sm"
              />
              <input
                type="password"
                name="client_secret"
                value={@mcp_client_secret}
                placeholder="Client secret"
                class="rounded-md border border-zinc-300 px-3 py-2 text-sm"
              />
            </div>
          </details>
        </form>
      </section>

      <%!-- ── Connections ───────────────────────────────────────────────── --%>
      <section class="space-y-3" id="connections">
        <h2 class="text-lg font-medium">Connected accounts</h2>
        <div :if={@connections == []} class="text-sm text-[var(--color-text-secondary)]">
          No connections yet.
        </div>

        <div
          :for={c <- @connections}
          id={"connection-#{c.id}"}
          class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-4 flex items-start justify-between gap-4"
        >
          <div class="space-y-1 min-w-0">
            <div class="flex items-center gap-2">
              <span class="font-medium">{c.account_email}</span>
              <span
                class={[
                  "rounded-full px-2 py-0.5 text-xs",
                  c.status == "active" && "bg-green-100 text-green-800",
                  c.status == "expired" && "bg-amber-100 text-amber-800",
                  c.status == "revoked" && "bg-red-100 text-red-800"
                ]}
                data-role="status"
              >
                {c.status}
              </span>
            </div>
            <p class="text-xs text-[var(--color-text-secondary)]">
              {c.provider} · brokered as <code class="font-mono">{c.env_key}</code>
              · id <code class="font-mono">{c.id}</code>
            </p>
            <p :if={c.provider == "google"} class="text-xs text-[var(--color-text-secondary)]">
              In an agent's MCP servers:
              <code class="font-mono">{~s({"gmail": {"connection": "#{c.id}"}})}</code>
            </p>
            <p :if={c.provider != "google"} class="text-xs text-[var(--color-text-secondary)]">
              In an agent's MCP servers:
              <code class="font-mono">
                {~s({"<name>": {"type": "http", "url": "https://…/mcp", "connection": "#{c.id}"}})}
              </code>
              or a stdio server that reads <code class="font-mono">{c.env_key}</code>.
            </p>
            <p :if={c.status == "revoked"} class="text-xs text-red-700">
              Revoked {c.revoked_at}. Connect the account again to replace it.
            </p>
            <p :if={c.status == "expired"} class="text-xs text-amber-700">
              The access token expired and the provider issued no refresh token. Reconnect to
              continue.
            </p>
          </div>
          <div class="flex gap-2 shrink-0">
            <a
              :if={@may_connect? and c.status == "expired"}
              href={~p"/connections/#{c.provider_id || c.provider}/start?label=#{c.account_email}"}
              data-role="reconnect"
              class="rounded-md bg-zinc-900 px-3 py-1.5 text-sm text-white hover:bg-zinc-700"
            >
              Reconnect
            </a>
            <button
              :if={c.status == "active"}
              phx-click="revoke"
              phx-value-id={c.id}
              data-confirm="Revoke this connection? Agents that use it will fail with 'connection revoked' on their next call."
              class="rounded-md border border-[var(--color-border)] px-3 py-1.5 text-sm hover:bg-[var(--color-bg-2)]"
            >
              Revoke
            </button>
            <button
              phx-click="delete"
              phx-value-id={c.id}
              data-confirm="Remove this connection entirely?"
              class="rounded-md border border-[var(--color-border)] px-3 py-1.5 text-sm text-red-700 hover:bg-[var(--color-bg-2)]"
            >
              Remove
            </button>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
