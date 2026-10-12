# Overview

A Fountain instance talks to external services to do its work. It provisions a
sandbox somewhere. It sends mail. Something signs users in. Something can
meter spend. Errors land somewhere. All of that is the operator's business.

One page for each service says three things. What to create on the provider
side. Which env vars come out of it. How to check that it works.

This is the *outbound* half. For the tools that talk **to** a live Fountain,
such as editors, chat surfaces, plugins and SDKs, read
[Plug into Fountain](clients.md). Nothing there needs an env var from here.

| Service | Required? | Env vars | Without it |
|---|---|---|---|
| [A sandbox provider](sandbox-contract.md) | **Yes, one of four.** | `SPRITES_TOKEN` *or* `E2B_API_KEY` *or* `DAYTONA_API_KEY`, or a user's own machine through [`fountain runner`](runners.md), which needs no credential. Add `SANDBOX_PROVIDER` to choose the default. | The app boots, and each conversation fails at provision time. |
| [Mail](mail.md) | **Yes, as a decision.** | `RESEND_API_KEY` *or* `SMTP_*` *or* `EMAIL_DELIVERY=none`, and `EMAIL_FROM`. | Production refuses to boot with none of the three set. |
| [GitHub OAuth](github-oauth.md) | Optional. | `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET` | Email and password auth alone. |

| [Sentry](sentry.md) | Optional. | `SENTRY_DSN`, `SENTRY_ENVIRONMENT` | Fountain reports no error. The SDK is inert, and nothing leaves the instance. |

The sandbox providers are Sprites, E2B, Daytona and a user's own machine. They
have [a section of their own](sandbox-contract.md), because they are one
contract with four implementations. The row above is the short version.

## The service you do not configure

**The operator does not configure the inference providers.** Anthropic, OpenAI
and Gemini are the three, and there is no platform-level API key. Each user
brings their own credentials and enters them at
`/account/inference-credentials` in the app.

A user can enter an Anthropic API key or a Claude Code OAuth token, an OpenAI
API key, and a Gemini API key. Fountain validates each one against the
provider on save, encrypts it for that tenant, and never echoes it back. With
both Anthropic credentials on file, Fountain uses the OAuth token. That bills
a subscription, and not metered usage. Read
[which credential claude uses](../catalog/runtimes/claude.md#which-credential-it-uses).

This is a deliberate design
([ADR 0008](https://github.com/managoat/fountain/blob/main/decisions/0008-byo-inference-credentials.md)).
Inference cost scales with usage, and it belongs to the person who causes it.
Many users also want their own Claude subscription to do the work. If you look
for a place to set `ANTHROPIC_API_KEY` in the server environment, there is
none, on purpose.
