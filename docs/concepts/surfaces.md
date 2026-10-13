# The console, the apps, and the API

This page explains why Fountain's own UI does not show you an agent at work,
and where that happens instead. To connect your own client, read
[Plug into Fountain](../integrations/clients.md).

## Three surfaces, on purpose

| Surface | What it is | Where it runs |
|---|---|---|
| The console | Fountain's own browser UI. | The Fountain server. |
| The apps | Conversations, Team and Workbench. | Their own origins, on `/api`. |
| The API | REST and SSE, with the CLI and the SDKs over it. | Anywhere. |

## The console is an operator console

Fountain's own UI covers the dashboard, agents, environments, vaults, audit,
API keys, account and admin.

It is deliberately not an interactive application. You configure things in it.
You do not watch an agent work in it.

## To watch an agent work, use a different application

Three single-page apps sit on `/api`. Each one has its own origin and its own
OAuth client.

| App | What it does |
|---|---|
| [Conversations](https://github.com/managoat/demos/tree/main/apps/fountain-conversations) | Start a run, watch it, steer it, read the raw log. |
| [Team](https://github.com/managoat/demos/tree/main/apps/fountain-team) | Agents as teammates, one thread for each. |
| [Workbench](https://github.com/managoat/demos/tree/main/apps/fountain-workbench) | Projects over an environment and a vault, work items in them, teammates on the work items. |

The first two replaced in-app LiveViews, and the console links to them.
Workbench replaced no page, so the console does not link it. All three take
your server URL as input.

## Retired browser URLs

The release that contains #2105 removes the old browser redirects. From that
release onward, the paths below return the normal 404 response on hosted and
self-hosted deployments. This also applies to signed-in readers and deployments
with no external app configured.

Use the app URLs from `GET /api/catalog` or the console's app links.
`CONVERSATIONS_APP_URL` and `TEAM_APP_URL` select those destinations.
Replace old bookmarks, support links and links in saved agent instructions
with the destination below. For a link in an old email, copy its
conversation or agent ID into the new destination.

| Retired path | Destination |
|---|---|
| `/conversations` | Conversations app base URL. |
| `/conversations/new` | Conversations app base URL plus `#/new`. |
| `/conversations/:id` | Conversations app base URL plus `#/c/:id`. |
| `/conversations/:id/logs` | Conversations app base URL plus `#/c/:id/logs`. |
| `/team` | Team app base URL. |
| `/team/:agent_id` | Team app base URL plus `#/team/:agent_id`. |
| `/onboarding` and `/onboarding/:step` | `/dashboard` on the Fountain server. |

Keep one slash between the app base URL and `#`. The hosted app defaults work
with a self-hosted server when its CORS configuration admits their origins.
If an app URL is empty, the console omits that app's links. Open `/dashboard`
and use the API or CLI for conversations on that deployment.

This retirement changes browser URLs only; the conversation and team APIs
remain under `/api`.

## Why divide them

**A conversation UI is a real-time application, and a console is not.** A form
that writes a row is one engineering problem. To stream a turn, to render a
tool call, to steer a run mid-turn and to interrupt it is a different one. Put
both in one LiveView, and each change to one risks the other.

**The apps are static builds with no server.** You type your Fountain's URL
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
not in Fountain. The server's job is to serve it.

**Do you self-host?** The hosted apps work against your instance once you set
`API_CORS_ORIGINS`. To host your own build instead, point
`CONVERSATIONS_APP_URL` and `TEAM_APP_URL` at it. Set either one to an empty
string to tell the console that this deployment has no such app. The console
then stops the offer. Read
[Deploy an instance](../guides/operate/deploy.md).

**Do you write something that links a person to a transcript?** Read the URL
from the one place that knows it. The console's links, an email's "open it"
and `/api/catalog` all agree, because they all ask
the same module.

## What this is not

**Not a microservice split.** There is one server and one database. The apps
are static files with no backend of their own.

**Not a plugin system.** The apps are ordinary API clients with no special
access. Yours would have the same.

**Not permanent for the console.** The console keeps whatever a person needs
that is not a conversation. That boundary can move; release notes describe
any URL changes.

## Where to go next

- [Plug into Fountain](../integrations/clients.md), for editors, chat
  surfaces, plugins and SDKs.
- [Build a chat app](../build/index.md), and why the API below it exists.
- [API reference](../api.md).
- [Agents as teammates](teammates.md), which is what the Team app renders.
