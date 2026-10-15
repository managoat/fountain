/**
 * Sit in front of an agent and approve its tool calls one at a time.
 *
 * The agent needs an `ask` entry in its `permission_policy` — the default is
 * `auto_allow`, which never asks. `execute` is the one worth holding, because
 * it is the kind that runs commands:
 *
 *   await managoat.agents.update("<agent>", {
 *     permission_policy: { execute: "ask", default: "auto_allow" },
 *   });
 *
 *   MANAGOAT_API_KEY=... node examples/permissions.ts "<agent>"
 *
 * Answer promptly. A request that expires is denied, and the turn carries on
 * without that step — so ignoring these is not the same as allowing them.
 */
import { Managoat } from "../src/index.ts";

const agent = process.argv[2] ?? "smoke-runner";
const managoat = new Managoat();

const run = managoat.run("Count the lines of TypeScript in this repo.", { agent });

console.log(`watch: ${await run.url}\n`);

for await (const event of run) {
  if (event.type === "text") process.stdout.write(event.text);
  if (event.type !== "permission") continue;

  const { requestId, summary, toolName, options } = event.request;
  console.log(`\n? ${summary ?? toolName ?? "the agent wants to run a tool"}`);
  console.log(`  ${options.map((o) => `${o.optionId} (${o.kind})`).join("  ")}`);

  // Approve reads, refuse anything else. A real caller would ask a person —
  // and would have the whole `options` list to offer them, in the agent's own
  // order, rather than assuming two choices.
  const wanted = /^(ls|cat|rg|grep|wc|find)\b/.test(summary ?? "") ? "allow_once" : "reject_once";
  const choice = options.find((o) => o.kind === wanted) ?? options[0];
  if (!choice) continue;

  console.log(`> ${choice.optionId}`);
  await run.answer(requestId, choice.optionId);
}

const result = await run;
console.log(`\n· ${result.state}`);

await managoat.resume(result.conversationId).terminate();
