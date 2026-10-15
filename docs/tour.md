# A guided tour: an agent that opens a pull request

At the end of this page you have an agent that clones your repository, changes
it, and opens a pull request. You can then ask for a revision. The revision
lands on the same PR seconds later, because the sandbox it worked in still
runs.

The tour is about forty lines. Each number and each output below came from a
real run.

This is the second page. The [quickstart](quickstart.md) is the first one: a
key and one request, with no repository and no token. Read it first if nothing
has answered on your account yet.

## What you must have

- A Managoat API key (the API keys section of Account, or `managoat auth login`).
- A repository that you let an agent push a branch to.
- A GitHub token that can push to it. Use a
  [fine-grained token](https://github.com/settings/personal-access-tokens)
  scoped to that one repository. The agent gets a true credential, so give it
  the smallest one that works.

```bash
npm install @managoat/sdk
```

```ts
import { Managoat } from "@managoat/sdk";

const managoat = new Managoat();          // MANAGOAT_API_KEY
const REPO = "https://github.com/you/your-app";
```

## 1. The machine

An [environment](primitives.md) describes the machine the agent gets. You
describe it once and use it again. Here it is a checkout of your repository.

```ts
const environment = await managoat.environments.create({
  name: "tour-workspace",
  repositories: [
    {
      url: REPO,
      mount_path: "/work/app",
      secret_key: "GITHUB_TOKEN",   // ← see the warning below
    },
  ],
  setup_script: "cd /work/app && npm install",
});
```

!!! warning "A private repository needs `secret_key`"

    Set `secret_key` on a **private** repository. It names the secret that the
    clone authenticates with. Omit it and the clone fails in the sandbox. The
    conversation still starts, your agent opens on an empty directory, and it
    tells you that it cannot find the repo. This page cost one wasted run to
    exactly that. A public repository does not need the key.

## 2. The credential

A [vault](primitives.md) is a bag of secrets that you choose for one run.
Managoat decrypts the values into the sandbox when the sandbox spawns. The
values never enter the prompt, the model's context, or the log feed.

```ts
const vault = await managoat.vaults.create({ name: "tour-github" });

await managoat.vaults.secrets.set("tour-github", "GITHUB_TOKEN", process.env.GITHUB_TOKEN!);
await managoat.vaults.secrets.set("tour-github", "GH_TOKEN", process.env.GITHUB_TOKEN!);
```

Two keys, because two things need the token. The clone reads `GITHUB_TOKEN`,
which is the `secret_key` above. The `gh` command reads `GH_TOKEN` when the
agent opens the PR.

You cannot read either one back. `secrets.list()` returns keys and nothing
else. If the agent prints the token, Managoat redacts it from the transcript
before it stores it.

## 3. The agent

The system prompt says how you want the work done. Name the repository path,
and say what "done" means.

```ts
const agent = await managoat.agents.create({
  name: "tour-contributor",
  runtime: "claude",
  model: "anthropic/claude-sonnet-5",
  description: "Opens small pull requests",
  system:
    "You work in /work/app, a git repository. Make the smallest change that " +
    "satisfies the request, commit on a new branch, push, and open a pull " +
    "request with `gh`. Report the PR url and nothing else.",
  environment_id: environment.id,
  allowed_vault_ids: [vault.id],   // this agent can attach that vault, and no other
});
```

## 4. The run

```ts
const run = managoat.run(
  "Add a --version flag that prints 0.1.0 and exits. " +
    "Update the README. Then open a pull request.",
  { agent: "tour-contributor", vault: "tour-github" },
);

for await (const event of run) {
  if (event.type === "tool") console.log("·", event.name);
}

const result = await run;
console.log(result.text);
```

```text
· Terminal
· Read File
· Read File
· Edit
· Edit
· Terminal
· Terminal
· Terminal
· Terminal
· Terminal
https://github.com/you/your-app/pull/1
```

Forty-three seconds. Most of that time went to the sandbox. The pull request
is a real one. It has a `--version` branch, two files changed, and ten lines
added.

To watch nothing, drop the loop. `await managoat.run(...)` gives you the same
result. To wait for nothing, do not await it at all. Hand
`run.conversationId` to whatever polls later.

## 5. The follow-up, which is the point

Ask for a revision.

```ts
const revision = await managoat
  .resume(result.conversationId)
  .send("Also accept -v as an alias for --version, and push it to the same PR.");
```

```text
turn 2 | done | +13s
https://github.com/you/your-app/pull/1
```

**Thirteen seconds, and the same PR.** Managoat cloned nothing again. You
explained nothing again. No second branch appeared.

The sandbox is still up. The checkout sits on the branch that the first turn
made, and `gh` still holds its authentication. The agent's session still holds
what it did and why. That is the difference between an agent that has a
machine and an agent that has a context window.

## 6. Clean up

```ts
await managoat.resume(result.conversationId).terminate();   // the sandbox
await managoat.agents.delete("tour-contributor");
await managoat.vaults.delete("tour-github");                // the credential first, in real code
await managoat.environments.delete("tour-workspace");
```

In a script that can fail, delete the vault in a `finally`. A credential must
not outlive the run that needed it.

## What you built

| Piece | What it decided |
|---|---|
| Environment | Which repository, the mount path, the setup script. |
| Vault | Which credential the sandbox gets, and not the prompt. |
| Agent | The runtime, the model, the system prompt. |
| Conversation | This run, and what you can still ask it. |

Change one of them and the job changes. The other three stay as they are. A
read-only token turns the same agent into one that can only report. A second
environment points it at a different repository.

## The whole thing, in one script

Here is everything above in one file that you can copy and run. It is not a
transcription of the steps. The file is
`sdk/typescript/examples/pull-request.ts`. This page holds it word for word,
and that one file produced each output above.

```ts title="pull-request.ts"
--8<-- "sdk/typescript/examples/pull-request.ts"
```

```bash
MANAGOAT_API_KEY=…  GITHUB_TOKEN=…  REPO_URL=https://github.com/you/your-app \
  node pull-request.ts
```

## How to make it yours

- **Run it from CI.** The same forty lines work in an action. The agent needs
  no checkout on the runner, because the checkout is in the sandbox.
- **Keep the thread.** Store the conversation id, or pass a `channelId`, and
  the next prompt lands in the same conversation. "Each Monday, open a PR that
  bumps the dependencies" is your own cron sending one prompt. Read the
  [SDK page](sdk.md#a-conversation-that-lasts).
- **Fan it out.** Call `managoat.run()` once for each repository, and await
  them together. Each call gets its own sandbox.
- **Narrow the allowlist.** `allowed_vault_ids` names the vaults this agent
  can attach. A vault outside that list stays out of reach.
