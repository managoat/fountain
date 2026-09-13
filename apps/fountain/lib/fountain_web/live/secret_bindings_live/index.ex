defmodule FountainWeb.SecretBindingsLive.Index do
  @moduledoc """
  `/account/bindings` — which hosts each secret is attached to at the egress
  broker, and how (ADR 0019 gate 1b).

  Only on a deployment that runs the broker: the nav link is hidden otherwise,
  and a direct visit is sent to `/account`. The page never sees a value —
  it lists the names of the secrets the account holds anywhere, and the
  bindings on each name. The `connections` rollout flag decides whether a
  credential can be sent anywhere new from here. With it off the page still
  lists the bindings, still disables one and still unbinds it; the form is
  gone, and so is the button that would enable a disabled binding (#1693).
  """

  use FountainWeb, :live_view

  alias Fountain.Broker
  alias Fountain.SecretBindings
  alias Fountain.SecretBindings.Binding
  alias Fountain.SecretBindings.Catalog

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # Open for any brokered account. A binding that is attaching a credential
    # right now has to be visible and removable whatever the rollout flag
    # says; `may_bind?` is the flag, and it gates only the form (#1693).
    if Fountain.Connections.manageable_for?() do
      {:ok,
       socket
       |> assign(:page_title, "Credential bindings")
       |> assign(:user_id, user.id)
       |> assign(:may_bind?, Fountain.Connections.enabled_for?(user.id))
       |> assign(:proxy_host, Broker.proxy_host())
       |> assign(:presets, Catalog.presets())
       |> assign(:form_version, 0)
       |> assign(:draft, blank_draft())
       |> reload()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Egress credential brokerage is not enabled for this account.")
       |> push_navigate(to: ~p"/account")}
    end
  end

  # ── events ───────────────────────────────────────────────────────────────

  # The events that make a new binding, refused in one place for an account
  # without the rollout flag. The template hides the form; a hidden form is
  # not a gate. `delete` is not here: it takes a binding away, and that is
  # exactly what must keep working.
  #
  # `toggle` is not here either, and not because it is safe: it writes
  # `enabled: not enabled`, so its name says nothing about which way it goes.
  # Disabling is the soft off switch; enabling starts a credential flowing to
  # a host it was not flowing to, which is the same act the API's `update`
  # needs the flag for. A name cannot tell the two apart, so the direction of
  # the write is gated instead, in `handle_event("toggle", ...)` below.
  @binding_new ~w(draft pick_key preset save)

  @impl true
  def handle_event(event, _params, %{assigns: %{may_bind?: false}} = socket)
      when event in @binding_new do
    {:noreply,
     put_flash(
       socket,
       :error,
       "New bindings are off for this account. You can still disable or unbind the ones you have."
     )}
  end

  # Keeps the form's shape in step with the auth type and the preset pick,
  # so only the fields of the chosen type are shown and submitted — the
  # broker rejects a stale field from a previous choice.
  def handle_event("draft", %{"binding" => attrs}, socket) do
    draft =
      Map.merge(
        socket.assigns.draft,
        Map.take(attrs, ~w(key host auth_type header prefix username headers_text))
      )

    {:noreply, assign(socket, :draft, draft)}
  end

  def handle_event("pick_key", %{"key" => key}, socket) do
    draft = Map.put(socket.assigns.draft, "key", key)

    # A preset that usually goes by this name prefills the rest.
    draft =
      case Catalog.for_key(key) do
        [preset | _] ->
          Map.merge(draft, %{
            "host" => preset.host,
            "auth_type" => preset.auth_type,
            "header" => preset.header || "",
            "prefix" => preset.prefix || "",
            "headers_text" => headers_to_text(preset.headers)
          })

        [] ->
          draft
      end

    {:noreply, socket |> assign(:draft, draft) |> update(:form_version, &(&1 + 1))}
  end

  def handle_event("preset", %{"id" => id}, socket) do
    case Catalog.get(id) do
      nil ->
        {:noreply, socket}

      preset ->
        key = presence(socket.assigns.draft["key"]) || preset.suggested_key || ""

        draft = %{
          "key" => key,
          "host" => preset.host,
          "auth_type" => preset.auth_type,
          "header" => preset.header || "",
          "prefix" => preset.prefix || "",
          "username" => "",
          "headers_text" => headers_to_text(preset.headers)
        }

        {:noreply, socket |> assign(:draft, draft) |> update(:form_version, &(&1 + 1))}
    end
  end

  def handle_event("save", %{"binding" => attrs}, socket) do
    attrs = to_attrs(attrs)

    case SecretBindings.create_binding(
           socket.assigns.user_id,
           attrs,
           FountainWeb.Audited.attribution(socket)
         ) do
      {:ok, binding} ->
        {:noreply,
         socket
         |> assign(:draft, blank_draft())
         |> update(:form_version, &(&1 + 1))
         |> reload()
         |> put_flash(:info, "#{binding.key} is now attached to #{binding.host}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:draft, Map.merge(socket.assigns.draft, attrs_to_draft(attrs)))
         |> put_flash(:error, changeset_error(changeset))}
    end
  end

  # Which way this one goes decides which gate it is under: disabling a binding
  # is the off switch and stays open, enabling one attaches a credential to a
  # host again and needs the flag (#1693).
  def handle_event("toggle", %{"id" => id}, socket) do
    binding = SecretBindings.get_binding(id, socket.assigns.user_id)

    cond do
      is_nil(binding) ->
        {:noreply, put_flash(socket, :error, "Binding not found")}

      not binding.enabled and not socket.assigns.may_bind? ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "New bindings are off for this account, and enabling this one would make it " <>
             "attach #{binding.key} to #{binding.host} again."
         )}

      true ->
        flip(socket, binding)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case SecretBindings.get_binding(id, socket.assigns.user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Binding not found")}

      binding ->
        {:ok, _} = SecretBindings.delete_binding(binding, FountainWeb.Audited.attribution(socket))

        {:noreply,
         socket |> reload() |> put_flash(:info, "Unbound #{binding.key} from #{binding.host}")}
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp flip(socket, %Binding{} = binding) do
    case SecretBindings.update_binding(
           binding,
           %{"enabled" => not binding.enabled},
           FountainWeb.Audited.attribution(socket)
         ) do
      {:ok, updated} ->
        word = if updated.enabled, do: "enabled", else: "disabled"

        {:noreply,
         socket |> reload() |> put_flash(:info, "#{updated.key} → #{updated.host} #{word}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Binding not found")}
    end
  end

  defp reload(socket) do
    user_id = socket.assigns.user_id
    bindings = SecretBindings.list_bindings(user_id)
    known = SecretBindings.known_keys(user_id)
    bound = bindings |> Enum.map(& &1.key) |> Enum.uniq()

    socket
    |> assign(:bindings, bindings)
    |> assign(:by_key, Enum.group_by(bindings, & &1.key))
    |> assign(:known_keys, known)
    |> assign(:unbound_keys, Enum.reject(known, &(&1 in bound)))
    |> assign(:catalog_keys, Broker.catalog_keys())
  end

  defp blank_draft do
    %{
      "key" => "",
      "host" => "",
      "auth_type" => "substitute",
      "header" => "",
      "prefix" => "",
      "username" => "",
      "headers_text" => ""
    }
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(s), do: s

  defp to_attrs(params) do
    params
    |> Map.take(~w(key host auth_type header prefix username))
    |> Map.put("headers", text_to_headers(params["headers_text"] || ""))
  end

  defp attrs_to_draft(attrs) do
    attrs
    |> Map.take(~w(key host auth_type header prefix username))
    |> Map.put("headers_text", headers_to_text(attrs["headers"] || %{}))
  end

  # One `Name: template` per line. `{{ KEY }}` in a template is replaced by
  # the secret at the broker.
  defp text_to_headers(text) do
    text
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.split(&1, ":", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Map.new(fn [name, value] -> {String.trim(name), String.trim(value)} end)
  end

  defp headers_to_text(headers) when is_map(headers) do
    headers |> Enum.map(fn {k, v} -> "#{k}: #{v}" end) |> Enum.sort() |> Enum.join("\n")
  end

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        Enum.find_value(opts, "", fn {k, v} -> if Atom.to_string(k) == key, do: to_string(v) end)
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp auth_label("substitute"), do: "Replace the placeholder wherever it appears"
  defp auth_label("bearer"), do: "Add a bearer header"
  defp auth_label("basic"), do: "Basic auth (secret is the password)"
  defp auth_label("api_key"), do: "API key header"
  defp auth_label("custom"), do: "Custom headers"

  defp auth_summary(%Binding{auth_type: "substitute"}),
    do: "placeholder → <secret>, anywhere in the request"

  defp auth_summary(%Binding{auth_type: "bearer"}), do: "Authorization: Bearer <secret>"
  defp auth_summary(%Binding{auth_type: "basic", username: u}), do: "Basic #{u}:<secret>"
  defp auth_summary(%Binding{auth_type: "api_key", header: h, prefix: nil}), do: "#{h}: <secret>"
  defp auth_summary(%Binding{auth_type: "api_key", header: h, prefix: ""}), do: "#{h}: <secret>"

  defp auth_summary(%Binding{auth_type: "api_key", header: h, prefix: p}),
    do: "#{h}: #{p}<secret>"

  defp auth_summary(%Binding{auth_type: "custom", headers: hs}),
    do: hs |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8 max-w-4xl">
      <div>
        <h1 class="text-2xl font-semibold">Credential bindings</h1>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1 max-w-2xl">
          Your sandboxes reach the internet only through the egress broker at <code class="font-mono">{@proxy_host}</code>. A secret you bind here never enters a
          sandbox: the agent sees a placeholder, and the broker attaches the real value to
          requests for the hosts you name. A secret with no binding reaches the sandbox in the
          clear, as before.
        </p>
      </div>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Bound secrets</h2>
        <div :if={@bindings == []} class="text-sm text-[var(--color-text-secondary)]">
          No bindings yet. <code class="font-mono">GITHUB_TOKEN</code>
          and <code class="font-mono">GH_TOKEN</code>
          are attached to GitHub by default until you
          bind them yourself.
        </div>
        <div
          :for={{key, bindings} <- @by_key}
          id={"key-#{key}"}
          class="rounded border border-[var(--color-border)]"
        >
          <div class="px-3 py-2 border-b border-[var(--color-border)] flex items-center gap-2">
            <span class="font-mono text-sm">{key}</span>
            <span
              :if={key not in @known_keys}
              class="text-xs text-amber-600"
              title="No environment or vault holds a secret of this name right now"
            >
              not stored anywhere yet
            </span>
          </div>
          <table class="w-full text-sm">
            <tbody>
              <tr
                :for={b <- bindings}
                id={"binding-#{b.id}"}
                class={[
                  "border-b border-[var(--color-border)] last:border-0",
                  !b.enabled && "opacity-60"
                ]}
              >
                <td class="px-3 py-2 font-mono">{b.host}</td>
                <td class="px-3 py-2 text-[var(--color-text-secondary)]">{auth_summary(b)}</td>
                <td class="px-3 py-2 text-xs">
                  <span :if={b.enabled} class="text-emerald-600">enabled</span>
                  <span :if={!b.enabled} class="text-zinc-500">disabled</span>
                </td>
                <td class="px-3 py-2 text-right whitespace-nowrap space-x-2">
                  <.btn_secondary
                    :if={b.enabled or @may_bind?}
                    phx-click="toggle"
                    phx-value-id={b.id}
                  >
                    {if b.enabled, do: "Disable", else: "Enable"}
                  </.btn_secondary>
                  <.btn_danger phx-click="delete" phx-value-id={b.id} data-confirm="Unbind?">
                    Unbind
                  </.btn_danger>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section :if={@may_bind? and @unbound_keys != []} class="space-y-2">
        <h2 class="text-lg font-medium">Secrets with no binding</h2>
        <p class="text-sm text-[var(--color-text-secondary)]">
          These reach the sandbox in the clear. Bind the ones that are credentials for a host.
        </p>
        <div class="flex flex-wrap gap-2">
          <button
            :for={key <- @unbound_keys}
            type="button"
            phx-click="pick_key"
            phx-value-key={key}
            class="font-mono text-xs rounded border border-[var(--color-border)] px-2 py-1"
            title={if key in @catalog_keys, do: "Attached to GitHub by default", else: "Not brokered"}
            id={"unbound-#{key}"}
          >
            {key}<span :if={key in @catalog_keys} class="ml-1 text-emerald-600">(GitHub default)</span>
          </button>
        </div>
      </section>

      <section :if={!@may_bind?} data-role="bind-disabled" class="text-sm text-amber-900">
        New bindings are off for this account. The bindings above keep attaching their
        secrets, and you can disable or unbind any of them.
      </section>

      <section :if={@may_bind?} class="space-y-3">
        <h2 class="text-lg font-medium">Bind a secret to a host</h2>
        <div class="flex flex-wrap gap-1 items-center text-xs">
          <span class="text-[var(--color-text-secondary)] mr-1">Start from a known service:</span>
          <button
            :for={p <- @presets}
            :if={p.usable}
            type="button"
            phx-click="preset"
            phx-value-id={p.id}
            class="rounded border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-bg-1)]"
            title={"#{p.host} · #{p.auth_type}" <> if(p.suggested_key, do: " · usually #{p.suggested_key}", else: "")}
            id={"preset-#{p.id}"}
          >
            {p.name}
          </button>
        </div>

        <form
          id={"binding-form-#{@form_version}"}
          phx-change="draft"
          phx-submit="save"
          class="space-y-3 rounded border border-[var(--color-border)] p-4"
        >
          <div class="grid gap-3 sm:grid-cols-2">
            <div class="space-y-1">
              <label for="binding_key" class="block text-sm font-medium">Secret name</label>
              <input
                id="binding_key"
                name="binding[key]"
                type="text"
                list="known-keys"
                value={@draft["key"]}
                placeholder="STRIPE_SECRET_KEY"
                pattern="[A-Z][A-Z0-9_]*"
                required
                class="block w-full rounded-md border px-3 py-2 text-sm font-mono bg-[var(--color-bg-1)]"
              />
              <datalist id="known-keys">
                <option :for={k <- @known_keys} value={k} />
              </datalist>
            </div>
            <div class="space-y-1">
              <label for="binding_host" class="block text-sm font-medium">Host</label>
              <input
                id="binding_host"
                name="binding[host]"
                type="text"
                value={@draft["host"]}
                placeholder="api.example.com, *.example.com, host:port, host/path/*"
                required
                class="block w-full rounded-md border px-3 py-2 text-sm font-mono bg-[var(--color-bg-1)]"
              />
            </div>
          </div>

          <fieldset class="space-y-1">
            <legend class="text-sm font-medium">How the secret is sent</legend>
            <p class="text-xs text-[var(--color-text-secondary)]">
              The agent sees <code class="font-mono">__key__</code>
              in place of the secret. By default the
              broker swaps it for the real value wherever it turns up in a request to this host, so the
              agent uses it exactly as it would the secret. Pick a header shape only for an API the agent
              cannot address itself, or basic auth, which the client encodes before it leaves.
            </p>
            <div class="flex flex-wrap gap-3 text-sm">
              <label :for={t <- Binding.auth_types()} class="flex items-center gap-1">
                <input
                  type="radio"
                  name="binding[auth_type]"
                  value={t}
                  checked={@draft["auth_type"] == t}
                />
                {auth_label(t)}
              </label>
            </div>
          </fieldset>

          <div :if={@draft["auth_type"] == "basic"} class="space-y-1">
            <label for="binding_username" class="block text-sm font-medium">Username</label>
            <input
              id="binding_username"
              name="binding[username]"
              type="text"
              value={@draft["username"]}
              placeholder="x-access-token"
              class="block w-full rounded-md border px-3 py-2 text-sm font-mono bg-[var(--color-bg-1)]"
            />
            <p class="text-xs text-[var(--color-text-secondary)]">The secret is the password.</p>
          </div>

          <div :if={@draft["auth_type"] == "api_key"} class="grid gap-3 sm:grid-cols-2">
            <div class="space-y-1">
              <label for="binding_header" class="block text-sm font-medium">Header</label>
              <input
                id="binding_header"
                name="binding[header]"
                type="text"
                value={@draft["header"]}
                placeholder="Authorization"
                class="block w-full rounded-md border px-3 py-2 text-sm font-mono bg-[var(--color-bg-1)]"
              />
            </div>
            <div class="space-y-1">
              <label for="binding_prefix" class="block text-sm font-medium">Prefix</label>
              <input
                id="binding_prefix"
                name="binding[prefix]"
                type="text"
                value={@draft["prefix"]}
                placeholder="Token "
                class="block w-full rounded-md border px-3 py-2 text-sm font-mono bg-[var(--color-bg-1)]"
              />
              <p class="text-xs text-[var(--color-text-secondary)]">
                Text placed before the value, with its trailing space.
              </p>
            </div>
          </div>

          <div :if={@draft["auth_type"] == "custom"} class="space-y-1">
            <label for="binding_headers_text" class="block text-sm font-medium">Headers</label>
            <textarea
              id="binding_headers_text"
              name="binding[headers_text]"
              rows="3"
              placeholder="X-Api-Key: {{ STRIPE_SECRET_KEY }}\nX-Account: acct_123"
              class="block w-full rounded-md border px-3 py-2 text-sm font-mono bg-[var(--color-bg-1)]"
            >{@draft["headers_text"]}</textarea>
            <p class="text-xs text-[var(--color-text-secondary)]">
              One <code>Name: value</code>
              per line. <code>{"{{ KEY }}"}</code>
              is replaced by that secret at the broker.
            </p>
          </div>

          <div class="flex items-center gap-3">
            <.btn type="submit">Bind</.btn>
            <span class="text-xs text-[var(--color-text-secondary)]">
              The secret's name is enough; its value stays where it is stored.
            </span>
          </div>
        </form>
      </section>
    </div>
    """
  end
end
