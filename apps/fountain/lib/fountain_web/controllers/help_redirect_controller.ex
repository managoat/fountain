defmodule FountainWeb.HelpRedirectController do
  @moduledoc """
  Where the old in-app help went (ADR 0076).

  `/help` and `/help/:topic` were a LiveView over curated markdown in
  `priv/help/`. That content was folded into the public manual at `/docs`,
  and these routes stay only so a bookmark, an old email or an agent's saved
  instructions still land somewhere useful: each retired topic goes to the
  `/docs` page that took it, and anything else goes to the manual's home.

  The map is static on purpose. The topics are a closed, retired set; a test
  checks every target against `Fountain.Docs.slugs/0`, so a docs page renamed
  later breaks the build rather than a redirect.
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

  @doc "The retired topic slugs and the `/docs` slug each redirects to."
  @spec topics() :: %{String.t() => String.t()}
  def topics, do: @topics

  def show(conn, %{"topic" => topic}) do
    case Map.fetch(@topics, topic) do
      {:ok, slug} -> redirect(conn, to: "/docs/" <> slug)
      :error -> redirect(conn, to: ~p"/docs")
    end
  end

  def show(conn, _params), do: redirect(conn, to: ~p"/docs")
end
