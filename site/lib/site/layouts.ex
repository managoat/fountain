defmodule Site.Layouts do
  @moduledoc """
  The document around every page: the `<head>` (`root/1`) and the header and
  footer (`shell/1`, from `layouts/shell.html.heex`).

  `root/1` is the public half of the app's `root.html.heex`: the card and
  favicon tags, the PostHog snippet, the design tokens and the paper skin, the
  Tailwind play CDN and the theme restore. What it leaves behind is the
  console's: the CSRF token, LiveView and its hooks, the keyboard cheatsheet.
  """
  use Phoenix.Component

  embed_templates("layouts/*")

  # The PostHog project the app's public surface reports to, with the same
  # options the app's layout states rather than inherits: anonymous readers
  # mint no person profile, and replay masks everything typed. The key is a
  # public token and appears in every page the app already serves.
  @posthog_api_key "phc_yDS4U3XZWA3cdHQPNDMdWK95r2MmccSz6XxQgVhDY2Mv"
  @posthog_api_host "https://us.i.posthog.com"
  @posthog_assets_host "https://us-assets.i.posthog.com"

  attr(:page_title, :string, required: true)
  attr(:meta_description, :string, required: true)
  attr(:path, :string, required: true)
  attr(:inner_content, :any, required: true)

  def root(assigns) do
    assigns =
      assign(assigns,
        posthog_api_key: @posthog_api_key,
        posthog_api_host: @posthog_api_host,
        posthog_assets_host: @posthog_assets_host,
        canonical: Site.Brand.site_url() <> assigns.path
      )

    ~H"""
    <!DOCTYPE html>
    <html
      lang="en"
      id="app-html"
      data-theme=""
      data-skin="paper"
      style={"--paper-mark: url(#{Site.Brand.asset("mark-mono.png")})"}
    >
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@page_title}</title>
        <link rel="canonical" href={@canonical} />
        <meta name="description" content={@meta_description} />
        <meta property="og:type" content="website" />
        <meta property="og:site_name" content={Site.Brand.name()} />
        <meta property="og:title" content={@page_title} />
        <meta property="og:description" content={@meta_description} />
        <meta property="og:url" content={@canonical} />
        <meta property="og:image" content={Site.Brand.asset("og-card.png")} />
        <meta property="og:image:width" content="1200" />
        <meta property="og:image:height" content="630" />
        <meta property="og:image:alt" content={Site.Brand.name()} />
        <meta name="twitter:card" content="summary_large_image" />
        <meta name="twitter:title" content={@page_title} />
        <meta name="twitter:description" content={@meta_description} />
        <meta name="twitter:image" content={Site.Brand.asset("og-card.png")} />
        <link rel="icon" href={Site.Brand.asset("favicon.ico")} sizes="any" />
        <link rel="icon" type="image/png" sizes="32x32" href={Site.Brand.asset("favicon-32x32.png")} />
        <link rel="icon" type="image/png" sizes="16x16" href={Site.Brand.asset("favicon-16x16.png")} />
        <link rel="apple-touch-icon" sizes="180x180" href={Site.Brand.asset("apple-touch-icon.png")} />
        <script defer src={"#{@posthog_assets_host}/static/array.js"}>
        </script>
        <script id="posthog-config" data-api-key={@posthog_api_key} data-api-host={@posthog_api_host}>
          window.addEventListener("DOMContentLoaded", function () {
            if (!window.posthog || !window.posthog.init) return;
            var cfg = document.getElementById("posthog-config");
            window.posthog.init(cfg.dataset.apiKey, {
              api_host: cfg.dataset.apiHost,
              defaults: "2025-05-24",
              person_profiles: "identified_only",
              session_recording: { maskAllInputs: true }
            });
            window.posthog.register({ surface: "public" });
          });
        </script>
        <%!-- Design tokens before Tailwind, so the utilities' variables exist;
              the paper skin after them, because it is a second set of values
              for the same tokens. --%>
        <link rel="stylesheet" href={Site.Assets.tokens_css()} />
        <link rel="stylesheet" href={Site.Assets.paper_css()} />
        <script>
          window.tailwind = window.tailwind || {};
          window.tailwind.config = {
            darkMode: ["selector", "[data-theme=\"dark\"]"],
            theme: {
              extend: {
                colors: {
                  brand:    { DEFAULT: "var(--color-brand)", hover: "var(--color-brand-hover)" },
                  surface:  { 0: "var(--color-bg-0)", 1: "var(--color-bg-1)", 2: "var(--color-bg-2)", 3: "var(--color-bg-3)" },
                  "ft-border": { DEFAULT: "var(--color-border)", strong: "var(--color-border-strong)" },
                  "ft-text":   { primary: "var(--color-text-primary)", secondary: "var(--color-text-secondary)", muted: "var(--color-text-muted)" },
                  "ft-code":   { bg: "var(--color-code-bg)", text: "var(--color-code-text)" }
                }
              }
            }
          };
        </script>
        <script src="https://cdn.tailwindcss.com?plugins=typography">
        </script>
        <%!-- The console stores a theme choice in localStorage under this key;
              a reader arriving from it keeps their choice here, and everyone
              else follows the OS. --%>
        <script>
          (function () {
            var saved = null;
            try { saved = localStorage.getItem("fountain-theme"); } catch (e) {}
            var html = document.getElementById("app-html");
            if (saved === "dark") {
              html.setAttribute("data-theme", "dark");
            } else if (saved !== "light" && window.matchMedia("(prefers-color-scheme: dark)").matches) {
              html.setAttribute("data-theme", "dark");
            }
          })();
        </script>
      </head>
      <body class="bg-[var(--color-bg-0)] text-[var(--color-text-primary)] font-sans antialiased">
        {@inner_content}
      </body>
    </html>
    """
  end
end
