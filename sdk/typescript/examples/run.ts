/**
 * The whole SDK in ten lines.
 *
 *   MANAGOAT_API_KEY=... node examples/run.ts "<agent>" "<prompt>"
 */
import { Managoat } from "../src/index.ts";

const [agent = "smoke-runner", prompt = "Reply with the kernel name and nothing else."] =
  process.argv.slice(2);

const managoat = new Managoat();
const run = await managoat.run(prompt, { agent });

console.log(run.text);
console.log(`\n${run.state} · ${run.toolsUsed.join(", ") || "no tools"} · ${run.url}`);
