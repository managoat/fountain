# Open source

Fountain is an open-source project. Managoat is one hosted instance of it.
This page says what is open, what is not, and where each thing lives.

## The names

| Name | What it is |
|---|---|
| **Fountain** | The server, the CLI, the SDKs and this manual. The name of the project. |
| **Managoat** | The instance that the maintainer runs at `managoat.com`. It runs the same code that you can run. |

The hosted instance has a different name so that "self-host Fountain" and
"use Managoat" are two clear choices. The project is not renamed.

## The licences

| Part | Licence | What it means for you |
|---|---|---|
| The server (`apps/fountain`) | [AGPL-3.0-or-later](https://github.com/managoat/fountain/blob/main/LICENSE) | Run it, change it, host it. If you host a changed version, your users have a right to your source. |
| `cli/` and `sdk/typescript` | [Apache-2.0](https://github.com/managoat/fountain/blob/main/cli/LICENSE) | Build on the API or ship a client in a closed product. Keep the required license and notices when you redistribute it. |

The client parts are permissive on purpose. A connection to Fountain must
never put a licence obligation on your application.

The copyleft has one target. A company that improves Fountain and runs it as a
service owes those improvements to everyone else who runs it. The licence does
not stop a commercial host, in competition with Managoat or not. It stops a
private one.

The
[NOTICE](https://github.com/managoat/fountain/blob/main/NOTICE) file
holds the third-party attribution.

## Where things live

| You want | Go to |
|---|---|
| The code, issues and pull requests | [github.com/managoat/fountain](https://github.com/managoat/fountain) |
| Your own instance | [Self-host Fountain](self-hosting.md) |
| The manual | This site, at `/docs`, on every instance. The markdown is in the repo under `docs/`. |
| The reasons behind the design | `decisions/` in the repo. The ADRs are not on this site. |
| The hosted instance | [managoat.com](https://managoat.com) |
| The CLI | `brew install managoat/tap/fountain`, or the [CLI reference](cli.md). |
| The TypeScript SDK | `@managoat/fountain-sdk` on npm, or the [TypeScript reference](sdk.md). |
| The Python, Elixir or Swift SDK | Retired. `fountain-agent-sdk` on PyPI, `fountain_sdk` on Hex and the `sdk-swift-v*` tags stay published but are no longer maintained; use the TypeScript SDK or the [HTTP API](api.md). |

There is no separate project website. The manual you read now is the project
site, and the repo README is its front page. One copy of each stays correct.

## What the hosted instance adds

Nothing that is not in the repo. Managoat runs the release image with the
egress broker on. The
[configuration reference](configuration.md) lists every switch, so an instance
of your own can match it or not.

## To contribute

Read
[CONTRIBUTING.md](https://github.com/managoat/fountain/blob/main/CONTRIBUTING.md)
and
[CLAUDE.md](https://github.com/managoat/fountain/blob/main/CLAUDE.md)
in the repo. The second file is the contributor guide, and coding agents read
it too.

The [manual contribution guide](https://github.com/managoat/fountain/blob/main/contributing/docs.md)
explains the structural checks and offers optional writing guidance.
