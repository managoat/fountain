defmodule FountainWeb.CatalogController do
  @moduledoc """
  `GET /api/catalog`: the instance's vocabulary a client needs to build the
  agent and environment forms — runtimes and their model suggestions,
  the sandbox providers usable here and the default, the package managers
  an environment accepts,
  where this instance's browser apps live (#866), and the remote MCP
  servers verified to complete connection discovery (#1322), and the first
  request (ADR 0038).

  Everything here is already public through the forms; this is the same
  lists over the API so a client on another origin does not hard-code them
  and drift from the server. `first_request` is that argument applied to the
  onboarding snippet: the verified landing prints it, `docs/quickstart.md`
  prints it, and `fountain auth register` prints it, so the text has to come
  from one place or the three will disagree. `Fountain.Onboarding` is that
  place; this is how a client that is not the server reaches it.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Agents.Agent
  alias Fountain.Agents.ModelCatalog
  alias Fountain.Onboarding
  alias Managoat.Runtimes.Model
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  tags(["Catalog"])

  operation(:show,
    summary: "The instance's form vocabulary",
    description:
      "Runtimes with model suggestions per runtime (suggestions, not an allowlist — " <>
        "any `provider/model` under a known provider is accepted), sandbox providers " <>
        "usable on this instance and the default, package managers an environment " <>
        "accepts, the URLs of the " <>
        "browser apps this instance sends people to for conversations and the team, " <>
        "and remote MCP servers verified to complete connection discovery " <>
        "(again suggestions — any URL can be discovered), each with the date " <>
        "it was last verified. Also `first_request`, the one onboarding " <>
        "snippet this deployment hands out, with its base URL already in it " <>
        "and the caller's own key and agent left as placeholders.",
    responses: [ok: {"Catalog", "application/json", Schemas.CatalogResponse}]
  )

  def show(conn, _params) do
    runtimes = Agent.runtimes()
    base_url = Fountain.PublicUrl.base()

    json(conn, %{
      data: %{
        sandbox_api_access: Fountain.Conversations.Conversation.sandbox_api_access_modes(),
        runtimes: runtimes,
        models: Map.new(runtimes, &{&1, ModelCatalog.suggestions(&1)}),
        model_providers: Model.providers(),
        sandbox_providers: %{
          enabled: Enum.map(Fountain.SandboxProviders.enabled_providers(), &Atom.to_string/1),
          default: Atom.to_string(Fountain.SandboxProviders.default_provider())
        },
        package_managers: Fountain.Conversations.Provisioning.package_managers(),
        # Where a human is sent to watch a conversation or message a teammate.
        # Null for an app this deployment does not have.
        apps: %{
          conversations: Fountain.Apps.conversations(),
          team: Fountain.Apps.team()
        },
        # The first request, from the one source the landing and the manual
        # share (ADR 0038). Rendered with this deployment's base URL, which
        # the server knows; the key and the agent stay placeholders, because
        # the server holds only a *hash* of the caller's key and cannot fill
        # one in. A client substitutes the key it already has and an agent it
        # resolves from `GET /api/agents`, and `placeholders` names the exact
        # tokens so it does not have to guess at them.
        first_request: first_request(base_url)
      }
    })
  end

  defp first_request(base_url) do
    curl = Onboarding.curl(base_url: base_url)

    # The TypeScript keeps its bare `new Fountain()`, and that is not an
    # oversight. The SDK resolves the key and the base URL exactly as the CLI
    # does — option, then environment, then `~/.fountain/credentials` — so a
    # constructor filled in here would be worse than the one the manual
    # prints: it would carry a base URL and no key, which reads as a complete
    # snippet and is not one. `curl` gets the base URL because `curl`
    # resolves nothing.
    typescript = Onboarding.typescript()

    %{
      curl: curl,
      typescript: typescript,
      prompt: Onboarding.prompt(),
      placeholders: Onboarding.remaining_placeholders(curl <> typescript)
    }
  end
end
