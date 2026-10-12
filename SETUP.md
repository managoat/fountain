# Local workstation setup

Bootstrap a fresh machine (laptop, ephemeral VM, codespace) to run, test, and deploy Fountain. Should take ~10 minutes on broadband.

## Prerequisites

| Tool       | Why                                                                 | Install                                                                 |
| ---------- | ------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `mise`     | Pins Elixir/Erlang to the exact versions in `.tool-versions`.       | `brew install mise` (macOS) · `curl https://mise.run \| sh` (Linux/WSL) |
| `gh`       | GitHub CLI for cloning and PRs.                                     | `brew install gh && gh auth login`                                      |
| `psql`     | Client for the dev/test Postgres.                                   | Comes with `brew install postgresql@16`. Match the server major (16): an older `pg_dump` refuses a newer server, which is the backup drill.                   |
| Docker *or* native Postgres 16 | One way to host the dev/test database.                  | `brew install --cask orbstack` (or Docker Desktop), or `brew install postgresql@16 && brew services start postgresql@16`. |

After installing `mise`, [activate it in your shell](https://mise.jdx.dev/getting-started.html#activate-mise):

```bash
# zsh
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc

# bash
echo 'eval "$(mise activate bash)"' >> ~/.bashrc
```

Open a new shell so `mise` is on the PATH.

## 1. Clone

```bash
gh repo clone managoat/fountain
cd fountain
```

## 2. Install the toolchain

```bash
mise install
```

This reads `.tool-versions` and installs the pinned Erlang/OTP and Elixir versions (~5 min on first run, cached after). `.tool-versions` pins the *local* toolchain only; production runs the release image built from the repo-root `Dockerfile`, whose base image pins its own Erlang/Elixir (see [Production parity reference](#production-parity-reference)).

Verify:

```bash
elixir --version
# Erlang/OTP 28 ...
# Elixir 1.19.2 (compiled with Erlang/OTP 28)
```

## 3. Hex + Rebar (one-time, per-toolchain)

```bash
mix local.hex --force
mix local.rebar --force
```

## 4. Postgres

Pick **one** path:

### Option A — Docker (recommended for ephemeral machines)

```bash
docker compose up -d postgres
```

Brings up Postgres 16 on `localhost:5432` with role `postgres`/`postgres` (already running your own Postgres? set `POSTGRES_HOST_PORT` in `.env` to publish elsewhere). `mix setup` creates `fountain_dev` itself. (`docker compose up` with no service name also starts Fountain — see [self-hosting](docs/self-hosting.md).) Stop with `docker compose down`; data persists in the `postgres_data` volume.

### Option B — Native Postgres

If you already run Postgres locally (e.g. `brew services start postgresql@16`), make sure a `postgres` superuser role exists with password `postgres`:

```bash
psql -h localhost -U "$USER" -d postgres \
  -c "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres'"
```

(Skip if you already have it.)

Both paths satisfy the default `DATABASE_URL` baked into `config/dev.exs` and `config/test.exs`. To override, export `DATABASE_URL` before any `mix` command.

## 5. Dependencies and database

```bash
mix deps.get
mix setup        # deps.get + ecto.setup for the dev DB
```

For the test DB:

```bash
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
```

## 6. Run

```bash
mix phx.server   # http://localhost:4000
mix test         # full suite
```

`mix precommit` runs the local gate; its stages, and what CI runs on top, are in [CONTRIBUTING.md](CONTRIBUTING.md#before-you-push). Run it through the pinned toolchain (activate mise, or `mise exec -- mix precommit`); it refuses a different Elixir.

## Production parity reference

The release image is built from the repo-root `Dockerfile`, and `deploy/` holds the portable Kubernetes baseline (decisions/0032). The Erlang/Elixir toolchain is pinned in three places, and a toolchain bump must update all of them:

| Where                      | What pins the toolchain                                              |
| -------------------------- | -------------------------------------------------------------------- |
| `.tool-versions`           | `erlang` / `elixir` lines (local dev via mise)                       |
| `Dockerfile`               | the `FROM hexpm/elixir:<elixir>-erlang-<otp>-...` build-stage base image |
| `.github/workflows/ci.yml` | `elixir-version` / `otp-version` in the `erlef/setup-beam` step      |

The lockstep is enforced by `apps/fountain/test/fountain/toolchain_lockstep_test.exs` — if the three pins disagree, the test suite goes red.

## Troubleshooting

- **`role "postgres" does not exist`** — see step 4. Either `docker compose up -d postgres` or create the native role.
- **Compile warnings about `OpentelemetryPhoenix` / `OpentelemetryEcto`** — these deps are `:prod`-only; `apply/3` is used to defer symbol resolution. If you see warnings, you're probably on stale `_build`; `rm -rf _build deps && mix deps.get && mix compile` to reset.
- **mise installs Erlang from source and it's slow** — that's normal on first run. Subsequent installs (and ephemeral machines that share a mise cache) reuse the build.
- **Tests fail with `rate_limited` errors** — shouldn't happen: `config/test.exs` sets `rate_limit_test_isolation: true`, which keys `FountainWeb.Plugs.RateLimit` buckets by the calling test process instead of a shared IP. If you see this, check that the flag is still set in `config/test.exs` (it's a correctness guard — don't remove it) and that your test isn't issuing enough requests from one process to legitimately exceed a bucket's limit.
