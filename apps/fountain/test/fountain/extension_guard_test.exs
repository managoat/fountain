defmodule Fountain.ExtensionGuardTest do
  @moduledoc """
  The compile-time boundary, checked as source (ADR 0043, #1507 and #1528).

  The umbrella's dependency resolution proves `fountain_buzz -> fountain` and
  `fountain_support -> fountain`: each extension lists
  `{:fountain, in_umbrella: true}` and Fountain lists nothing. It proves nothing
  at all about the other direction, because the way that breaks is not a
  dependency — it is a stray module atom, a route, a migration or a config key
  that compiles perfectly and only surprises somebody on the day a core-only
  release fails to boot.

  So this walks the source. It is the test that has to fail on the PR that
  reintroduces the crossing, not on the deploy.

  ## What is allowed

  Prose. `apps/fountain/lib` may say the words "Buzz" or "support" in a comment,
  a docstring or a schema description, and does — the ADR calls that
  human-facing discovery metadata, and #1528 keeps the support-report
  documentation in core deliberately. `SUPPORT_EMAIL` is core's too: the
  account emails name it, so the key stays `config :fountain, :support_email` and only the
  GitHub forwarding keys moved. What is refused is *code* that names an
  extension.

  `config/` is deliberately not walked: naming an extension module in
  configuration is the one place ADR 0043 says it belongs.
  """
  use ExUnit.Case, async: true

  @core_lib Path.expand("../../lib", __DIR__)
  @core_priv Path.expand("../../priv", __DIR__)
  @apps Path.expand("../../..", __DIR__)

  @sources @core_lib
           |> Path.join("**/*.{ex,exs,heex}")
           |> Path.wildcard()
           |> Enum.sort()

  # Every extension, and what naming it from core looks like:
  #
  #   * `module` — module references, not the product's name. `FountainBuzz.X`,
  #     `Fountain.Buzz.X`, and the names each subsystem carried before it moved.
  #   * `route` — a router line that would serve the extension's mount, minus
  #     the `route_except` substrings that are core's after all.
  #   * `priv` — files under core's priv that belong to the extension, which is
  #     how a migration comes back.
  @extensions [
    %{
      app: :fountain_buzz,
      module:
        ~r/\b(FountainBuzz\.|Fountain\.Buzz\b|Fountain\.BuzzRegistry\b|Fountain\.BuzzSupervisor\b|Fountain\.Workers\.BuzzHarnessSweep\b|FountainWeb\.Buzz[A-Z])/,
      route: ~r|"/(api/)?(mcp/)?buzz|,
      route_except: [],
      priv: "**/*buzz*"
    },
    %{
      app: :fountain_support,
      module:
        ~r/\b(FountainSupport\b|Fountain\.Support\b|Fountain\.Workers\.SupportForward\b|FountainWeb\.SupportReport[A-Z])/,
      route: ~r|"/(api/)?support|,
      route_except: [],
      priv: "**/*support_report*"
    }
  ]

  for %{app: app} = extension <- @extensions do
    @extension extension

    describe "#{app}" do
      test "apps/fountain/lib names no module of it" do
        offenders =
          for path <- @sources,
              {line, number} <- Enum.with_index(File.stream!(path), 1),
              Regex.match?(@extension.module, line),
              do: "#{Path.relative_to(path, @core_lib)}:#{number}: #{String.trim(line)}"

        assert offenders == [],
               """
               Core source names an extension module. It must reach an extension only
               through `Fountain.Extension` callbacks, read from
               `config :fountain, :extensions` (ADR 0043).

               #{Enum.join(offenders, "\n")}
               """
      end

      test "apps/fountain/lib declares no route of it" do
        router = Path.join(@core_lib, "fountain_web/router.ex")

        offenders =
          for {line, number} <- Enum.with_index(File.stream!(router), 1),
              Regex.match?(@extension.route, line),
              not Enum.any?(@extension.route_except, &String.contains?(line, &1)),
              do: "router.ex:#{number}: #{String.trim(line)}"

        assert offenders == [],
               "The core router declares an extension route:\n#{Enum.join(offenders, "\n")}"
      end

      test "apps/fountain/priv holds no migration or asset of it" do
        offenders =
          @core_priv
          |> Path.join(@extension.priv)
          |> Path.wildcard()
          |> Enum.map(&Path.relative_to(&1, @core_priv))

        assert offenders == [],
               """
               An extension's assets and migrations belong to its own priv, so that a
               core-only release carries neither. Found:

               #{Enum.join(offenders, "\n")}
               """
      end

      test "it depends on the host, and the host depends on it in no direction" do
        core_mix = Path.expand("../../mix.exs", __DIR__) |> File.read!()
        ext_mix = Path.join([@apps, to_string(@extension.app), "mix.exs"]) |> File.read!()

        assert ext_mix =~ "{:fountain, in_umbrella: true}"

        refute core_mix =~ ":#{@extension.app}",
               "apps/fountain must not depend on an extension; the release owns inclusion"
      end

      test "the bundled release discovers it" do
        umbrella = Path.expand("../../../..", __DIR__)
        umbrella_mix = umbrella |> Path.join("mix.exs") |> File.read!()

        # Extensions are DISCOVERED from `apps/fountain_*` rather than listed
        # (#1510), so a new one is in the bundled release from the commit that
        # adds it and out of the core one for free. Asserting the literal name
        # in mix.exs would therefore assert the old mechanism; what matters is
        # that this app is one the glob finds.
        assert umbrella_mix =~ ~s|Path.join("apps/fountain_*")|,
               "the release must discover extensions, not list them (ADR 0043 decision 7)"

        discovered =
          umbrella
          |> Path.join("apps/fountain_*")
          |> Path.wildcard()
          |> Enum.filter(&File.dir?/1)
          |> Enum.map(&Path.basename/1)

        assert to_string(@extension.app) in discovered,
               "#{@extension.app} is not under apps/fountain_*, so no release would carry it"
      end
    end
  end

  test "the bundled release includes the server" do
    umbrella_mix = Path.expand("../../../../mix.exs", __DIR__) |> File.read!()

    assert umbrella_mix =~ "fountain: :permanent",
           "the bundled release must include the server"
  end

  test "every extension app under apps/ is covered by a case above" do
    # A third extension added without a row here would be unguarded, and
    # unguarded is indistinguishable from guarded-and-passing.
    on_disk =
      @apps
      |> Path.join("fountain_*")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.basename() |> String.to_atom()))
      |> Enum.reject(&(&1 == :fountain))
      |> Enum.sort()

    covered = @extensions |> Enum.map(& &1.app) |> Enum.sort()

    assert on_disk == covered,
           "extension apps on disk: #{inspect(on_disk)}; guarded here: #{inspect(covered)}"
  end
end
