Code.require_file("config/hex_advisories.exs", __DIR__)

defmodule Fountain.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      # Kept in lockstep with the newest v* git tag — release-bump.yml
      # computes the next tag from this value.
      version: "0.18.0",
      hex: [
        ignore_advisories:
          [
            # cowlib 2.19.0 is already the newest Hex release, OSV lists no fixed
            # Hex version, and Fountain serves HTTP with Bandit rather than Cowboy.
            "EEF-CVE-2026-43969",
            # cowlib 2.19.0 is already the newest Hex release, OSV lists no fixed
            # Hex version, and Fountain serves HTTP with Bandit rather than Cowboy.
            "EEF-CVE-2026-43971",
            # cowlib 2.19.0 is already the newest Hex release, OSV lists no fixed
            # Hex version, and Fountain serves HTTP with Bandit rather than Cowboy.
            "EEF-CVE-2026-43966",
            # gun 2.5.0 is already the newest Hex release, OSV lists no fixed Hex
            # version, and Fountain serves HTTP with Bandit rather than Cowboy.
            "GHSA-w4f7-4cxr-rv3c"
          ] ++ Fountain.Build.HexAdvisories.for_lock(Path.join(__DIR__, "mix.lock"))
      ],
      deps: deps(),
      releases: releases(),
      aliases: aliases(),
      # Built-in cover rather than ExCoveralls (#620): ExCoveralls has no way
      # to merge results from separate machines, and the suite is now run as
      # six partitions in six CI jobs, each of which instruments every
      # module while exercising a sixth of the tests. `mix test --partitions`
      # exports a .coverdata per partition and `mix test.coverage` merges them
      # here, at the umbrella root, where the 85% threshold is enforced once
      # against the union. Dropping the threshold per partition instead would
      # have deleted the gate while leaving it looking present.
      test_coverage: coverage(),
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs",
        # A fixed path (rather than the _build default) so CI can cache the
        # PLT across runs — cold PLT builds on a runner take minutes.
        #
        # list_unused_filters is deliberately NOT set: the pinned dialyxir ref
        # fails to credit string-form filters as used and would fail the run.
        # Audit the ignore file by hand with `mix dialyzer --list-unused-filters`
        # (tuple entries report accurately) when trimming it.
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        # :mix so Mix.Task-based code (`mix openapi.spec.json`, the aliases)
        # analyzes cleanly — without it every Mix.* call is "unknown function".
        plt_add_apps: [:mix]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test
      ]
    ]
  end

  # Shared with apps/fountain/mix.exs — see coverage.exs for why it is a file.
  defp coverage do
    Path.expand("coverage.exs", __DIR__) |> Code.eval_file() |> elem(0)
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.8", only: [:dev, :test], runtime: false}
    ]
  end

  # Migrating from the umbrella root has to reach apps/fountain — that is where
  # the Repo's project lives — but the migration PATH SET can only be computed
  # here, because `apps/fountain` deliberately depends on no sibling app and so
  # cannot see an extension's `priv` at all (ADR 0043).
  #
  # Shelling in without the paths is how CI went red on this PR: a fresh
  # database got no `buzz_identities`, and the core migration that alters it
  # (20260817020000) then failed. A pre-migrated workstation database hides it
  # completely, which is why it took a clean CI run to find.
  #
  # The paths are absolute because the child process runs in apps/fountain, and
  # apps/fountain's own `ecto.migrate` alias takes an explicit
  # `--migrations-path` at face value rather than adding its own.
  defp migrate_in_app(args), do: run_ecto_in_app("ecto.migrate", args)
  defp rollback_in_app(args), do: run_ecto_in_app("ecto.rollback", args)

  defp run_ecto_in_app(task, args) do
    Mix.Task.run("app.config")

    args = if "--migrations-path" in args, do: args, else: args ++ migration_path_args()

    Mix.Task.run("do", ["--app", "fountain", "cmd", "mix", task] ++ args)
  end

  defp migration_path_args do
    core = Path.expand("apps/fountain/priv/repo/migrations", File.cwd!())

    [core | Fountain.Migrations.extension_paths()]
    |> Enum.flat_map(&["--migrations-path", &1])
  end

  defp releases do
    [
      fountain_server: [
        # One release name, two distributions (ADR 0043 decision 7). The name
        # stays `fountain_server` in both, because it is `bin/fountain_server`
        # in the image's CMD, in every `bin/migrate` and in the operator's
        # muscle memory — a core release is a different set of applications,
        # not a different product.
        #
        # `apps/fountain` deliberately depends on NO extension — the arrow
        # points the other way and the compiler proves it — so inclusion is the
        # release's decision, made here, and dropping one is a switch rather
        # than untangling a dependency.
        #
        # `BUNDLE_EXTENSIONS=false` builds the core release: the server and
        # nothing else. Every `apps/fountain_*` app is an extension and is
        # discovered rather than listed, so a new one is in the bundled release
        # from the commit that adds it and out of the core one for free.
        applications: [fountain: :permanent] ++ extension_applications()
      ]
    ]
  end

  # `BUNDLE_EXTENSIONS=false mix release` builds the core distribution.
  #
  # Read from the environment rather than from Mix config because the Dockerfile
  # passes the same switch as a build arg for the native-asset stage, and one
  # switch for both halves is the point: an image cannot end up with an
  # extension application but no binaries, or the reverse.
  #
  # Discovered from `apps/fountain_*` rather than listed. A `managoat_*` library
  # under apps/ is a DEPENDENCY of fountain (decisions/0037) and belongs in both
  # releases, which is why the glob is the naming convention and not "every
  # sibling".
  defp extension_applications do
    if System.get_env("BUNDLE_EXTENSIONS", "true") == "true" do
      __DIR__
      |> Path.join("apps/fountain_*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&{String.to_atom(Path.basename(&1)), :permanent})
      |> Enum.sort()
    else
      []
    end
  end

  defp aliases do
    [
      # `ecto.setup` and `ecto.reset` go through this project's `ecto.migrate`
      # below, NOT through apps/fountain's — the app cannot see a sibling's
      # migration path, so shelling straight into its `ecto.setup` would create
      # a database with no extension tables (ADR 0043). Same bug CI caught on
      # the plain `ecto.migrate` path, on the two entrances CI does not run.
      setup: ["deps.get", "ecto.setup"],
      # `cmd` under `do --app`, rather than `do --app <task>` directly (#1526,
      # replacing the deprecated `cmd --app`): `mix do --app` narrows only a
      # task that is `@recursive`, and none of ecto.create, ecto.drop,
      # ecto.migrate, ecto.rollback or run is one. Handed the task directly,
      # `do --app fountain ecto.create` drops the narrowing and runs at the
      # umbrella root, and `do --app fountain run priv/repo/seeds.exs` fails
      # outright ("No such file"), because the relative path resolves against
      # the root. `mix cmd` IS recursive, so the --app narrows *it* and the
      # command runs inside apps/fountain, which is what `cmd --app` did.
      "ecto.setup": [
        "do --app fountain cmd mix ecto.create",
        "ecto.migrate",
        "do --app fountain cmd mix run priv/repo/seeds.exs"
      ],
      "ecto.reset": ["do --app fountain cmd mix ecto.drop", "ecto.setup"],
      # Migrating from the umbrella root has to go through apps/fountain, or the
      # extension migration paths are silently dropped (ADR 0043, #1506).
      #
      # `mix ecto.migrate` is a recursive task: run here, Mix invokes the task
      # module inside each child project WITHOUT resolving that child's aliases,
      # so apps/fountain's "ecto.migrate" alias — the one that appends every
      # installed extension's --migrations-path — never fires. It reports
      # "Migrations already up" and leaves the extension's tables missing.
      # Shelling into the app the way `ecto.reset` above already does is what
      # makes the child's alias run. CI, SETUP.md and CLAUDE.md all migrate from
      # the root, so without these two lines the root is the entrance that
      # quietly skips extensions.
      # Render the served OpenAPI spec. At the UMBRELLA ROOT on purpose: the
      # document describes the running distribution (ADR 0043), and only here
      # is every app on the code path. Run inside apps/fountain — which is what
      # this did until #1507 — and `Fountain.Extensions.installed/0` is empty,
      # so the extension's operations vanish from `dist/openapi.json` and from
      # the SDK contract projected out of it, silently and by deletion.
      "openapi.export": [
        "openapi.spec.json --spec FountainWeb.ApiSpec --vendor-extensions=false dist/openapi.json"
      ],
      "ecto.migrate": [&migrate_in_app/1],
      "ecto.rollback": [&rollback_in_app/1],
      # The gate is scripts/precommit.sh, one OS process per stage, and its
      # exit status is the verdict. `System.halt/1` rather than `Mix.raise/1`
      # so that status reaches the shell untouched: nothing in Mix's own exit
      # path, and no at_exit handler, sits between the failed stage and `$?`.
      precommit: [&precommit/1]
    ]
  end

  defp precommit(args) do
    case Mix.shell().cmd(Enum.join(["scripts/precommit.sh" | args], " ")) do
      0 -> :ok
      status -> System.halt(status)
    end
  end
end
