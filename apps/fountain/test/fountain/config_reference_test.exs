defmodule Fountain.ConfigReferenceTest do
  use ExUnit.Case, async: true

  # Guards docs/configuration.md against drifting from config/runtime.exs
  # (#280): every environment variable the runtime config reads must have a
  # row in the reference. Reading a new var without documenting it is a red
  # build, not an archaeology project.

  @repo_root Path.expand("../../../..", __DIR__)

  test "every env var the app reads is documented in docs/configuration.md" do
    runtime = File.read!(Path.join(@repo_root, "config/runtime.exs"))
    doc = File.read!(Path.join(@repo_root, "docs/configuration.md"))

    # Two extraction passes. Direct System.get_env/fetch_env calls are scanned
    # across every config file and the lib tree, because a read outside
    # runtime.exs is still a switch an operator can set: PHOENIX_REQUEST_LOG
    # sat in config/prod.exs for six weeks, undocumented and — since prod.exs
    # is evaluated at build time — wired to nothing (deleted). The second pass, any
    # quoted UNDERSCORED_ALL_CAPS literal, catches vars passed through helpers
    # like parse_bound.("SANDBOX_IDLE_TIMEOUT_MINUTES", ...), which the direct
    # pattern misses; it runs over runtime.exs only, where every such literal
    # is an env var name, which is not true of the lib tree.
    direct =
      Regex.scan(
        ~r/System\.(?:get_env|fetch_env!?)\(\s*"([A-Z][A-Z0-9_]*)"/,
        env_source(),
        capture: :all_but_first
      )

    underscored_literals =
      Regex.scan(~r/"([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)"/, runtime, capture: :all_but_first)

    vars =
      (direct ++ underscored_literals)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    # If extraction ever stops matching (a refactor of runtime.exs, a regex
    # rot), this guard fails loudly instead of the main assertion passing
    # vacuously over an empty list.
    assert length(vars) > 30,
           "extracted only #{length(vars)} env vars from the config files — " <>
             "the extraction patterns no longer match how the file reads env vars"

    undocumented =
      Enum.reject(vars, fn var ->
        String.contains?(doc, "`#{var}`")
      end)

    assert undocumented == [],
           """
           The app reads env vars that docs/configuration.md does not document:

             #{Enum.join(undocumented, ", ")}

           Add a row for each, in backticks. A variable the platform injects
           rather than an operator sets still gets a row: FLY_APP_NAME is read
           here, invisible from a dashboard, and worth a line that says who
           sets it. The
           exemption list they used to sit on is gone.
           """
  end

  # ── reverse direction (#337) ─────────────────────────────────────────────
  #
  # The original test only caught runtime.exs → doc drift. Nothing caught a
  # documented variable that no longer exists in code, or a compose variable
  # the app never reads — an operator following either would set a knob wired
  # to nothing.

  # Documented variables legitimately read by something other than this
  # code base. Each entry needs a reason; an entry without a real reader is
  # exactly the rot this test exists to catch.
  @read_elsewhere %{
    # The OTel SDK reads its own standard variables directly.
    "OTEL_TRACES_EXPORTER" => "read by the OTel Erlang SDK"
  }

  test "every variable documented in configuration.md is actually read by code" do
    source = env_source()
    doc = File.read!(Path.join(@repo_root, "docs/configuration.md"))

    documented =
      Regex.scan(~r/^\| `([A-Z][A-Z0-9_]*)`/m, doc, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    # Vacuous-pass guard, mirroring the forward test.
    assert length(documented) > 30,
           "extracted only #{length(documented)} documented vars — the table format changed"

    dead =
      Enum.reject(documented, fn var ->
        String.contains?(source, ~s("#{var}")) or Map.has_key?(@read_elsewhere, var)
      end)

    assert dead == [],
           """
           docs/configuration.md documents variables that the app never reads:

             #{Enum.join(dead, ", ")}

           Delete the row, or — only when a real reader exists outside the
           config files and the lib tree — add the var to @read_elsewhere
           with the reader.
           """
  end

  # Compose-side keys that are not app env vars: consumed by compose
  # interpolation or by another service, not by the release.
  @compose_only ~w()

  test "every env var the compose app service sets is one the app reads" do
    source = env_source()
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))

    # The environment mapping of the `app:` service: keys at 6-space indent
    # between its `environment:` line and the next 4-space-indented key.
    [_, app_section] = String.split(compose, ~r/^  app:\n/m, parts: 2)
    [_, env_and_rest] = String.split(app_section, ~r/^    environment:\n/m, parts: 2)
    [env_block | _] = String.split(env_and_rest, ~r/^    [a-z]/m, parts: 2)

    keys =
      Regex.scan(~r/^      ([A-Z][A-Z0-9_]*):/m, env_block, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert length(keys) > 5,
           "extracted only #{length(keys)} compose env keys — the compose layout changed"

    unread =
      Enum.reject(keys, fn var ->
        String.contains?(source, ~s("#{var}")) or var in @compose_only or
          Map.has_key?(@read_elsewhere, var)
      end)

    assert unread == [],
           """
           docker-compose.yml sets env vars on the app service that the app never reads:

             #{Enum.join(unread, ", ")}

           Remove the key, or add it to @compose_only/@read_elsewhere with a reason.
           """
  end

  # Keys in .env.compose.example consumed by compose interpolation itself
  # (image tag, published ports, sibling services), not passed through the
  # app service's environment block.
  @interpolation_only ~w(FOUNTAIN_IMAGE_TAG PORT POSTGRES_PASSWORD POSTGRES_HOST_PORT)

  test "every variable .env.compose.example advertises is actually passed to the app" do
    # The other compose test is one-directional by construction: it asserts
    # every key compose SETS is read, never that every key the example file
    # ADVERTISES is passed through. That gap is exactly how a documented
    # variable can be set by an operator and silently ignored.
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))
    example = File.read!(Path.join(@repo_root, ".env.compose.example"))

    advertised =
      Regex.scan(~r/^#?\s*([A-Z][A-Z0-9_]*)=/m, example, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert length(advertised) > 5,
           "extracted only #{length(advertised)} keys from .env.compose.example — its layout changed"

    unpassed =
      Enum.reject(advertised, fn var ->
        passed_through?(compose, var) or var in @interpolation_only
      end)

    assert unpassed == [],
           """
           .env.compose.example advertises variables the compose file never passes to the app:

             #{Enum.join(unpassed, ", ")}

           Add the key to the app service's environment block, or to
           @interpolation_only with a reason.
           """
  end

  test "every variable a guide tells the reader to append to .env is passed to the app" do
    # The two tests above both run "declared, therefore it must be real": they
    # start from what compose sets or what the example file advertises. Neither
    # starts from what a *guide* tells an operator to do, which is how
    # API_CORS_ORIGINS came to be documented, read by runtime.exs, instructed
    # by the deploy guide — and never forwarded by compose, so following the
    # guide changed nothing and logged nothing (#1215).
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))

    instructed =
      Path.join(@repo_root, "docs/**/*.md")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(&Regex.scan(~r/^echo\s+"([A-Z][A-Z0-9_]*)=.*>>\s*\.env\s*$/m, &1))
        |> Enum.map(fn [_, var] -> {var, Path.relative_to(path, @repo_root)} end)
      end)
      |> Enum.uniq()

    assert instructed != [],
           "found no `>> .env` lines in docs/ — the guides changed shape, so this guard is blind"

    unpassed = Enum.reject(instructed, fn {var, _} -> passed_through?(compose, var) end)

    assert unpassed == [],
           """
           A guide tells the reader to append variables that compose never passes to the app,
           so following it silently does nothing:

             #{Enum.map_join(unpassed, "\n  ", fn {var, path} -> "#{var} (#{path})" end)}

           Add the key to the app service's environment block in docker-compose.yml.
           """
  end

  test "every variable the feature-status page tells a reader to set is passed to the app" do
    # The sibling above starts from the guides' `>> .env` lines. This one
    # starts from docs/reference/feature-status.md, whose "on your own
    # instance" column is the promise that what the hosted platform rations is
    # a line of config on your own deployment, and names which line.
    #
    # Until 2026-09 the same promise was also made by the marketing page
    # /self-hosted, from Elixir data no linter here read, and FEATURE_FLAGS_ON,
    # the AgentMail and AgentPhone keys and every BROKER_* variable were named
    # there and forwarded by nothing: an operator set them, restarted, and got
    # no feature and no error. That page lives in managoat/site now and copies
    # this table; the docs page is the version this repo can guard.
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))
    page = File.read!(Path.join(@repo_root, "docs/reference/feature-status.md"))

    promised =
      ~r/`([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)`/
      |> Regex.scan(page, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert promised != [],
           "no environment variables found in docs/reference/feature-status.md — the page " <>
             "no longer names them in code spans, so this guard is blind"

    unpassed = Enum.reject(promised, &passed_through?(compose, &1))

    assert unpassed == [],
           """
           feature-status.md tells a reader to set variables that compose never passes to the app,
           so the feature never turns on and nothing says why:

             #{Enum.join(unpassed, ", ")}

           Add the key to the app service's environment block in docker-compose.yml.
           """
  end

  # Keys fly.toml sets that Fly consumes rather than the release: the port it
  # asks the machine to bind is read by the app too, so this stays empty until
  # something is genuinely Fly-only.
  @fly_only ~w()

  test "every env var fly.toml sets is one the app reads" do
    # Second self-host deploy surface, same rot as compose: a key set
    # here that the app never reads is a knob wired to nothing, and an
    # operator has no way to tell from the outside.
    source = env_source()
    fly = File.read!(Path.join(@repo_root, "fly.toml"))

    keys =
      fly
      |> env_block()
      |> then(&Regex.scan(~r/^\s*([A-Z][A-Z0-9_]*) = /m, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()

    assert length(keys) > 5,
           "extracted only #{length(keys)} keys from fly.toml [env] — its layout changed"

    unread =
      Enum.reject(keys, fn var ->
        String.contains?(source, ~s("#{var}")) or var in @fly_only or
          Map.has_key?(@read_elsewhere, var)
      end)

    assert unread == [],
           """
           fly.toml sets env vars that the app never reads:

             #{Enum.join(unread, ", ")}

           Remove the key, or add it to @fly_only/@read_elsewhere with a reason.
           """
  end

  test "fly.toml keeps the secrets out of the repository" do
    # Fly has no dashboard-only marker for a value: a value written in [env] is a value committed to
    # a git repository, and `fly secrets set` is the only right home for them.
    # The guide says so; this makes the file itself say so.
    fly = env_block(File.read!(Path.join(@repo_root, "fly.toml")))

    committed =
      Enum.filter(~w(SECRET_KEY_BASE MASTER_SECRETS_KEY SPRITES_TOKEN DATABASE_URL), fn var ->
        Regex.match?(~r/^\s*#{var} = /m, fly)
      end)

    assert committed == [],
           """
           fly.toml writes secrets into [env], which commits them:

             #{Enum.join(committed, ", ")}

           These belong in `fly secrets set`, and DATABASE_URL comes from
           `fly mpg attach`.
           """
  end

  test "fly.toml pins one machine that never parks" do
    # These four lines are the entire reason this file exists rather than a
    # paragraph in a guide, so they get a guard rather than a comment.
    #
    # Fly's defaults stop an idle machine and start it again on a request, and
    # a parked machine is an instance that quietly stops reaping sandboxes and
    # stops pricing turns — every scheduler runs inside this process. A second
    # machine is worse: Fountain clusters over Erlang distribution and nothing
    # on Fly discovers peers, so two machines are two schedulers racing over
    # the same sandboxes. `canary` and `bluegreen` both create that second
    # machine for the length of a deploy.
    fly = File.read!(Path.join(@repo_root, "fly.toml"))

    for {pattern, why} <- [
          {~r/^\s*auto_stop_machines = "off"$/m, "a parked machine stops reaping and pricing"},
          {~r/^\s*auto_start_machines = false$/m,
           "a machine Fly starts on demand is a parked one"},
          {~r/^\s*min_machines_running = 1$/m, "the instance has to stay up between requests"},
          {~r/^\s*strategy = "rolling"$/m, "canary and bluegreen run two machines at once"}
        ] do
      assert Regex.match?(pattern, fly),
             "fly.toml no longer matches #{inspect(pattern)} — #{why}"
    end

    assert Regex.match?(~r/^\s*path = "\/health\/ready"$/m, fly),
           """
           fly.toml no longer health-checks /health/ready. /health is static
           and passes with an unreachable database, so Fly would send traffic
           to a machine that cannot serve it.
           """

    refute Regex.match?(~r/^\s*PUBLIC_URL = /m, env_block(fly)),
           """
           fly.toml sets PUBLIC_URL. This file ships with an app name that
           `fly launch` replaces, so a committed base URL names the wrong app
           — and a set-but-wrong value takes the FLY_APP_NAME fallback in
           config/runtime.exs out of reach. Leave it to the fallback, and set
           it with `fly secrets set` when you add a custom domain.
           """
  end

  # Everything that can read an environment variable at boot: the four config
  # files and the lib tree of every app, ee/ included. Test support and the
  # suites are left out; a read there is a fixture, not a switch.
  defp env_source do
    config = Path.wildcard(Path.join(@repo_root, "config/*.exs"))
    apps = Path.wildcard(Path.join(@repo_root, "apps/*/lib/**/*.ex"))
    ee = Path.wildcard(Path.join(@repo_root, "ee/lib/**/*.ex"))

    (config ++ apps ++ ee)
    |> Enum.sort()
    |> Enum.map_join("\n", &File.read!/1)
  end

  # The [env] table of fly.toml: everything between the `[env]` header and the
  # next top-level table. Scanning the whole file instead would read the
  # commented examples and the prose in the header comment.
  defp env_block(fly) do
    [_, rest] = String.split(fly, ~r/^\[env\]\n/m, parts: 2)
    [block | _] = String.split(rest, ~r/^\[/m, parts: 2)
    block
  end

  # Two legitimate pass-through forms in the app service's environment block:
  # `VAR: ${VAR...}` with any default, and a bare `VAR:` with no value at all.
  # The second one forwards the variable only when .env sets it, which is the
  # only way to distinguish "unset, use the app's default" from "set to empty
  # on purpose" — see the app-URL block in docker-compose.yml.
  defp passed_through?(compose, var) do
    Regex.match?(~r/^\s*#{var}:\s*.*\$\{#{var}[:}-]/m, compose) or
      Regex.match?(~r/^\s*#{var}:\s*$/m, compose)
  end
end
