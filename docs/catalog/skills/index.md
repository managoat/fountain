# Skills

A skill is a `SKILL.md` that Managoat writes into the sandbox. The runtime
reads it to learn a capability. You declare skills on an
[Agent](../../concepts/agent.md).

## Bundled in each sandbox

Managoat writes this one into **each** sandbox, whatever an agent declares.

| Skill | What it does |
|---|---|
| [managoat](managoat.md) | Gives the agent Managoat's own API, so it can start sub-conversations and stream them. |

## How to declare your own

There are two forms, and they behave differently.

**Inline.** Managoat writes the whole file to
`<skills_root>/<name>/SKILL.md`.

```yaml
skills:
  - name: house-style
    content: |
      ---
      name: house-style
      description: Our commit message and PR conventions.
      ---
      # House style
      ...
```

**From GitHub.** The [skills.sh](https://skills.sh) CLI installs it on the
sandbox.

```yaml
skills:
  - source: anthropics/skills
    ref: main             # optional: a tag, branch or sha
    name: frontend-design # optional: install one named skill from the source
```

With no `ref`, Managoat resolves the repository's default branch **when it
installs the skill**. Two conversations from the same agent, a week apart, can
install different code. Pin a `ref` on whatever you depend on.

## How they land

**A GitHub install goes through the broker.** It needs `registry.npmjs.org`
and `github.com`, and it reaches them the way a package install does: through
the conversation's proxy, after the broker's CA and the network floor are in
place. The install gets the proxy and CA variables and none of your secrets.
Under a `limited` environment, put both hosts in `allowed_hosts`, or the
install is refused and the agent runs without that skill. See
[Environment](../../concepts/environment.md).

**A wake installs only what is missing.** When a conversation wakes, a GitHub
skill whose directories are still on the disk stays as it is. Managoat
installs it again when it is newly selected, when one of its directories is
gone, or when its `ref` changed. An unpinned skill therefore keeps the code it
first installed for the life of the sandbox.

**A skill that fails to install doesn't fail the conversation.** The server
logs `skills.sh install failed` and the agent runs without that skill.

**A GitHub install runs before an inline write.** The install is an exec that
blocks, and it also serves as the readiness gate that the file-write path
needs.

## The path depends on the runtime

Each runtime declares its own skills root and its own skills.sh agent name. So
one declaration lands in a different place for each `runtime`. Read
[Runtimes](../runtimes/index.md) for the table.

## Not here yet

There is no catalog of third-party skills. Any GitHub repo that ships a
`SKILL.md` works, and Managoat curates no list.

## Related

- [About agents](../../concepts/agent.md), where you declare `skills`.
- [Runtimes](../runtimes/index.md), for where a skill lands on disk.
