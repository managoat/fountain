import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Fountain } from "../../typescript/dist/index.js";

const fixture = JSON.parse(readFileSync(new URL("./fixture.json", import.meta.url), "utf8"));
const client = new Fountain({ baseUrl: process.env.FOUNTAIN_BASE_URL, apiKey: "fixture" });
await assert.rejects(async () => client.runRequest(fixture.request, { timeoutMs: 5000, collectEvents: true }),
  (error) => error.status === 422 && error.code === "fixture_stop");
assert.deepEqual(await client.request("GET", "/api/conversations/c1"), { data: fixture.response });
