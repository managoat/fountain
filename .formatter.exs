[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  # Umbrella children carry their own .formatter.exs; without this the globs
  # below (root-relative) would never reach apps/. See #612.
  subdirectories: ["apps/*"],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,test}/**/*.{heex,ex,exs}"
  ]
]
