defmodule Site.Brand do
  @moduledoc """
  The project's name, its icons, and who to talk to about it.

  The icons are the same files the server ships in `priv/static`, copied
  into `priv/site/images/brand/` and published under `/site/images/brand/`,
  so the site needs no other host to render.
  """

  @assets ~w(app-icon.png apple-touch-icon.png favicon-32x32.png favicon-16x16.png favicon.ico og-card.png mark-mono.png)

  @doc "The project."
  def name, do: "Managoat"

  @doc "Who to talk to about the project. Every call to action on the site lands here."
  def contact_name, do: "Jake"

  @doc "The address behind `contact_name/0`."
  def contact_email, do: "jhgaylor@gmail.com"

  @doc "The `mailto:` link every call to action uses."
  def contact_url, do: "mailto:" <> contact_email()

  @doc "The files `asset/1` and `asset_url/1` name."
  def assets, do: @assets

  @doc "The path one icon file is published at, on this site."
  def asset(name) when name in @assets, do: "/site/images/brand/" <> name

  @doc "The absolute URL of one icon file, for a card a scraper fetches from elsewhere."
  def asset_url(name), do: site_url() <> asset(name)

  @doc "Where the site is published; every absolute link and card URL starts here."
  def site_url, do: "https://managoat.com"

  @doc "The project's repository."
  def repo_url, do: "https://github.com/managoat/managoat"
end
