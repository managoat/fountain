defmodule FountainWeb.HelpRedirectController do
  @moduledoc """
  Where the old in-app help went (ADR 0076).

  `/help` and `/help/:topic` were a LiveView over curated markdown in
  `priv/help/`. That content was folded into the manual, and these routes
  stay only so a bookmark, an old email or an agent's saved instructions
  still land somewhere useful: each retired topic goes to the manual page
  that took it, and anything else goes to the manual's home. The manual is
  published at `DOCS_URL` (decisions/0081), so the redirect goes straight
  there rather than through this server's own `/docs` redirect.

  The map is static on purpose. The topics are a closed, retired set; a test
  checks every target against the slugs `docs/nav.yml` names, so a docs page
  renamed later breaks the build rather than a redirect.
  """
  use FountainWeb, :controller

  @topics %{
    "quickstart" => "quickstart",
    "agents" => "concepts/agent",
    "skills" => "catalog/skills",
    "environments" => "concepts/environment",
    "vaults" => "concepts/vault",
    "manifest" => "guides/manifests",
    "spawning" => "catalog/skills/fountain",
    "api" => "api",
    "secrets-managers" => "guides/manifests",
    "for-llms" => "llm-integration",
    "runbook" => "self-hosting"
  }

  @doc "The retired topic slugs and the manual slug each redirects to."
  @spec topics() :: %{String.t() => String.t()}
  def topics, do: @topics

  def show(conn, %{"topic" => topic}) do
    case Map.fetch(@topics, topic) do
      {:ok, slug} -> redirect(conn, external: Fountain.DocsUrl.url("/docs/" <> slug))
      :error -> home(conn)
    end
  end

  def show(conn, _params), do: home(conn)

  defp home(conn), do: redirect(conn, external: Fountain.DocsUrl.url("/docs"))
end
