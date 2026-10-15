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

**From GitHub.** Managoat fetches the repository onto the sandbox and copies
the skill directories it finds into the runtime's skills root.

```yaml
skills:
  - source: anthropics/skills
    ref: main             # optional: a tag, branch or full commit sha
    name: frontend-design # optional: install one named skill from the source
```

Without a `name`, every skill in the repository is installed. With one, the
skill whose `SKILL.md` frontmatter has that `name` is installed, ignoring
case. Either way a skill's directory is named after its frontmatter `name` in
kebab case, not after its directory in the repository.

Skills are found the way the [skills.sh](https://skills.sh) CLI finds them: a
`SKILL.md` at the repository root is the only skill; otherwise the root's
subdirectories, `skills/` and the agent directories such as `.claude/skills`
(up to three levels down), and the directories a `.claude-plugin`
manifest lists. Only when none of those has a skill is every `SKILL.md` up to
five levels down used. A `SKILL.md` without a `name` and a `description` in
its frontmatter isn't a skill. One marked `metadata.internal: true` is
installed only when asked for by `name`. To search one directory of the
repository instead, name it in the source: `source: owner/repo/path/to/dir`.

Each repository is fetched once per sandbox start, however many entries name
it, and different repositories are fetched at the same time. A fetch takes
about a second.

With no `ref`, Managoat resolves the repository's default branch **when it
installs the skill**. Two conversations from the same agent, a week apart, can
install different code. Pin a `ref` on whatever you depend on.

## How they land

**A GitHub install goes through the broker.** It is a `git fetch` from
`github.com`, and it reaches GitHub the way a package install does: through
the conversation's proxy, after the broker's CA and the network floor are in
place. The fetch gets the proxy and CA variables and none of your secrets. A
GitHub credential bound to `github.com` is added by the broker, so a private
repository works too. Under a `limited` environment, put `github.com` in
`allowed_hosts`, or the fetch is refused and the agent runs without that
skill. See [Environment](../../concepts/environment.md).

**A wake installs only what is missing.** When a conversation wakes, a GitHub
skill whose directories are still on the disk stays as it is. Managoat
installs it again when it is newly selected, when one of its directories is
gone, or when its `ref` changed. An unpinned skill therefore keeps the code it
first installed for the life of the sandbox.

**A skill that fails to install doesn't fail the conversation.** The server
logs `github skill install failed` with the reason (the fetch failed, or the
repository has no skill by that name) and the agent runs without that skill.

**A GitHub install runs before an inline write.** The install is an exec that
blocks, and it also serves as the readiness gate that the file-write path
needs.

## The path depends on the runtime

Each runtime declares its own skills root, and inline and GitHub skills both
land there. So one declaration lands in a different place for each `runtime`. Read
[Runtimes](../runtimes/index.md) for the table.

## Not here yet

There is no catalog of third-party skills. Any GitHub repo that ships a
`SKILL.md` works, and Managoat curates no list.

## Related

- [About agents](../../concepts/agent.md), where you declare `skills`.
- [Runtimes](../runtimes/index.md), for where a skill lands on disk.
