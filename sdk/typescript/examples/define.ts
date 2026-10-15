/**
 * Define an environment, a vault and an agent — then run the thing you just
 * defined. Deletes all three on the way out.
 *
 *   MANAGOAT_API_KEY=... node examples/define.ts
 */
import { Managoat } from "../src/index.ts";

const managoat = new Managoat();
const suffix = process.argv[2] ?? "demo";
const names = {
  environment: `sdk-${suffix}-env`,
  vault: `sdk-${suffix}-vault`,
  agent: `sdk-${suffix}-agent`,
};

let conversationId: string | null = null;

try {
  const environment = await managoat.environments.create({
    name: names.environment,
    env_vars: { GREETING: "hello from the environment" },
  });

  await managoat.vaults.create({ name: names.vault });
  // A vault value is decrypted into the sandbox at spawn. It is never in the
  // prompt, so the agent can use it without the model ever seeing it.
  await managoat.vaults.secrets.set(names.vault, "DEMO_TOKEN", "s3cr3t-abc123");

  const agent = await managoat.agents.create({
    name: names.agent,
    runtime: "claude",
    model: "anthropic/claude-haiku-4-5",
    description: "Created by the Managoat SDK's define example",
    system: "You answer in one short line.",
    environment_id: environment.id,
    allowed_vault_ids: [(await managoat.vaults.get(names.vault)).id],
  });

  console.log(`defined ${agent.name} (${agent.runtime}, ${agent.model})`);

  // Deliberately ask it to print the secret. Managoat redacts any value of 8
  // bytes or more that it placed in the sandbox's environment, on the single
  // write path every log event goes through — so the plaintext never reaches
  // Postgres or this stream, however the agent was asked.
  const run = await managoat.run(
    "Print $GREETING and $DEMO_TOKEN, then say how many characters $DEMO_TOKEN has.",
    { agent: names.agent, vault: names.vault },
  );
  conversationId = run.conversationId;

  console.log(run.text);
  console.log("\n^ the values come back [REDACTED]; the character count proves they arrived");
  console.log(`${run.state} · ${run.url}`);
} finally {
  if (conversationId) await managoat.resume(conversationId).terminate().catch(() => {});
  await managoat.agents.delete(names.agent).catch(() => {});
  await managoat.vaults.delete(names.vault).catch(() => {});
  await managoat.environments.delete(names.environment).catch(() => {});
  console.log("cleaned up");
}
