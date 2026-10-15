# Overview

A Fountain instance talks to external services to do its work. It provisions a
sandbox somewhere. It sends mail. Something signs users in. Errors land
somewhere. All of that is the operator's business.

One page for each service says three things. What to create on the provider
side. Which env vars come out of it. How to check that it works.

This is the *outbound* half. For the tools that talk **to** a live Fountain,
such as editors, chat surfaces, plugins and SDKs, read
[Ways to drive Fountain](clients.md). Nothing there needs an env var from here.

| Service | Required? | Env vars | Without it |
|---|---|---|---|
| [A sandbox provider](sandbox-contract.md) | **Yes, one of two.** | `SPRITES_TOKEN` *or* `E2B_API_KEY`. Add `SANDBOX_PROVIDER` to choose the default. | The app boots, and each conversation fails at provision time. |
| [Mail](mail.md) | Optional. | `SMTP_*` and `EMAIL_FROM`. | Mail is off. Accounts self-verify at registration, and nobody can reset a password in-app. |
| [GitHub OAuth](github-oauth.md) | Optional. | `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET` | Email and password auth alone. |
| [Sentry](sentry.md) | Optional. | `SENTRY_DSN`, `SENTRY_ENVIRONMENT` | Fountain reports no error. The SDK is inert, and nothing leaves the instance. |

The sandbox providers are Sprites and E2B. They are one contract with two
implementations, and [the sandbox contract](sandbox-contract.md) heads its own
section of the reference. The row above is the short version.

## The inference providers

**The inference providers are optional for the operator.** Anthropic, OpenAI
and Gemini are the three. Each user can bring their own credentials and enter
them at `/account/inference-credentials` in the app.

A user can enter an Anthropic API key or a Claude Code OAuth token, an OpenAI
API key, and a Gemini API key. Fountain validates each one against the
provider on save, encrypts it for that tenant, and never echoes it back. With
both Anthropic credentials on file, Fountain uses the OAuth token. That bills
a subscription, and not metered usage. Read
[which credential claude uses](../catalog/runtimes/claude.md#which-credential-it-uses).

Bringing your own credential is the only way
([ADR 0008](https://github.com/managoat/fountain/blob/main/decisions/0008-byo-inference-credentials.md),
[ADR 0075](https://github.com/managoat/fountain/blob/main/decisions/0075-no-deployment-paid-inference.md)).
Inference cost scales with usage, and it belongs to the person who causes it.
Many users also want their own Claude subscription to do the work. The
deployment holds no inference key of its own.
