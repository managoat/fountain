/**
 * The guided tour, complete and runnable: an agent that clones your repository,
 * opens a pull request, and then amends the same PR on a follow-up turn.
 *
 *   MANAGOAT_API_KEY=...  # Account → API keys, or `managoat auth login`
 *   GITHUB_TOKEN=...      # fine-grained, scoped to the one repository
 *   REPO_URL=https://github.com/you/your-app
 *
 *   node pull-request.ts
 *
 * Everything it creates — environment, vault, agent, sandbox — is deleted on
 * the way out, including when a step throws.
 *
 * Walkthrough: https://managoat.com/docs/tour
 *
 * (Inside this repository the import below resolves to the SDK itself, so run
 * `npm run build` in sdk/typescript first. Installed from npm it just works.)
 */
import { Managoat } from "@managoat/sdk";

const repo = process.env.REPO_URL;
const token = process.env.GITHUB_TOKEN;
if (!repo || !token) {
  console.error("set REPO_URL and GITHUB_TOKEN");
  process.exit(1);
}

const managoat = new Managoat();
const names = { environment: "tour-workspace", vault: "tour-github", agent: "tour-contributor" };
let conversationId: string | null = null;

try {
  // ── 1. the computer ──────────────────────────────────────────────────────
  // `secret_key` names the secret the clone authenticates with. Leave it out on
  // a private repository and the clone fails *inside the sandbox*: the agent
  // starts anyway, on an empty directory.
  const environment = await managoat.environments.create({
    name: names.environment,
    repositories: [{ url: repo, mount_path: "/work/app", secret_key: "GITHUB_TOKEN" }],
  });

  // ── 2. the credential ────────────────────────────────────────────────────
  // Decrypted into the sandbox at spawn: never in the prompt, never in the
  // model's context, and redacted out of the transcript if the agent prints it.
  const vault = await managoat.vaults.create({ name: names.vault });
  await managoat.vaults.secrets.set(names.vault, "GITHUB_TOKEN", token); // the clone reads this
  await managoat.vaults.secrets.set(names.vault, "GH_TOKEN", token); // `gh` reads this

  // ── 3. the agent ─────────────────────────────────────────────────────────
  await managoat.agents.create({
    name: names.agent,
    runtime: "claude",
    model: "anthropic/claude-sonnet-5",
    description: "Opens small pull requests",
    system:
      "You work in /work/app, a git repository. Make the smallest change that " +
      "satisfies the request, commit on a new branch, push, and open a pull request " +
      "with `gh`. Report the PR url and nothing else.",
    environment_id: environment.id,
    allowed_vault_ids: [vault.id], // this agent may attach that vault, and no other
  });

  // ── 4. the run ───────────────────────────────────────────────────────────
  const run = managoat.run(
    "Add a --version flag that prints 0.1.0 and exits. " +
      "Update the README. Then open a pull request.",
    { agent: names.agent, vault: names.vault, timeoutMs: 15 * 60_000 },
  );

  for await (const event of run) {
    if (event.type === "tool") console.log("·", event.name);
  }

  const result = await run;
  conversationId = result.conversationId;
  console.log(`\n${result.text}\n`);

  // ── 5. the follow-up, which is the point ─────────────────────────────────
  // The sandbox is still up, the checkout is on the branch the first turn made,
  // and `gh` is still authenticated. No re-clone, no re-explaining.
  const revision = await managoat
    .resume(result.conversationId)
    .send("Also accept -v as an alias for --version, and push it to the same PR.");

  console.log(`turn ${revision.turnNumber}: ${revision.text}`);
} finally {
  // ── 6. clean up ──────────────────────────────────────────────────────────
  // The credential goes first, whatever happened above.
  await managoat.vaults.delete(names.vault).catch(() => {});
  if (conversationId) await managoat.resume(conversationId).terminate().catch(() => {});
  await managoat.agents.delete(names.agent).catch(() => {});
  await managoat.environments.delete(names.environment).catch(() => {});
  console.log("cleaned up");
}
