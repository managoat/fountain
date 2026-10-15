defmodule Mix.Tasks.Site.CheckLinks do
  @shortdoc "Check every link into the app's manual against the live host"
  @moduledoc """
  `mix site.check_links [HOST]` renders the pages and requests every distinct
  `/docs/...` link (and the other app paths the pages name) from HOST, default
  `https://managoat.com`. A renamed manual page used to fail
  `marketing_controller_test.exs` in the fountain repo, which resolved each link
  through `Fountain.Manual`; the site is not in that repo any more, so it asks
  the deployed manual instead. Anchors are not checked.
  """
  use Mix.Task

  @app_prefixes ["/docs", "/auth/"]

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    host = List.first(args) || Site.Brand.site_url()

    links =
      for page <- Site.Build.pages(),
          html = Site.Build.render(page),
          [href] <- Regex.scan(~r/href="(\/[^"#?]*)/, html, capture: :all_but_first),
          Enum.any?(@app_prefixes, &String.starts_with?(href, &1)),
          uniq: true,
          do: href

    Mix.shell().info("checking #{length(links)} app links on #{host}")

    failures =
      links
      |> Task.async_stream(&{&1, status(host <> &1)}, max_concurrency: 8, timeout: 30_000)
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.reject(fn {_, status} -> status in 200..399 end)

    if failures == [] do
      Mix.shell().info("all #{length(links)} links answer")
    else
      for {href, status} <- failures, do: Mix.shell().error("#{status} #{href}")
      Mix.raise("#{length(failures)} link(s) do not resolve on #{host}")
    end
  end

  defp status(url) do
    {out, 0} = System.cmd("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-L", url])
    String.to_integer(out)
  end
end
