defmodule FountainWeb.StartLive do
  @moduledoc """
  `/start` — the verified landing (ADR 0038 decision 5, #1390).

  The first screen after verification. It hands over a key and one request,
  shows the reply on the same screen when it arrives, and then points at three
  doors. It does not onboard; it hands off.

  It replaced a three-item checklist on the dashboard — a credential, an
  agent, a conversation — which defined done as "three things exist", sent
  the third item to a different origin to click a button, and asked for an
  inference key before the product had done anything.

  ## Why the key is minted here

  A raw API key exists for exactly one render: `Accounts.create_api_key/3`
  stores a hash. So the mint has to happen on the screen that shows it, and
  only when the socket is connected, or the dead render would burn one key and
  the live render another. An account that already has a key is not given a
  second one silently — it gets the same "keys are shown once" sentence the
  API keys page uses, and a button.

  ## Why the reply arrives without polling the agent

  `Conversations` broadcasts `sidebar:<user_id>` on every log event and every
  conversation change — the same topic the console's sidebar counts on. The
  page subscribes to it and, while it has no reply yet, asks
  `Fountain.Activation.first_reply/1` on each nudge. So the reply that appears
  here is the row the funnel counted, not a second opinion about which reply
  was first.

  ## The events

  `onboarding.landing_viewed` and `onboarding.reply_shown` are this page's,
  and `onboarding.key_copied` rides on the copy button's `phx-click`. The
  funnel's third step, `onboarding.request_sent`, is deliberately **not**
  here: it is emitted server-side by `Fountain.Activation` when the account's
  first conversation is written, so a developer who copies the request and
  runs it after closing the tab still counts. `Activation.funnel_events/0`
  holds the four names.
  """
  use FountainWeb, :live_view

  alias Fountain.{Accounts, Activation, Agents, Analytics, Apps, InferenceCredentials, Onboarding}

  @key_label "quickstart"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    agent = default_agent(user.id)

    socket =
      socket
      |> assign(:page_title, "Start")
      |> assign(:agent, agent)
      |> assign(:base_url, Fountain.PublicUrl.base())
      |> assign(:conversations_app, Apps.conversations())
      |> assign(:raw_key, nil)
      |> assign(:has_key?, Accounts.list_api_keys(user.id) != [])
      |> assign(:reply, Activation.first_reply(user.id))
      |> assign(:sent?, false)
      |> assign(:needs_credential?, needs_credential?(user.id, agent))

    {:ok, if(connected?(socket), do: on_connect(socket, user), else: socket)}
  end

  defp on_connect(socket, user) do
    Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user.id}")

    Analytics.capture("onboarding.landing_viewed", user, %{
      "has_agent" => socket.assigns.agent != nil,
      "already_replied" => socket.assigns.reply != nil,
      "source" => "console"
    })

    socket
    |> assign(:sent?, Fountain.Conversations.conversation_counts(user.id).total > 0)
    |> mint_first_key(user)
  end

  # Only when the account has none. A developer who lands here twice is not
  # given a second key behind their back; the page says so and offers one.
  defp mint_first_key(%{assigns: %{has_key?: true}} = socket, _user), do: socket
  defp mint_first_key(socket, user), do: mint(socket, user)

  defp mint(socket, user) do
    case Accounts.create_api_key(user.id, @key_label, FountainWeb.Audited.attribution(socket)) do
      {:ok, {_key, raw}} -> socket |> assign(:raw_key, raw) |> assign(:has_key?, true)
      {:error, _} -> put_flash(socket, :error, "Could not create an API key.")
    end
  end

  # Will this request reach a model at all?
  #
  # `InferenceCredentials.select/2` is the one selection rule (#1388): the
  # tenant's own key wins, this deployment's platform key covers an account
  # that has none, and `{:error, :no_credential}` is the case where the
  # sandbox starts and the agent has nothing to call. The page says so rather
  # than letting a copied `curl` fail with a provider's auth error the
  # developer has to go and decode.
  #
  # Asked here rather than reimplemented, so a deployment that turns a
  # platform key on stops showing the banner with no change to this file. It
  # is also the reason the banner is per-*agent*: `select/2` keys off the
  # model's provider, and an account holding an Anthropic key still has
  # nothing for an agent on a `gemini` model.
  defp needs_credential?(_user_id, nil), do: false

  defp needs_credential?(user_id, agent) do
    with {:ok, dek} <- Fountain.Crypto.load_tenant_key(user_id),
         {:ok, own} <- InferenceCredentials.decrypted_for_user(user_id, dek) do
      match?(
        {:error, :no_credential},
        InferenceCredentials.select(agent.model, own, agent.runtime,
          brokered: Fountain.Broker.configured?(),
          refresh: false
        )
      )
    else
      # A tenant key that will not load is a bigger problem than this banner,
      # and it is not this page's to report.
      _ -> false
    end
  end

  # The agent the first request runs against. `Fountain.Agents.Starter` plants
  # a `starter` at verification (#1389), so an account has one from the moment
  # it exists. The fallback is not dead code: the starter is an ordinary agent
  # and may be renamed or deleted, and every account verified before #1389
  # never had one. Any agent will do, oldest first. This page never creates
  # one of its own.
  defp default_agent(user_id) do
    agents = Agents.list_agents(user_id, [])

    Enum.find(agents, &(&1.name == "starter")) ||
      Enum.min_by(agents, & &1.inserted_at, DateTime, fn -> nil end)
  end

  @impl true
  def handle_event("key_copied", _params, socket) do
    Analytics.capture("onboarding.key_copied", socket.assigns.current_user, %{
      "source" => "console"
    })

    {:noreply, socket}
  end

  def handle_event("new_key", _params, socket) do
    {:noreply, mint(socket, socket.assigns.current_user)}
  end

  @impl true
  def handle_info({:sidebar_update, _user_id}, socket) do
    {:noreply, refresh_reply(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Cheap while it matters: once the reply is on screen the page stops asking,
  # and a chatty run broadcasts on every log event.
  defp refresh_reply(%{assigns: %{reply: reply}} = socket) when not is_nil(reply), do: socket

  defp refresh_reply(socket) do
    user = socket.assigns.current_user

    case Activation.first_reply(user.id) do
      nil ->
        assign(socket, :sent?, Fountain.Conversations.conversation_counts(user.id).total > 0)

      reply ->
        Analytics.capture("onboarding.reply_shown", user, %{
          "conversation_id" => reply.conversation_id,
          "source" => "console"
        })

        socket |> assign(:reply, reply) |> assign(:sent?, true)
    end
  end

  defp curl(assigns) do
    Onboarding.curl(
      base_url: assigns.base_url,
      api_key: assigns.raw_key,
      agent_id: assigns.agent && assigns.agent.id
    )
  end

  defp typescript(assigns) do
    Onboarding.typescript(
      base_url: assigns.base_url,
      api_key: assigns.raw_key,
      agent: assigns.agent && assigns.agent.name
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8 max-w-3xl">
      <div>
        <h1 class="text-2xl font-semibold">Your key, one request, the reply</h1>
        <%!-- Not "you need nothing else": while BYO inference is the rule
              (#1388), the banner under this line asks for one thing, and a
              headline that contradicts the next paragraph reads as a lie. --%>
        <p class="mt-1 text-sm text-[var(--color-text-secondary)]">
          Everything below is ready to paste. No repository, no GitHub token, and nothing
          to install.
        </p>
      </div>

      <%!-- The one wall left on this path, and it is honest about itself. --%>
      <.link
        :if={@needs_credential?}
        navigate={~p"/account/inference-credentials"}
        class="block rounded-lg border border-amber-300 bg-amber-50 p-4 text-amber-900 hover:border-amber-500"
      >
        <p class="text-sm font-medium">This account has no inference credential yet</p>
        <p class="mt-1 text-sm">
          This deployment holds no model key for your agent's provider either, so the
          request below reaches a sandbox and the agent in it has nothing to call. Add
          an Anthropic, OpenAI or Google key first. It takes a minute.
        </p>
      </.link>

      <%!-- 1. The key. Shown once, because only a hash is stored. --%>
      <section class="rounded-lg border border-[var(--color-border)] p-5 space-y-3">
        <h2 class="text-sm font-semibold">1. Your API key</h2>

        <div :if={@raw_key} class="space-y-2">
          <div class="flex items-center gap-2">
            <code
              id="start-api-key"
              class="flex-1 bg-[var(--color-bg-2)] rounded border border-[var(--color-border)] px-3 py-2 text-sm font-mono break-all"
            >{@raw_key}</code>
            <.button
              id="copy-start-api-key"
              phx-hook="CopyToClipboard"
              phx-click="key_copied"
              data-target="start-api-key"
              variant="secondary"
            >
              Copy
            </.button>
          </div>
          <p class="text-xs text-[var(--color-text-muted)]">
            Shown once. It is already in the request below, so you can skip straight to
            step 2 and come back for it later from <.link navigate={~p"/api-keys"} class="underline">API keys</.link>.
          </p>
        </div>

        <div :if={!@raw_key and @has_key?} class="space-y-2">
          <p class="text-sm text-[var(--color-text-secondary)]">
            This account already has a key, and a key is shown once. Create another to fill
            in the request below.
          </p>
          <.button phx-click="new_key" variant="secondary">Create another key</.button>
        </div>

        <%!-- Neither a raw key nor a stored one. The mint happens on the
              connected mount, so this is the dead render, a browser with no
              JavaScript, or a mint that failed — and in none of those is it
              true that the account already has a key. --%>
        <div :if={!@raw_key and !@has_key?} class="space-y-2">
          <p class="text-sm text-[var(--color-text-secondary)]">
            This account has no API key yet.
          </p>
          <.button phx-click="new_key" variant="secondary">Create a key</.button>
        </div>
      </section>

      <%!-- 2. The request. The same text docs/quickstart.md prints. --%>
      <section class="rounded-lg border border-[var(--color-border)] p-5 space-y-4">
        <div>
          <h2 class="text-sm font-semibold">2. Send one request</h2>
          <p :if={@agent} class="mt-1 text-sm text-[var(--color-text-secondary)]">
            Against your <strong>{@agent.name}</strong>
            agent. It starts a sandbox, runs the agent in it, and answers.
          </p>
          <p :if={!@agent} class="mt-1 text-sm text-[var(--color-text-secondary)]">
            You have no agent yet, so the request below still has a placeholder in it.
            <.link navigate={~p"/agents/new"} class="underline">Create one</.link>
            and this page fills it in.
          </p>
        </div>

        <div class="space-y-2">
          <div class="flex items-center justify-between">
            <span class="text-xs font-medium text-[var(--color-text-muted)]">curl</span>
            <.button
              id="copy-start-curl"
              phx-hook="CopyToClipboard"
              data-target="start-curl"
              variant="ghost"
            >
              Copy
            </.button>
          </div>
          <pre class="bg-[var(--color-bg-2)] rounded border border-[var(--color-border)] px-3 py-2 text-xs font-mono overflow-x-auto"><code id="start-curl">{curl(assigns)}</code></pre>
        </div>

        <div class="space-y-2">
          <div class="flex items-center justify-between">
            <span class="text-xs font-medium text-[var(--color-text-muted)]">
              TypeScript SDK
            </span>
            <.button
              id="copy-start-ts"
              phx-hook="CopyToClipboard"
              data-target="start-ts"
              variant="ghost"
            >
              Copy
            </.button>
          </div>
          <pre class="bg-[var(--color-bg-2)] rounded border border-[var(--color-border)] px-3 py-2 text-xs font-mono overflow-x-auto"><code id="start-ts">{typescript(assigns)}</code></pre>
          <p class="text-xs text-[var(--color-text-muted)]">
            <code class="font-mono">npm install @managoat/fountain-sdk</code>
          </p>
        </div>
      </section>

      <%!-- 3. The reply, on this screen. --%>
      <section class="rounded-lg border border-[var(--color-border)] p-5 space-y-3">
        <h2 class="text-sm font-semibold">3. The reply</h2>

        <div :if={@reply} class="space-y-3" id="start-reply">
          <blockquote class="bg-[var(--color-bg-2)] rounded border border-[var(--color-border)] px-4 py-3 text-sm whitespace-pre-wrap">
            {@reply.text}
          </blockquote>
          <p class="text-sm">
            <strong>That reply came from your agent</strong>, running in a sandbox Fountain
            started for it. That is the whole product.
          </p>
          <p :if={@conversations_app} class="text-sm">
            <a href={Apps.conversation_url(@reply.conversation_id)} class="underline">
              Watch the rest of it in the conversations app ↗
            </a>
          </p>
        </div>

        <p :if={!@reply and @sent?} class="text-sm text-[var(--color-text-secondary)]">
          Your request is running. The first sandbox takes a few seconds to start. The
          reply appears here.
        </p>

        <p :if={!@reply and !@sent?} class="text-sm text-[var(--color-text-secondary)]">
          Nothing has run on this account yet. Send the request above and the reply
          appears here.
        </p>
      </section>

      <%!-- 4. The doors, below the fold. --%>
      <section class="space-y-3">
        <h2 class="text-lg font-medium">Where to go next</h2>
        <div class="grid gap-4 sm:grid-cols-3">
          <.link
            navigate={~p"/account/inference-credentials"}
            class="rounded-lg border border-[var(--color-border)] p-4 hover:border-[var(--color-border-strong)]"
          >
            <div class="text-sm font-medium">Add your own inference key</div>
            <p class="mt-1 text-xs text-[var(--color-text-secondary)]">
              Anthropic, OpenAI or Google. Yours wins over anything this instance supplies.
            </p>
          </.link>
          <a
            href="/docs/cli"
            class="rounded-lg border border-[var(--color-border)] p-4 hover:border-[var(--color-border-strong)]"
          >
            <div class="text-sm font-medium">Your own agents, from a file</div>
            <p class="mt-1 text-xs text-[var(--color-text-secondary)]">
              <code class="font-mono">fountain apply</code>
              takes a manifest of agents, environments and vaults.
            </p>
          </a>
          <a
            href="/docs/sdk"
            class="rounded-lg border border-[var(--color-border)] p-4 hover:border-[var(--color-border-strong)]"
          >
            <div class="text-sm font-medium">The SDK, for real code</div>
            <p class="mt-1 text-xs text-[var(--color-text-secondary)]">
              TypeScript, Python, Elixir and Swift over the same API.
            </p>
          </a>
        </div>
      </section>
    </div>
    """
  end
end
