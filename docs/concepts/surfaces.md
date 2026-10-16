# The console, the apps, and the API

This page explains why Managoat's own UI does not show you an agent at work,
and where that happens instead. To connect your own client, read
[Ways to drive Managoat](../integrations/clients.md).

## Three surfaces, on purpose

| Surface | What it is | Where it runs |
|---|---|---|
| The console | Managoat's own browser UI. | The Managoat server. |
| The apps | Arugula, Conversations and Workbench. | Their own machines or origins, on `/api`. |
| The API | REST and SSE, with the CLI and the TypeScript SDK over it. | Anywhere. |

## The console is an operator console

Managoat's dashboard introduces the API with a copyable request, key creation
and documentation links, then summarizes the signed-in account's usage and
recent activity. Dashboard and audit use a compact header with links to Docs,
Conversations and Account. Admins also see an Admin link.

The administration console remains at `/admin`, protected by an admin server
session, with its own sidebar for users, sandboxes, broker and admin keys.
Administration is separate from the Account app. The audit page retains its
existing scope: an admin sees every tenant; other users see only their own.
The dashboard's activity summary is always scoped to the signed-in account.
 Account settings
use a static OAuth app over the API. `/account` opens the bundled app by default;
`ACCOUNT_APP_URL` selects a separately hosted copy. It manages API keys, OAuth
apps, connections, inference credentials, secret bindings, passwords and deletion.
Admin-key issuance stays under `/admin/keys`, and ChatGPT subscription linking
stays under `/auth/chatgpt`, both protected by server sessions.

The console does not configure what a conversation runs on. Create and edit agents, environments and vaults
with the [CLI](../cli.md) or a [manifest](../guides/manifests.md), over the
[API](../api.md), or in one of the apps below where it has built that. Help
is this manual. The console links `/docs`, which redirects to the published
manual (`DOCS_URL` in the [configuration reference](../configuration.md#manual)).

## To watch an agent work, use a different application

Managoat's human UIs are separate applications on `/api`. Arugula is the
primary one, and the Conversations app is kept as a second client.

| App | What it does |
|---|---|
| [Arugula](https://github.com/arugula-salad/arugula) | Durable terminals and agent blocks in the browser, the desktop app and on a phone. Its Managoat support (sign-in with the device grant, a conversations view, permission cards, a native conversation link) is tracked in [arugula#942](https://github.com/arugula-salad/arugula/issues/942) and is being built. |
| [Conversations](https://github.com/managoat/demos/tree/main/apps/fountain-conversations) | Start a run, watch it, steer it, read the raw log. Create and edit agents, environments and vaults. |
| [Workbench](https://github.com/managoat/demos/tree/main/apps/fountain-workbench) | Projects over an environment and a vault, work items in them, agents on the work items. |

Conversations and Workbench are single-page apps, each with its own origin
and its own OAuth client. Conversations replaced in-app LiveViews, the
console's conversation pages first and its agent, environment and vault
pages later, and the console links to it.
Workbench replaced no page, so the console does not link it. Both take your
server URL as input.

## Retired browser URLs

The release that contains #2105 removes the old browser redirects. From that
release onward, the paths below return the normal 404 response on every
deployment. This also applies to signed-in readers and deployments
with no external app configured. The agent, environment and vault pages
followed in a later release (ADR 0076), and so did the in-app help, whose
paths still redirect to this manual.

Use the app URLs from `GET /api/catalog` or the console's app links.
`CONVERSATIONS_APP_URL` selects the destination.
Replace old bookmarks, support links and links in saved agent instructions
with the destination below. For a link in an old email, copy its
conversation or agent ID into the new destination.

| Retired path | Destination |
|---|---|
| `/conversations` | Conversations app base URL. |
| `/conversations/new` | Conversations app base URL plus `#/new`. |
| `/conversations/:id` | Conversations app base URL plus `#/c/:id`. |
| `/conversations/:id/logs` | Conversations app base URL plus `#/c/:id/logs`. |
| `/onboarding` and `/onboarding/:step` | `/dashboard` on the Managoat server. |
| `/agents`, `/agents/new`, `/agents/:id/edit`, `/agents/:id/versions` | Conversations app base URL plus `#/agents`, or `managoat apply` (`managoat agent list` and `show` to read). Versions are `GET /api/agents/:id/versions`. |
| `/environments`, `/environments/new`, `/environments/:id/edit` | Conversations app base URL plus `#/environments`, or `managoat apply` (`managoat env list` and `show` to read). |
| `/vaults`, `/vaults/new`, `/vaults/:id/edit` | Conversations app base URL plus `#/vaults`, or `managoat vault` and `managoat apply`. |
| `/agents/:id/avatar` | `GET /api/agents/:id/avatar`, with an API key. |
| `/help` and `/help/:topic` | Still redirects: to the manual's home, or to the page that took the topic. |

Keep one slash between the app base URL and `#`. The hosted app defaults work
with a self-hosted server when its CORS configuration admits their origins.
If an app URL is empty, the console omits that app's links. Open `/dashboard`
and use the API or CLI for conversations on that deployment.

This retirement changes browser URLs only; the conversation, agent,
environment and vault APIs remain under `/api`.

Three console pages moved instead of being retired. Each is now a section
of `/account`, and its old path redirects there with the section open:
`/api-keys`, `/account/oauth-apps` and `/account/security` (the password
form).

## Why divide them

**A conversation UI is a real-time application, and a console is not.** A form
that writes a row is one engineering problem. To stream a turn, to render a
tool call, to steer a run mid-turn and to interrupt it is a different one. Put
both in one LiveView, and each change to one risks the other.

**The apps are static builds with no server.** You type your Managoat's URL
in. So one hosted build works against each deployment, yours as well, as soon
as the server admits the origin.

```
API_CORS_ORIGINS=https://fountain-conversations.demo.managoat.com
```

**It forces the API to be complete.** Make `/api` the only way to watch a
conversation, and `/api` then holds everything a client needs. Anybody who
builds their own client stands level with the first-party one. `?blocks=true`
on the event streams exists for exactly this reason. The server parses the
ACP events into transcript blocks, so clients share one representation.

That last point is the real argument. A console that could do what the API
could not would quietly make the API second-class.

## What this means for you

**Do you build a feature that a conversation shows?** It goes in the app, and
not in Managoat. The server's job is to serve it.

**Do you self-host?** The hosted apps work against your instance once you set
`API_CORS_ORIGINS`. To host your own build instead, point
`CONVERSATIONS_APP_URL` at it. Set it to an empty string to tell the console
that this deployment has no such app. The console
then stops the offer. Read
[Deploy an instance](../guides/operate/deploy.md).

**Do you write something that links a person to a transcript?** Read the URL
from the one place that knows it. The console's links, an email's "open it"
and `/api/catalog` all agree, because they all ask
the same module.

## What this is not

**Not a microservice split.** There is one server and one database.
Conversations and Workbench are static files with no backend of their own,
and Arugula keeps only its own state.

**Not a plugin system.** The apps are ordinary API clients with no special
access. Yours would have the same.

**Not permanent for the console.** The console keeps whatever a person needs
that is not a conversation. That boundary can move; release notes describe
any URL changes.

## Where to go next

- [Ways to drive Managoat](../integrations/clients.md), for editors, chat
  surfaces, plugins and SDKs.
- [Build a chat app](../build/index.md), and why the API below it exists.
- [API reference](../api.md).
