#!/usr/bin/env node
// Pack the built SDK, then typecheck and run a consumer outside the checkout.
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const sdk = join(dirname(fileURLToPath(import.meta.url)), "..");
const { name } = JSON.parse(readFileSync(join(sdk, "package.json"), "utf8"));
const temporary = mkdtempSync(join(tmpdir(), "fountain-package-"));
try {
  const packed = JSON.parse(execFileSync("npm", ["pack", "--json", "--offline", "--ignore-scripts",
    "--pack-destination", temporary], { cwd: sdk, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }));
  if (packed.length !== 1 || !packed[0].filename) throw new Error("Expected one SDK tarball");
  const consumer = join(temporary, "consumer");
  mkdirSync(consumer);
  writeFileSync(join(consumer, "package.json"), JSON.stringify({ private: true, type: "module" }));
  // The SDK promises no runtime dependencies; the local tarball is sufficient.
  execFileSync("npm", ["install", "--offline", "--ignore-scripts", "--no-audit", "--no-fund",
    "--package-lock=false", "--no-save", join(temporary, packed[0].filename)],
    { cwd: consumer, stdio: "inherit" });
  writeFileSync(join(consumer, "consumer.ts"), `
import Managoat, { type Agent } from ${JSON.stringify(name)};
import BrowserFountain from ${JSON.stringify(name + "/browser")};

async function verify(Client: typeof Managoat) {
  let calls = 0;
  const client = new Client({
    baseUrl: "https://package.invalid", apiKey: "package-test",
    fetch: async (input, init) => {
      const request = new Request(input, init);
      if (request.url !== "https://package.invalid/api/agents" || request.method !== "GET"
          || request.headers.get("authorization") !== "Bearer package-test") {
        throw new Error("The installed SDK made an unexpected request");
      }
      calls++;
      return new Response(JSON.stringify({ data: [] }), { headers: { "content-type": "application/json" } });
    },
  });
  const agents: Agent[] = await client.agents.list();
  if (calls !== 1 || agents.length !== 0) throw new Error("The installed SDK returned an unexpected collection");
}
await verify(Managoat);
await verify(BrowserFountain);
`);
  // No project paths alias or skipLibCheck: resolve the published declarations.
  execFileSync(process.execPath, [join(sdk, "node_modules/typescript/lib/tsc.js"), "--strict",
    "--target", "ES2022", "--lib", "ES2022,DOM", "--module", "NodeNext",
    "--moduleResolution", "NodeNext", "consumer.ts"], { cwd: consumer, stdio: "inherit" });
  execFileSync(process.execPath, ["consumer.js"], { cwd: consumer, stdio: "inherit" });
  execFileSync("npx", ["--yes", "esbuild", "consumer.ts", "--bundle", "--platform=browser",
    "--format=esm", "--outfile=consumer.bundle.js"], { cwd: consumer, stdio: "inherit" });
  console.log("Packed SDK declarations, entry points and browser bundle passed consumer checks.");
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
