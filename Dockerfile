# syntax=docker/dockerfile:1.7
#
# Phoenix release image for Fountain (umbrella). Build stage compiles
# the `fountain_server` release against Erlang/OTP 28 + Elixir 1.19;
# runtime stage copies the release onto a slim Debian base.
#
# Notes:
#   - Umbrella: COPY apps/, ee/, config/, and the root mix.exs/mix.lock.
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
#     `--build-arg BUNDLE_EXTENSIONS=false` builds the CORE image: no Buzz
#     application in the release, no Buzz binaries, no Buzz smoke check.
#     The default is the bundled image, which is what every existing tag
#     has meant and what the hosted deployment runs.

# Global scope, before the first FROM, because a `FROM` line can only
# interpolate an ARG declared out here. Each stage that also *uses* the value
# re-declares it; that is how build args work and not a duplication to tidy.
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
# BUNDLE_EXTENSIONS decides is whether the release *includes* the Buzz application
# and whether this image carries its binaries (ADR 0043 decision 7).
COPY apps/fountain_buzz/mix.exs ./apps/fountain_buzz/mix.exs
COPY apps/fountain_support/mix.exs ./apps/fountain_support/mix.exs
COPY apps/fountain_microsoft/mix.exs ./apps/fountain_microsoft/mix.exs
# One line per umbrella library app (decisions/0037), when there is one: the
# umbrella loads every child's mix.exs to resolve deps, so a missing one fails
# `mix deps.get` here. Every managoat_* library has graduated to hex (#1345,
# then managoat_runtimes under #1368), so there is none today;
# umbrella_layout_test.exs checks any future one.

RUN mix deps.get --only prod \
 && mix deps.compile

COPY apps ./apps
# ee/ is extra elixirc_paths for the fountain app (billing + transactional
# email — decisions/0010). Mix SILENTLY skips missing elixirc_paths dirs:
# without this COPY the release still builds but is missing those modules.
COPY ee ./ee
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
# 7, and see mix.exs). Declared in this stage as well as the asset stage below
# because a build ARG is scoped to the stage that declares it — and the two must
# agree, or the image gets the extension without its binaries or the reverse.
ARG BUNDLE_EXTENSIONS=true
RUN mix compile \
 && elixir -e 'Enum.each(Path.wildcard("_build/prod/lib/*/ebin"), &Code.prepend_path/1); {:ok, _} = Application.ensure_all_started(:lumis); {:ok, _} = Lumis.Languages.cache(Fountain.Docs.languages())' \
 && mix release fountain_server

# ---
# The `fountain` Go CLI. It is the ACP *child* a hosted buzz-acp harness drives
# (ADR 0020): buzz-acp runs `fountain acp`, which talks HTTP/SSE back to this
# same server. Built for the image's target arch (both amd64 and arm64).

FROM golang:1.27-bookworm AS gocli
WORKDIR /src
COPY cli/go.mod cli/go.sum ./
RUN go mod download
COPY cli/ ./
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH:-amd64}" \
      go build -trimpath -o /out/fountain ./cmd/fountain

# ---
# The Buzz extension's native assets (ADR 0043, #1509). Everything in this
# section belongs to `apps/fountain_buzz` and is present only in the BUNDLED
# distribution: `--build-arg BUNDLE_EXTENSIONS=false` selects the empty stage below
# instead, and the resulting image carries no Buzz binary, runs no Buzz smoke
# check and, through `BUNDLE_EXTENSIONS` in mix.exs, does not even include the
# extension application.
#
# block/buzz publishes an amd64 .deb only, and our cluster is arm64 (ADR 0020,
# #743), so we build buzz-acp ourselves for both arches from the block/buzz
# source and publish it as a Fountain release asset
# (`.github/workflows/buzz-acp-publish.yml`). Here we just download the
# arch-matched binary and verify its checksum — no compile in the image build.
# The pin lives in apps/fountain_buzz/buzz-acp.version and is passed as
# BUZZ_ACP_VERSION by the build workflow; the default below keeps a local
# `docker build` working. (buzz-acp.source may point the publish workflow at a
# fork — the version is then only the release name; see that workflow. #776
# tracks repinning to upstream once block/buzz#6088 ships.)

FROM debian:trixie-slim AS native-assets-true
ARG TARGETARCH
ARG BUZZ_ACP_VERSION=0.5.14-fountain.4
# buzz-acp: the hosted harness (gate 2). buzz: the CLI the server-side MCP tools
# shell out to for signed publishes (gate 3, #737). Both from our own release.
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && mkdir -p /out \
 && base="https://github.com/managoat/fountain/releases/download/buzz-acp-v${BUZZ_ACP_VERSION}" \
 && for bin in buzz-acp buzz; do \
      asset="${bin}-linux-${TARGETARCH:-amd64}" \
      && curl -fsSL -o "/out/${bin}" "${base}/${asset}" \
      && curl -fsSL -o /tmp/sha "${base}/${asset}.sha256" \
      && echo "$(cat /tmp/sha)  /out/${bin}" | sha256sum -c - \
      && chmod 0755 "/out/${bin}" ; \
    done \
 && rm -rf /var/lib/apt/lists/* /tmp/sha

# The core distribution's version of the same stage: an empty /out. Copying a
# directory that happens to be empty is a no-op, so the runtime stage below
# needs no conditional COPY — the only thing that varies is which of these two
# it copies from.
FROM debian:trixie-slim AS native-assets-false
RUN mkdir -p /out

# The one line that makes an image core or bundled. `BUNDLE_EXTENSIONS` is declared in
# the global scope at the top of this file, which is the only place a FROM can
# read an ARG from.
FROM native-assets-${BUNDLE_EXTENSIONS} AS native-assets

# ---

FROM debian:trixie-slim AS runtime

# Git SHA of the source commit, surfaced in-app under the sidebar email
# popup so we can confirm at-a-glance which build is running (and that
# we're on home-cloud vs Render). Wired up by the build workflow; falls
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

COPY --from=gocli /out/fountain /usr/local/bin/fountain

# The Buzz extension's binaries, or nothing at all. `buzz-assets` resolves to
# the download stage in a bundled build and to an empty directory in a core one
# (ADR 0043 decision 7), so this one COPY serves both distributions and the
# core image ends up with an empty /usr/local/lib/fountain-buzz.
#
# buzz-acp is the harness; buzz is the CLI the extension's MCP tools shell out
# to for signed publishes. Both our own builds, for both arches.
COPY --from=native-assets /out/ /usr/local/lib/fountain-buzz/

# Fail the build now if a baked binary will not run in this image, rather than
# at the first request, harness start or publish. The Buzz half is checked only
# where it was meant to be copied: absent binaries are the core distribution
# working, and absent binaries in a BUNDLED build are a broken one.
ARG BUNDLE_EXTENSIONS=true
RUN /usr/local/bin/fountain --version >/dev/null 2>&1 \
      || { echo "the fountain CLI will not run in this image" >&2; exit 1; }
RUN if [ "${BUNDLE_EXTENSIONS}" = "true" ]; then \
      /usr/local/lib/fountain-buzz/buzz-acp --help >/dev/null 2>&1 \
   && /usr/local/lib/fountain-buzz/buzz --help >/dev/null 2>&1 \
        || { echo "a baked Buzz binary will not run in this image" >&2; exit 1; } ; \
    else \
      test -z "$(ls -A /usr/local/lib/fountain-buzz 2>/dev/null)" \
        || { echo "BUNDLE_EXTENSIONS=false but Buzz binaries were baked in" >&2; exit 1; } ; \
    fi

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
