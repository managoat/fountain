# syntax=docker/dockerfile:1.7
#
# Phoenix release image for Fountain (umbrella). Build stage compiles
# the `fountain_server` release against Erlang/OTP 28 + Elixir 1.19;
# runtime stage copies the release onto a slim Debian base.
#
# Notes:
#   - Umbrella: COPY apps/, config/, and the root mix.exs/mix.lock.
#     Release definition lives in the umbrella root (releases/0 in
#     mix.exs).
#   - No assets pipeline today: apps/fountain has no `assets/` dir and
#     no `mix assets.deploy` alias. If/when Tailwind+esbuild land,
#     add a `mix assets.deploy` step before `mix release`.
#   - SECRET_KEY_BASE is provided via the Infisical-materialized
#     fountain-secrets Secret (deployment.yaml envFrom). No fallback
#     generation here — fail-fast at boot if it's missing rather than
#     silently invalidate cookie sessions on every restart.
#   - One Dockerfile, two distributions (ADR 0043 decision 7).
#     `--build-arg BUNDLE_EXTENSIONS=false` builds the CORE image: no
#     extension application in the release. The default is the bundled image, which is what every existing tag
#     has meant and what the hosted deployment runs.

# Global scope, before the first FROM, so the default lives in one place. The
# stage that *uses* the value re-declares it; that is how build args work and
# not a duplication to tidy.
ARG BUNDLE_EXTENSIONS=true

FROM hexpm/elixir:1.19.2-erlang-28.3-debian-trixie-20260610-slim AS build

ENV MIX_ENV=prod

WORKDIR /app

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git \
 && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
 && mix local.rebar --force

# Umbrella deps live at the root. Copy ONLY what dependency resolution
# reads — the root mix files, config, and each app's mix.exs — before
# fetching and compiling deps, so the (expensive, slow-moving) deps layer
# survives any change to application code. Copying apps/ wholesale here
# is what used to force a full dep recompile on every commit.
#
# coverage.exs is part of that set, not test-only config: both mix.exs
# files read it with Code.eval_file to build `test_coverage`, which runs
# while Mix loads the project — before any task, in every MIX_ENV. Leave
# it out and `mix deps.get` dies on Code.LoadError (#620 moved the
# settings into this file and the prod image stopped building).
COPY mix.exs mix.lock coverage.exs ./
COPY config ./config
COPY apps/fountain/mix.exs ./apps/fountain/mix.exs
# Every extension's mix.exs is COPYd whatever the distribution: the umbrella
# loads every child's project to resolve dependencies, so a missing one fails
# `mix deps.get` here regardless of what the release ends up carrying. What
# BUNDLE_EXTENSIONS decides is whether the release *includes* the extension
# applications (ADR 0043 decision 7). No first-party extension ships today.
# One line per umbrella library app (decisions/0037), when there is one: the
# umbrella loads every child's mix.exs to resolve deps, so a missing one fails
# `mix deps.get` here. Every managoat_* library has graduated to hex (#1345,
# then managoat_runtimes under #1368), so there is none today;
# umbrella_layout_test.exs checks any future one.

RUN mix deps.get --only prod \
 && mix deps.compile

COPY apps ./apps
# Fountain.Docs embeds docs/ at compile time to serve it at /docs — without
# it the compile fails on File.read!. This is also the only way the content
# ships: the release never contains docs/ as files.
#
# Every file Fountain.Docs reads at compile time has to be here too, and two of
# those paths reach outside docs/: the changelog page snippet-includes
# CHANGELOG.md, and the tour page includes the SDK example it is written from.
# A missing one is not a broken link, it is a failed image build —
# `docs_test.exs` checks this list against the module's @external_resource
# attributes so the failure lands in CI instead.
#
# `Fountain.Onboarding` reads docs/snippets/ at compile time as well — the one
# copy of the first request, which the landing page renders and the manual
# includes. It is under docs/ for exactly this reason, so the line below
# already carries it; `onboarding_test.exs` pins that.
COPY docs ./docs
COPY CHANGELOG.md ./
COPY sdk/typescript/examples ./sdk/typescript/examples
# rel/ is what `mix release` adds to the stock release: env.sh.eex, which
# names the node for a Fly cluster, and the overlays (bin/server,
# bin/migrate). Mix reads both from rel/ when it is there and skips them
# without a word when it is not, so this line is the whole difference.
COPY rel ./rel

# Lumis downloads a language's tree-sitter parser on first use and caches it
# under its own priv/. The deployment runs read-only (deployment.yaml sets
# `readOnlyRootFilesystem: true`), so at runtime that download can neither
# happen nor be kept, and every fenced block in /docs and /help renders
# unhighlighted — how #879 shipped. Caching the parsers here, before the
# release is assembled, puts them in `deps/lumis/priv/lumis`, which `mix
# release` copies in like any other dependency's priv. `{:ok, _}` is the point:
# a parser that cannot be fetched fails the build rather than the page.
# `elixir -e` rather than `mix run`: any mix task here evaluates
# config/runtime.exs, which demands MASTER_SECRETS_KEY and the rest of the
# production environment that does not exist during a build. Prepending the
# compiled ebin paths gives the same code without the config.
# BUNDLE_EXTENSIONS decides which applications the release carries (ADR 0043 decision
# 7, and see mix.exs). Re-declared in this stage because a build ARG is scoped to
# the stage that declares it.
ARG BUNDLE_EXTENSIONS
RUN mix compile \
 && elixir -e 'Enum.each(Path.wildcard("_build/prod/lib/*/ebin"), &Code.prepend_path/1); {:ok, _} = Application.ensure_all_started(:lumis); {:ok, _} = Lumis.Languages.cache(Fountain.Docs.languages())' \
 && mix release fountain_server

# ---

FROM debian:trixie-slim AS runtime

# Git SHA of the source commit, surfaced in-app under the sidebar email
# popup so we can confirm at-a-glance which build is running. Wired up by the build workflow; falls
# back to "dev" for local `docker build` invocations.
ARG BUILD_SHA=dev

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000 \
    FOUNTAIN_BUILD_SHA=$BUILD_SHA

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 1001 fountain \
 && useradd --system --uid 1001 --gid fountain --no-create-home fountain

WORKDIR /app

COPY --chown=fountain:fountain --from=build /app/_build/prod/rel/fountain_server ./

EXPOSE 4000

USER fountain

ENTRYPOINT ["/usr/bin/tini", "--"]
# Migrations run on every boot. Idempotent (Ecto.Migrator skips
# already-applied versions) and serialized by a Postgres advisory lock, so
# safe under rolling updates; the readiness probe gates traffic until
# migrate + start completes.
#
# MIGRATE_ON_BOOT=false turns this into a plain start, for a deployment that
# runs `bin/migrate` once in a Job instead (#610). `bin/migrate` ignores the
# switch — it is the Job's entrypoint.
CMD ["/bin/sh", "-c", "/app/bin/fountain_server eval 'Fountain.Release.migrate_on_boot()' && exec /app/bin/fountain_server start"]
