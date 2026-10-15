/**
 * The SDK tutorial, complete: a chat in your terminal with one agent, on one
 * conversation that lasts. The first line you type opens the conversation;
 * every line after it is a follow-up on the same sandbox.
 *
 *   MANAGOAT_BASE_URL=https://fountain.example.com
 *   MANAGOAT_API_KEY=...   # Account → API keys, or `managoat auth login`
 *
 *   node chat.ts
 *
 * Type /quit, or press Ctrl-D, to end the chat and take the sandbox down.
 *
 * Walkthrough: https://managoat.com/docs/tutorials/first-app
 *
 * (Inside this repository the import below resolves to the SDK itself, so run
 * `npm run build` in sdk/typescript first. Installed from npm it just works.)
 */
import { createInterface } from "node:readline";
import { Managoat, type Run } from "@managoat/sdk";

const managoat = new Managoat();
const agent = process.env.FOUNTAIN_AGENT ?? "starter";

const me = await managoat.me();
console.log(`Signed in to ${managoat.config.baseUrl} as ${me.email}. Type /quit to leave.`);

// Print a turn's words as they arrive. Say how it ended, if it did not finish.
async function show(run: Run) {
  process.stdout.write("agent> ");
  for await (const chunk of run.textStream) process.stdout.write(chunk);
  process.stdout.write("\n");

  const result = await run;
  if (result.state !== "done") console.log(`(${result.state}: ${result.reason ?? "no reason given"})`);
  return result;
}

const terminal = createInterface({ input: process.stdin, output: process.stdout, prompt: "\nyou> " });
let conversationId: string | null = null;

try {
  terminal.prompt();
  for await (const line of terminal) {
    const prompt = line.trim();
    if (prompt === "/quit") break;

    if (prompt !== "") {
      if (conversationId === null) {
        const result = await show(managoat.run(prompt, { agent }));
        conversationId = result.conversationId;
      } else {
        await show(managoat.resume(conversationId).send(prompt));
      }
    }
    terminal.prompt();
  }
} finally {
  terminal.close();
  if (conversationId !== null) await managoat.resume(conversationId).terminate();
}
