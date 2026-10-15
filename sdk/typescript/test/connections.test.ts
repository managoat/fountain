import { test } from "node:test";
import assert from "node:assert/strict";
import { Managoat, type McpConnection } from "../src/index.ts";
import { NotFoundError } from "../src/errors.ts";

const CONNECTION: McpConnection = {
  id: "cccccccc-1111-1111-1111-111111111111",
  url: "https://mcp.linear.app/mcp",
  resource: "https://mcp.linear.app/mcp",
  status: "pending",
  revoked_reason: null,
  issuer: "https://mcp.linear.app",
  registration: "client_id_metadata_document",
  client_id: "https://managoat.example/connections/client.json",
  scopes: ["read", "write"],
  expires_at: null,
  last_refreshed_at: null,
  created_at: "2026-10-15T00:00:00Z",
  updated_at: "2026-10-15T00:00:00Z",
};

type Seen = { method: string; path: string; body: unknown };

function client(seen: Seen[]): Managoat {
  const fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    seen.push({ method, path: url.pathname, body });
    const json = (status: number, payload: unknown) =>
      new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });

    if (method === "GET" && url.pathname === "/api/connections") return json(200, { data: [CONNECTION] });
    if (method === "POST" && url.pathname === "/api/connections")
      return json(201, { connection: CONNECTION, authorize_url: "https://mcp.linear.app/authorize?x=1" });
    if (method === "GET" && url.pathname === `/api/connections/${CONNECTION.id}`) return json(200, CONNECTION);
    if (method === "POST" && url.pathname === `/api/connections/${CONNECTION.id}/authorize`)
      return json(200, { connection: CONNECTION, authorize_url: "https://mcp.linear.app/authorize?x=2" });
    if (method === "DELETE" && url.pathname === `/api/connections/${CONNECTION.id}`) return new Response(null, { status: 204 });
    return json(404, { error: "not_found" });
  };

  return new Managoat({ baseUrl: "https://managoat.example", apiKey: "fk_test", fetch });
}

test("connections: create, list, get, reconnect, delete", async () => {
  const seen: Seen[] = [];
  const m = client(seen);

  const login = await m.connections.create({ url: "https://mcp.linear.app/mcp" });
  assert.equal(login.connection.id, CONNECTION.id);
  assert.match(login.authorize_url, /authorize\?x=1$/);
  assert.deepEqual(seen.at(-1), { method: "POST", path: "/api/connections", body: { url: "https://mcp.linear.app/mcp" } });

  assert.deepEqual((await m.connections.list()).map((c) => c.id), [CONNECTION.id]);
  assert.equal((await m.connections.get(CONNECTION.id)).status, "pending");
  assert.match((await m.connections.reconnect(CONNECTION.id)).authorize_url, /x=2$/);
  await m.connections.delete(CONNECTION.id);
  assert.equal(seen.at(-1)?.method, "DELETE");

  await assert.rejects(m.connections.get("nope"), NotFoundError);
});
