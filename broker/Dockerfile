FROM hexpm/elixir:1.19.2-erlang-28.3-debian-trixie-20260610-slim AS build
ENV MIX_ENV=prod
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
RUN mix release
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build --chown=nobody:nogroup /app/_build/prod/rel/remote_broker ./
USER nobody
ENV ERL_FLAGS="+S 2:2"
CMD ["/app/bin/remote_broker", "start"]
