defmodule Fountain.MixProject do
  use Mix.Project

  def project do
    [
      app: :fountain,
      version: "0.16.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: ["test", "../../ee/test"],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: coverage(),
      preferred_cli_env: [muzak: :test]
    ]
  end

  # Same file the umbrella root reads (#620). Read rather than referenced
  # through the root project because `mix test` is also run from inside this
  # directory — the documented way to run a single ee/test file — and then the
  # root mix.exs is never loaded at all.
  defp coverage do
    Path.expand("../../coverage.exs", __DIR__) |> Code.eval_file() |> elem(0)
  end

  def application do
    [
      mod: {Fountain.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # ee/ is the top-level EE directory (billing + transactional email); it
  # compiles into this app. Mix requires external dirs as absolute paths and
  # silently skips missing ones, so build contexts must include ee/ (see
  # Dockerfile and decisions/0010).
  @ee_lib Path.expand("../../ee/lib", __DIR__)
  defp elixirc_paths(:test), do: ["lib", @ee_lib, "test/support"]
  defp elixirc_paths(_), do: ["lib", @ee_lib]

  defp deps do
    [
      # The managoat_* component libraries (decisions/0037, #1345). Each is
      # Apache-2.0, carries no reference back into Fountain, started life as an
      # app in this umbrella and has graduated to a managoat/managoat_<name>
      # repository that publishes to hex from its own CI. The pins are
      # patch-level within each library's current minor release while everything
      # is 0.x: a new minor reaches Fountain only when someone bumps its pin here.
      # A future library starts as {:managoat_<name>, in_umbrella: true}
      # again; umbrella_layout_test.exs checks it is listed here.
      {:managoat_acp, "~> 0.4.2"},
      {:managoat_broker, "~> 0.11.0"},
      {:managoat_docs, "~> 0.1.0"},
      {:managoat_mcp_auth, "~> 0.1.0"},
      {:managoat_oauth, "~> 0.1.0"},
      {:managoat_runner, "~> 0.2.2"},
      {:managoat_runtimes, "~> 0.4.2"},
      {:managoat_substitution, "~> 0.1.0"},
      {:managoat_sandbox, "~> 0.3.0"},
      {:sentry, "~> 13.3"},
      {:phoenix, "~> 1.8.5"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:remote_ip, "~> 1.2"},
      {:oban, "~> 2.19"},
      {:open_api_spex, "~> 3.21"},
      {:libcluster, "~> 3.4"},
      {:horde, "~> 0.10.0"},
      # The opentelemetry_* family depends on complex Erlang/rebar3 cross-dep includes
      # (otel_sampler.hrl, grpcbox, chatterbox). They compile correctly in CI
      # (Alpine/musl OTP) but fail with rebar3 bare compile in some dev environments.
      # opentelemetry_api is the only one needed at compile time (for the @decorate macros);
      # the SDK and exporter are runtime-only outside of prod.
      {:opentelemetry, "~> 1.5", only: :prod},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.8", only: :prod},
      {:opentelemetry_phoenix, "~> 2.0", only: :prod},
      {:opentelemetry_ecto, "~> 1.2", only: :prod},
      {:opentelemetry_telemetry, "~> 1.1", only: :prod},
      {:req, "~> 0.5"},
      # New Fountain deps
      {:bcrypt_elixir, "~> 3.0"},
      {:uniq, "~> 0.6"},
      {:stripity_stripe, "~> 3.0"},
      {:swoosh, "~> 1.17"},
      # SMTP delivery, so a self-hoster is not obliged to use a SaaS provider.
      {:gen_smtp, "~> 1.2"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_github, "~> 0.8"},
      # Test / dev
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mimic, "~> 2.3", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:muzak, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # Extension migrations at the mix entrances (ADR 0043, #1506). These
      # aliases shadow Ecto's tasks, add `--migrations-path` for the core
      # directory and every installed extension's, and then run the real task —
      # a same-named task inside its own alias is the original, which is the
      # same mechanism `test: ["test"]` below relies on.
      #
      # Shadowing rather than adding `mix fountain.migrate` beside it is
      # deliberate: a contributor who types `mix ecto.migrate` out of habit must
      # not end up with a database that is missing an installed extension's
      # tables and no indication why.
      #
      # With nothing installed these add only the core path, which is the path
      # Ecto would have picked itself, so the behaviour is unchanged.
      "ecto.migrate": [&migrate_with_extension_paths/1],
      "ecto.rollback": [&rollback_with_extension_paths/1],
      test: ["test"],
      # `openapi.export` moved to the umbrella root (#1507): the spec describes
      # the running distribution, and an installed extension's operations are
      # only on the code path there. See the root mix.exs.
      "openapi.noop": []
    ]
  end

  defp migrate_with_extension_paths(args), do: run_ecto_task("ecto.migrate", args)
  defp rollback_with_extension_paths(args), do: run_ecto_task("ecto.rollback", args)

  # `app.config` first: the path set is read from `config :fountain, :extensions`
  # and resolved through `:code.priv_dir/1`, and neither the configuration nor
  # the applications are loaded before it runs.
  #
  # A caller who passes their own --migrations-path is taken at their word and
  # gets no additions — that is the escape hatch for migrating one directory on
  # purpose, and Ecto already treats the flag as replacing the default.
  defp run_ecto_task(task, args) do
    Mix.Task.run("app.config")

    args =
      if "--migrations-path" in args do
        args
      else
        args ++ path_args()
      end

    Mix.Task.run(task, args)
  end

  defp path_args do
    repo = Fountain.Repo
    core = Path.join(Mix.EctoSQL.source_repo_priv(repo), "migrations")

    [core | Fountain.Migrations.extension_paths()]
    |> Enum.flat_map(&["--migrations-path", &1])
  end
end
