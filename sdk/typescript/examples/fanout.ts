/**
 * The same question to several agents at once. Each gets its own sandbox.
 *
 *   MANAGOAT_API_KEY=... node examples/fanout.ts "<prompt>" <agent> <agent> ...
 */
import { Managoat } from "../src/index.ts";

const [prompt = "In one sentence: what is this repository for?", ...agents] = process.argv.slice(2);
const roster = agents.length ? agents : ["smoke-runner"];

const managoat = new Managoat();

// Nothing is awaited yet, so all of them are provisioning at once.
const runs = roster.map((agent) => managoat.run(prompt, { agent, timeoutMs: 10 * 60_000 }));

const results = await Promise.allSettled(runs);

for (const [index, result] of results.entries()) {
  const agent = roster[index];
  if (result.status === "rejected") {
    console.log(`\n## ${agent}\n(failed: ${result.reason})`);
    continue;
  }
  console.log(`\n## ${agent}\n${result.value.text}\n→ ${result.value.url}`);
}

// Sandboxes are cheap but not free; hand them back.
await Promise.allSettled(
  runs.map(async (run) => managoat.resume(await run.conversationId).terminate()),
);
