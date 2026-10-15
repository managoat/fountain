---
type: ADR
title: "Opt out of sandbox Fountain API credentials"
description: "An immutable conversation option omits Managoat callback credentials from the sandbox for untrusted host-managed work."
tags: [security, sandbox, api]
status: stable
adr: "0045"
adr_status: "Accepted"
date: 2026-09-05
generated: { by: human:jhgaylor, at: 2026-09-05T23:00:00-04:00 }
verified: { by: claude-code/opus-5, at: 2026-10-13T00:00:00-04:00 }
stale_after: 2027-01-13
---

# 0045 — Opt out of sandbox Fountain API credentials

**Status:** Accepted, built (d4fb0eb8, 2026-09-05): `sandbox_api_access` is a
conversation option (`owner` or `none`) and `GET /api/catalog` lists it. Was:
Proposed, implemented with regression tests before release.

## Context

A host application can process several repositories under one Fountain account.
Fountain's generated sandbox callback key authenticates as the account with
`sprite` scope. Conversation APIs enforce account ownership, not the identity
of the conversation that received the key. A separate machine for each
repository therefore does not, by itself, separate their API authority.

Review Loop needs workers that can inspect and fix untrusted PR content while
its host owns policy enforcement, GitHub writes, and Fountain orchestration.
Those workers return files and do not need Fountain callback tools.

## Decision

Conversation creation accepts immutable `sandbox_api_access`: `owner` retains
the current behavior and is the default for existing and new rows; `none`
never mints a Fountain sandbox callback credential. The callback-key path
honors the option on initial provision, wake, and reattachment. The conversation
response records it and the catalog advertises the supported values.

`none` requires a fresh ephemeral sandbox. It refuses existing-machine attach,
subsequent conversation sharing, and a channel resume that explicitly requests
a different setting. These checks prevent inheriting a credential from another
conversation or injecting one through later machine sharing.

## Consequences

The host retains its account API key and can send prompts and retrieve events
and files. The worker loses Fountain MCP tools and connections that require
the callback credential. Model inference credentials remain a separate concern.

This is not a credential scrubber or network isolation. An operator can still
supply credentials through an environment, vault, or custom MCP configuration.
Hosts processing mutually untrusted repositories must use a dedicated account
containing only workers with `none` and keep full account keys outside them.

Apply the migration and roll out all API nodes before relying on the catalog
capability. A mixed deployment can advertise support on one node while another
still uses the previous provisioning behavior. Live provider and application
acceptance tests remain release work.

## Alternatives considered

- Separate machines alone leave account-scoped callback API authority intact.
- Revoking or removing credentials after launch leaves a provisioning race and
  does not establish behavior on wake or reattachment.
- Per-conversation callback authorization could retain selected worker tools,
  but requires a separate authorization design across callback API surfaces.
- One account per repository changes account lifecycle and billing ownership;
  it does not provide a worker without host API authority within that account.

## Addendum — 2026-10-15: every sandbox is fresh

The requirement that `none` take a fresh ephemeral sandbox, and its refusals
of an existing-machine attach and later sharing, no longer distinguish it.
Every conversation gets a sandbox of its own
([0073](0073-one-sandbox-per-conversation.md)): `sandbox_id` on creation
answers `422 sandbox_attach_unsupported`, persistent sandboxes are gone, and
no conversation joins another's machine. A channel resume that asks for a
different `sandbox_api_access` is still refused.
