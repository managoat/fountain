defmodule Mix.Tasks.Site.Build do
  @shortdoc "Render the site into dist/"
  @moduledoc "`mix site.build [DIR]` renders every page and copies the assets into DIR (default `dist`)."
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    out = List.first(args) || "dist"
    Site.Build.run(out)
    Mix.shell().info("rendered #{length(Site.Build.pages())} pages into #{out}/")
  end
end
