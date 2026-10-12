# Local setup

This page bootstraps a fresh machine to run, test and deploy Fountain. The
machine can be a laptop, a short-lived VM or a codespace. The work takes about
10 minutes on a fast connection.

## What you must install first

| Tool | Why | Install |
|---|---|---|
| `mise` | Pins Elixir and Erlang to the versions in `.tool-versions`. | `brew install mise` (macOS) or `curl https://mise.run | sh` (Linux/WSL) |
| `gh` | The GitHub CLI, for the clone and for PRs. | `brew install gh && gh auth login` |
| `psql` | The client for the dev and test databases. | Comes with `brew install postgresql@16` |
| Docker or native Postgres 14+ | Hosts the dev and test database. | `brew install --cask orbstack` or `brew install postgresql@16` |

Install `mise`. Then
[activate it in your shell](https://mise.jdx.dev/getting-started.html#activate-mise).

## 1. Clone

```bash
gh repo clone managoat/fountain
cd fountain
```

## 2. Install the toolchain

```bash
mise install
```

The command reads `.tool-versions` and installs the pinned Erlang/OTP and
Elixir. `.tool-versions` pins the *local* toolchain only. Production runs the
release image, which the repo-root `Dockerfile` builds. That base image pins
its own Erlang and Elixir. `SETUP.md` holds the production parity reference.

Check the result.

```bash
elixir --version
# Erlang/OTP 28 ...
# Elixir 1.19.2 (compiled with Erlang/OTP 28)
```

## 3. Hex and Rebar, once for each toolchain

```bash
mix local.hex --force
mix local.rebar --force
```

## 4. Postgres

**Option A, Docker. Use this one.**

```bash
docker compose up -d postgres
```

The command starts Postgres 16 on `localhost:5432`. If you already run your
own Postgres, set `POSTGRES_HOST_PORT` in `.env` to publish somewhere else.
`docker compose down` stops it, and the data stays in the `postgres_data`
volume.

**Option B, native Postgres.**

```bash
psql -h localhost -U "$USER" -d postgres \
  -c "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres'"
```

Each option satisfies the default `DATABASE_URL` in `config/dev.exs` and
`config/test.exs`.

## 5. Dependencies and database

```bash
mix deps.get
mix setup                           # dev DB: create + migrate
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
```

## 6. Environment variables

Copy `.env.example` to `.env`. Then give each variable a value.

```bash
cp .env.example .env
```

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | The Postgres connection. |
| `MASTER_SECRETS_KEY` | The platform master key for envelope encryption. |
| `SPRITES_TOKEN` | The token for the Sprites sandbox platform. |
| `GITHUB_OAUTH_CLIENT_ID/SECRET` | The GitHub OAuth app. |

| `RESEND_API_KEY` | Transactional email. |

Make a master key.

```bash
openssl rand 32 | base64 | tr '+/' '-_' | tr -d '='
```

## 7. Run

```bash
mix phx.server   # http://localhost:4000
mix test         # full test suite
mix precommit    # same checks CI runs
```

## If something goes wrong

- **`role "postgres" does not exist`.** Go back to step 4.
- **Tests fail with connection pool timeouts.** Check that `config/test.exs`
  sets `pool_size: 20`.
- **`mise` is slow on the first run.** That is normal. It compiles Erlang from
  source, which takes about 5 minutes. Later runs use the cache.
