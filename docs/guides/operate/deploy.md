# Deploy an instance

This guide takes a Fountain instance from first boot to its first successful
conversation with Docker Compose. You verify readiness, create the first admin
account, close registration, and exercise the database, encryption, inference
and sandbox provider end to end.

For a development environment on your own machine, read
[Setup](../../setup.md). That is a different thing. This guide is for an
instance that stays up.

## Before you start

You must have Docker Engine with Compose v2, and `openssl` for the two key
lines below. Fountain requires Postgres 16 or newer. The compose file runs one
for you, or you can point Fountain at a Postgres you operate.

Your machine must also reach `ghcr.io`, the registry that holds the published
image. Does your network block it? Then comment the `image:` line in
`docker-compose.yml`, uncomment the `build: .` line under it, and compose
builds the image from this checkout.

You must also have a sandbox provider token. Read
[Self-host Fountain](../../self-hosting.md) for what each provider needs, and
for where a token comes from.

## Bring it up

```bash
git clone https://github.com/managoat/fountain
cd fountain

cp .env.compose.example .env
echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')" >> .env
echo "MASTER_SECRETS_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')" >> .env
# add your SPRITES_TOKEN to .env

docker compose up -d
```

Do you reach this instance by a host other than `localhost`? Then set
`PUBLIC_URL` in `.env` as well. It defaults to `http://localhost:4000`, it
builds the links in verification emails, and every sandbox reads it as
`FOUNTAIN_BASE_URL`. [Put it on the internet](put-it-on-the-internet.md)
covers the rest of a public deployment.

Back `MASTER_SECRETS_KEY` up now, before you have data. It is not in the
database, so a database backup alone does not protect you. Read
[Back up and restore](back-up-and-restore.md).

These guides explain each variable that shapes a deployment as it comes up.
The [configuration reference](../../configuration.md) holds the complete list,
and it includes the deploy-level variables that the compose file never
mentions.

## Verify the instance is ready

The app applies database migrations before it opens a listener, so a cold
start takes up to a minute. Wait for the app container to report `healthy`,
then probe it.

```bash
docker compose ps
# wait for the app to report healthy, then:
curl -sS localhost:4000/health/ready
# {"checks":{"database":"ok"},"status":"ok"}
```

Expect refused connections during first boot until migrations finish. If the
app still refuses connections after a minute, inspect
`docker compose logs -f app`.

## Register the first account

Open <http://localhost:4000> and create your account.

The compose defaults are `EMAIL_DELIVERY=none` and `FIRST_USER_ADMIN=true`.
Your account then self-verifies at registration, and Fountain promotes it to
admin because it is the first. The admin audit trail records the grant, like
any other role change (ADR 0011).

Register **before** you expose the instance to a network you do not trust.
While no admin exists, the first verified account takes the role.

For the manual path, set `FIRST_USER_ADMIN=false` and use a release task. Read [Run a release task](run-a-release-task.md).

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.promote_admin("you@example.com")'
```

## Close registration

```bash
echo "REGISTRATION_ENABLED=false" >> .env
docker compose up -d
```

Registration is open by default. Disable it immediately after you create the
first admin and before you expose the instance to an untrusted network.

## Point the apps at it

Fountain's own UI is a console. It covers the account, its keys, and the
agents, environments and vaults that a conversation runs on. To watch a
conversation turn by turn, and to message an agent as a teammate, you use
separate single-page apps that talk to your `/api`.

| | |
|---|---|
| [Conversations](https://fountain-conversations.demo.managoat.com/) | Start a run, watch it, steer it, read the raw log. |
| [Team](https://fountain-team.demo.managoat.com/) | Your agents as teammates, one thread for each. |

They are static builds with no server of their own. You type your Fountain's
URL in, so the hosted copies above work against your deployment as soon as it
admits the origin.

```bash
echo "API_CORS_ORIGINS=https://fountain-conversations.demo.managoat.com" >> .env
```

To click "Sign in with Fountain" instead of a paste of an API key, register
them in `OAUTH_CLIENTS`. Read the
[configuration reference](../../configuration.md).

The console links to whatever `CONVERSATIONS_APP_URL` and `TEAM_APP_URL` say.
Point those at your own build of either repo and it works the same way. Set
them to `""` to tell the console that this deployment has neither, and the
console stops the offer.

## Prove the whole path

Readiness checks Fountain's connection to Postgres. It does not check
encryption, inference credentials or the sandbox provider. In the console, add
a model credential under Settings, then Inference credentials. Open
Conversations and start a run. A first turn confirms that Fountain can read
Postgres, decrypt the credential, reach the model provider and start a sandbox
through the selected provider.

## Start over

```bash
docker compose down -v
```

The `-v` flag deletes the database volume, and every account and conversation
in it. Keep the same `MASTER_SECRETS_KEY` when you keep the volume. A new key
cannot unwrap what the old key wrapped. Every stored environment and vault
value then becomes unreadable.

## If it did not work

Does the app serve while a sandbox fails to start? The sandbox provider is the
usual cause. Read [Sandbox errors](../../troubleshooting/sandbox-errors.md).

If the container never opens a listener, migrations cannot reach the
database. Read
[Pods restart or never go ready](../../troubleshooting/pods-restarting.md).

## Related

- [Put it on the internet](put-it-on-the-internet.md), the next step.
- [Back up and restore](back-up-and-restore.md).
- [Configuration reference](../../configuration.md).
- [Architecture](../../architecture.md), for what runs, and what breaks when a
  dependency is down.
