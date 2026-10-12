defmodule FountainWeb.DocsController do
  @moduledoc """
  Serves the public documentation manual at `/docs`. Content is embedded at
  compile time by `Fountain.Docs`; rendering goes through the sanitizing
  `Managoat.Docs.Markdown` pipeline, same as `/help` (#323).

  Public, like the front door, and deliberately so: since the GitHub Pages
  copy was retired (#1008) this route is the only published manual, and the
  people who most need it — someone deciding whether to self-host, or reading
  `setup.md` before they have an account — have no session to authenticate.
  """
  use FountainWeb, :controller

  def show(conn, params) do
    slug = params |> Map.get("page", []) |> Enum.join("/")

    case Fountain.Docs.get(slug) do
      {:ok, page} ->
        render(conn, :show,
          layout: {FountainWeb.Layouts, :public},
          page_title: "Docs · " <> page.title,
          meta_description: "#{page.title}, from the #{Fountain.Brand.name()} manual.",
          nav: Fountain.Docs.nav(),
          slug: slug,
          title: page.title,
          body_html: Managoat.Docs.Markdown.to_trusted_html(page.body),
          search_index_json: Fountain.Docs.search_index_json()
        )

      :error ->
        conn
        |> put_status(:not_found)
        |> render(:not_found,
          layout: {FountainWeb.Layouts, :public},
          page_title: "Docs · Not found"
        )
    end
  end
end
