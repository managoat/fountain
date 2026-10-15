# Ship an app

The only server-side fact an app depends on is its OAuth client registration
on the Managoat it talks to (SKILL.md section 5). Everything below is about
hosting the app itself.

## Static SPA

`bun run build` → `dist/`. Host it anywhere that serves files:

| Host | Notes |
|---|---|
| GitHub Pages | `VITE_BASE=/<repo>/`; the redirect URI is `https://<user>.github.io/<repo>/` (or the custom domain), path included. A Pages workflow is a dozen lines: build with that base, upload `dist/`, deploy. |
| A CDN / object bucket | Nothing special; SPA fallback to `index.html` if the app uses path routing (hash routing avoids the need). |
| An nginx container | `nginx:alpine` + `COPY dist/`, `try_files $uri $uri/ /index.html`, `/assets/*` immutable 1y, everything else `no-cache`, a `/healthz` that returns 200. fountain-demos' `Dockerfile` + `nginx.conf` is the template. |

**Build the SPA on the CI runner, not inside the image.** The image stage is
then a plain copy, so a multi-arch build costs nothing and no emulated bun
runs under QEMU.

CI (`ci.yml`, on PR + main): `bun install --frozen-lockfile`, `typecheck`,
`bun test`, `build`, upload `dist`. A release workflow (`build.yml`, on push
to main) builds and pushes the image tagged `latest` and `sha-<commit>`;
pinning the sha into your deployment manifest from the workflow is what
makes a rollout reproducible. `paths-ignore` the manifest you pin into, or
the pin commit re-triggers the build.

## An app with a server

One container: `oven/bun:1-alpine` + `COPY server/ shared/ dist/`, the server
serving `dist/` itself (hashed assets immutable, the rest `no-cache`, unknown
paths → `index.html`). Env: `MANAGOAT_URL`, `PORT`, `DATA_DIR` (a volume, if
SQLite), a secret for session/cookie signing that is generated to `DATA_DIR`
when unset. One replica with `Recreate` if the state is a local SQLite file.
fountain-workbench's `Dockerfile`, `server/config.ts` and `k8s/` are the
template; the Kubernetes files there (Deployment, Service, ingress, cert) are
ordinary and translate to any cluster or a single VM with a reverse proxy.

## Verify after deploy

1. `curl -sI -X OPTIONS -H 'Origin: https://<host>' -H 'Access-Control-Request-Method: GET' https://<fountain>/api/auth/me` → an `access-control-allow-origin` header. Without it, every call from the app fails before it starts.
2. Sign in from the hosted build in **Firefox** and Chrome. A stray `oauth:<app>` key per failed attempt under Account → API keys means the callback threw *after* the token exchange — look at what ran next, usually `me()`.
3. Run an agent, send one message, watch `turn/done` arrive on the stream.
