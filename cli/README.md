# Fountain CLI (Go)

Single-binary port of the Fountain CLI from Elixir/Burrito to Go. Same
command surface, same API contract, same `~/.fountain/credentials` file.

## Why a port

The CLI is an HTTP/JSON client with subprocess shellouts (1Password,
Bitwarden Secrets Manager, Infisical) and an SSE stream consumer. None
of that needs the BEAM. Burrito wraps Elixir releases in a Zig-built
launcher so the BEAM ships inside the binary; that pipeline has been
fragile (Zig version pinning, slow startup, large binaries) and the
runtime concurrency model adds nothing for a CLI.

The Go binary is ~10 MB, statically linked, starts in <50 ms, and
cross-compiles cleanly with stdlib tooling.

## Build

Requires Go 1.26+.

```sh
cd cli
go build -o fountain ./cmd/fountain
./fountain --help
```

Cross-compile:

```sh
GOOS=linux  GOARCH=amd64 CGO_ENABLED=0 go build -o fountain-linux-amd64  ./cmd/fountain
GOOS=linux  GOARCH=arm64 CGO_ENABLED=0 go build -o fountain-linux-arm64  ./cmd/fountain
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -o fountain-darwin-amd64 ./cmd/fountain
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -o fountain-darwin-arm64 ./cmd/fountain
```

The `cli-release-go.yml` workflow builds and attaches all four to the
GitHub release on tag push.

## Layout

```
cli/
  cmd/fountain/         entry point
  internal/
    api/                HTTP client (Bearer auth, JSON, error envelope)
    cmd/                Cobra command tree (auth, keys, env, agent, vault, conv, run, apply)
    config/             API key + base URL precedence resolver
    credentials/        ~/.fountain/credentials reader/writer (TOML-ish)
    manifest/           YAML doc reader for `apply`
    output/             table + JSON rendering helpers
    secrets/            external secret resolvers (op, bws, infisical)
    sse/                RFC 6202 Server-Sent Events parser
    substitution/       ${VAR} expansion (with $${VAR} escape)
```

## Test

```sh
go test ./...
```

Coverage focuses on the pure logic — credentials parser, substitution,
SSE framing, manifest loading. Command handlers (which only assemble
HTTP requests) are validated by smoke runs against a real server.

## History

This binary replaced the Elixir/Burrito CLI that previously lived at
`apps/fountain_cli/`. The `${VAR}` substitution module the server still
needs at provision time was moved into the server app, where it is
`Fountain.Substitution` (it spent 2026-09 and 2026-10 as the hex library
`managoat_substitution`, decisions/0037); everything else was deleted. `internal/substitution` here
is the Go implementation of the same syntax and the two are kept aligned.

The `up` / `down` self-deploy commands were removed before the Go port
and are not reintroduced.

## Install

Pre-built binaries are attached to each GitHub release:

```sh
# macOS arm64
curl -L -o fountain https://github.com/managoat/fountain/releases/latest/download/fountain-darwin-arm64
chmod +x fountain && sudo mv fountain /usr/local/bin/

# Linux amd64
curl -L -o fountain https://github.com/managoat/fountain/releases/latest/download/fountain-linux-amd64
chmod +x fountain && sudo mv fountain /usr/local/bin/
```

Pinned versions are at `https://github.com/managoat/fountain/releases/download/<tag>/fountain-<os>-<arch>`.

## Streaming long turns

`fountain run`, `fountain conv prompt` and `fountain conv stream` follow a
conversation until the turn reaches a terminal state.

The server closes an SSE connection after 60 seconds of quiet, so a turn that
thinks for a while without emitting output will see the connection drop. The CLI
reconnects using `Last-Event-ID`, so anything produced while disconnected is
replayed rather than lost, and a dropped connection is never mistaken for a
finished turn.

If nothing arrives at all for 30 minutes the CLI gives up with an explicit
error naming the conversation, rather than exiting successfully. Override the
wait with `FOUNTAIN_STREAM_IDLE_TIMEOUT` (seconds):

```sh
FOUNTAIN_STREAM_IDLE_TIMEOUT=7200 fountain run researcher -p "audit the auth module"
```

Reattach to a conversation at any time — nothing is lost by disconnecting:

```sh
fountain conv stream <conversation-id>
```
