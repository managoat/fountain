import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { parseSse, streamEvents } from '../lib/sse.mjs';
import { Fixtures } from '../lib/fixtures.mjs';
import { configFrom } from '../lib/runner.mjs';
import { history } from '../lib/execution.mjs';
import { createServer } from 'node:http';
import { Redactor } from '../lib/http.mjs';

function bytes(parts) {
  return new ReadableStream({ start(controller) { for (const p of parts) controller.enqueue(typeof p === 'string' ? new TextEncoder().encode(p) : p); controller.close(); } });
}
async function collect(stream) { const all = []; for await (const item of stream) all.push(item); return all; }

test('SSE parser handles UTF-8 fragmentation, comments, multiline data and split CRLF', async () => {
  const wire = Buffer.from(': heartbeat\r\nid: 12\r\nevent: output\r\ndata: α\r\ndata: beta\r\n\r\n');
  const frames = await collect(parseSse(bytes([...wire].map(n => Uint8Array.of(n)))));
  assert.equal(frames.length, 1);
  assert.equal(frames[0].id, '12');
  assert.equal(frames[0].data, 'α\nbeta');
  assert.equal((await collect(parseSse(bytes(['data: ok\r\r']))))[0].data, 'ok');
});

test('SSE parser fails truncated data and bounded oversized streams', async () => {
  await assert.rejects(collect(parseSse(bytes(['id: 1\ndata: unfinished']))), /mid-frame/);
  await assert.rejects(collect(parseSse(bytes(['data: too much\n\n']), { maxBytes: 4 })), /byte budget/);
});

test('breaking an SSE consumer closes its real HTTP connection', async t => {
  let closed;
  const disconnected = new Promise(resolve => { closed = resolve; });
  const server = createServer((req, res) => {
    req.on('close', closed);
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('id: 1\nevent: output\ndata: {"kind":"output","data":"hi"}\n\n');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const client = { baseUrl: `http://127.0.0.1:${server.address().port}`, key: randomUUID(), redactor: new Redactor(), trace() {} };
  for await (const { event } of streamEvents(client, `/api/conversations/${randomUUID()}/stream`, { signal: AbortSignal.timeout(1000) })) {
    assert.equal(event.id, 1); break;
  }
  await Promise.race([disconnected, new Promise((_, reject) => setTimeout(() => reject(new Error('SSE connection leaked')), 1500).unref())]);
});

test('SSE reconnect sends the cursor header and wait=false drains to connection end', async t => {
  const headers = [];
  const server = createServer((req, res) => {
    headers.push(req.headers['last-event-id']);
    assert.ok(req.url.endsWith('wait=false'));
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const id of req.headers['last-event-id'] ? [41] : [12, 41]) {
      res.write(`id: ${id}\nevent: output\ndata: {"kind":"output","data":"ok"}\n\n`);
    }
    res.end();
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const client = { baseUrl: `http://127.0.0.1:${server.address().port}`, key: randomUUID(), redactor: new Redactor(), trace() {} };
  const path = `/api/conversations/${randomUUID()}/stream?wait=false`;
  assert.deepEqual((await collect(streamEvents(client, path, { signal: AbortSignal.timeout(1000) }))).map(f => f.event.id), [12, 41]);
  assert.deepEqual((await collect(streamEvents(client, path, { after: 12, signal: AbortSignal.timeout(1000) }))).map(f => f.event.id), [41]);
  assert.deepEqual(headers, [undefined, '12']);
});

function fixtures(t, request) {
  const dir = mkdtempSync(join(tmpdir(), 'fountain-execution-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const path = join(dir, 'cleanup.json');
  const f = new Fixtures(path, { request, baseUrl: 'https://example.test' }, { runId: randomUUID(), ownerId: randomUUID(), baseUrl: 'https://example.test' });
  const agent = { kind: 'agent', id: randomUUID(), name: `suite-${f.manifest.run_id}-agent-0`, state: 'created' };
  const environment = { kind: 'environment', id: randomUUID(), name: `suite-${f.manifest.run_id}-environment-1`, state: 'created' };
  f.manifest.resources.push(agent, environment); f.save();
  return { f, agent, environment, path, dir };
}

test('conversation creation cannot attach to existing resources or invoke unbudgeted inference', async t => {
  const { f, agent, environment } = fixtures(t, () => { throw new Error('Must not make a request'); });
  await assert.rejects(f.create('conversation', { agent_id: randomUUID(), environment_id: environment.id }), /run-owned/);
  await assert.rejects(f.create('conversation', { agent_id: agent.id, environment_id: environment.id, prompt: 'unbudgeted' }), /without inference/);
  assert.equal(f.manifest.resources.length, 2);
});

test('turn budget is durable before a prompt can be sent and cannot exceed two attempts', async t => {
  const { f, agent, environment, path } = fixtures(t, () => {});
  const id = randomUUID();
  f.manifest.resources.push({ kind: 'conversation', id, name: `suite-${f.manifest.run_id}-conversation-2`, agent_id: agent.id, environment_id: environment.id, state: 'created' });
  f.reserveTurn(id, 2); f.reserveTurn(id, 2);
  assert.equal(JSON.parse(readFileSync(path)).inference_attempts, 2);
  assert.throws(() => f.reserveTurn(id, 2), /budget exhausted/);
  assert.throws(() => f.reserveTurn(randomUUID(), 2), /recorded conversation/);
});

test('conversation cleanup verifies termination before deleting transcript and parent fixtures', async t => {
  const requests = [];
  let f, agent, environment, conversation, terminated = false;
  const setup = fixtures(t, async (method, path) => {
    requests.push([method, path]);
    if (path.endsWith('/terminate')) { terminated = true; return { status: 204 }; }
    if (path === `/api/conversations/${conversation.id}` && method === 'GET') return { status: 200, body: { data: { ...conversation, channel_id: conversation.name, status: terminated ? 'terminated' : 'idle', sandbox: { mode: 'ephemeral' } } } };
    if (path === `/api/sandboxes/${conversation.sandbox_id}`) return { status: 200, body: { data: { status: terminated ? 'terminated' : 'ready', agent_id: agent.id } } };
    if (method === 'GET') return { status: 200, body: { data: path.includes('agents') ? agent : environment } };
    return { status: 204 };
  });
  ({ f, agent, environment } = setup);
  conversation = { kind: 'conversation', id: randomUUID(), name: `suite-${f.manifest.run_id}-conversation-2`, agent_id: agent.id, environment_id: environment.id, sandbox_id: randomUUID(), state: 'created' };
  f.manifest.resources.push(conversation); f.save();
  assert.deepEqual(await f.cleanup(AbortSignal.timeout(1000)), []);
  const terminatedAt = requests.findIndex(([, p]) => p.endsWith('/terminate'));
  const deletedAt = requests.findIndex(([method, p]) => method === 'DELETE' && p.includes('conversations'));
  assert.ok(terminatedAt >= 0 && deletedAt > terminatedAt);
  assert.equal(requests.filter(([m]) => m === 'DELETE').length, 3);
});

test('a live leaked sandbox retains the conversation and its ownership fixtures', async t => {
  let f, agent, environment, conversation;
  const deleted = [];
  ({ f, agent, environment } = fixtures(t, async (method, path) => {
    if (method === 'DELETE') deleted.push(path);
    if (path.endsWith('/terminate')) return { status: 204 };
    if (path.includes('/sandboxes/')) return { status: 200, body: { data: { status: 'ready', agent_id: agent.id } } };
    return { status: 200, body: { data: { ...conversation, channel_id: conversation.name, status: 'terminated', sandbox: { mode: 'ephemeral' } } } };
  }));
  conversation = { kind: 'conversation', id: randomUUID(), name: `suite-${f.manifest.run_id}-conversation-2`, agent_id: agent.id, environment_id: environment.id, sandbox_id: randomUUID(), state: 'created' };
  f.manifest.resources.push(conversation); f.save();
  assert.equal((await f.cleanup(AbortSignal.timeout(1000))).length, 3);
  assert.deepEqual(deleted, []);
  assert.equal(conversation.state, 'created');
});

test('history enforces cursor progress without assuming consecutive global IDs', async () => {
  let n = 0;
  const client = { request: async () => ({ body: n++ === 0 ? { data: [{ id: 2 }, { id: 17 }], meta: { has_more: true, next_cursor: 17 } } : { data: [{ id: 91 }], meta: { has_more: false, next_cursor: 91 } } }) };
  assert.deepEqual((await history(client, randomUUID(), undefined, 2)).events.map(e => e.id), [2, 17, 91]);
  await assert.rejects(history({ request: async () => ({ body: { data: [], meta: { has_more: true, next_cursor: null } } }) }, randomUUID()), /stuck/);
});

test('history budgets events rather than pages, so small pages read a long transcript', async () => {
  const pages = (total, size) => {
    let served = 0;
    return { request: async (_method, path) => {
      const limit = Number(new URL(path, 'https://x.test').searchParams.get('limit'));
      assert.equal(limit, size);
      const data = Array.from({ length: Math.min(limit, total - served) }, (_, i) => ({ id: served + i + 1 }));
      served += data.length;
      return { body: { data, meta: { has_more: served < total, next_cursor: served } } };
    } };
  };
  const long = await history(pages(570, 3), randomUUID(), undefined, 3);
  assert.equal(long.events.length, 570);
  assert.equal(long.pages, 190);
  await assert.rejects(history(pages(31, 3), randomUUID(), undefined, 3, 30), /30-event budget/);
});

test('execution requires an explicit two-turn authorization and both credentials', t => {
  const { dir } = fixtures(t, () => {});
  const path = join(dir, 'config.json');
  const cfg = { base_url: 'https://example.test', profiles: ['execution'], credentials: { primary: 'TEST_KEY', secondary: 'OTHER_KEY' }, execution: { runtime: 'claude', model: 'anthropic/claude-haiku-4-5', sandbox_provider: 'sprites' } };
  const env = { TEST_KEY: randomUUID(), OTHER_KEY: randomUUID() };
  writeFileSync(path, JSON.stringify(cfg));
  assert.throws(() => configFrom(path, env), /max_turns/);
  cfg.execution.max_turns = 2; writeFileSync(path, JSON.stringify(cfg));
  assert.equal(configFrom(path, env).execution.max_turns, 2);
  assert.throws(() => configFrom(path, { TEST_KEY: env.TEST_KEY }), /Missing test credential/);
});

test('persistent cleanup preserves the home for lifecycle assertions, then resets only its recorded owner', async t => {
  const calls = [];
  let f, agent, environment, conv, terminated = false, reset = false;
  ({ f, agent, environment } = fixtures(t, async (method, path) => {
    calls.push([method, path]);
    if (path.endsWith('/terminate')) { terminated = true; return { status: 204 }; }
    if (path === `/api/sandboxes/${conv.sandbox_id}`) {
      if (method === 'DELETE') { reset = true; return { status: 204 }; }
      return { status: 200, body: { data: { mode: 'persistent', status: reset ? 'terminated' : 'ready', agent_id: agent.id, environment_id: environment.id } } };
    }
    if (method === 'GET' && path.includes('/conversations/')) return { status: 200, body: { data: { ...conv, channel_id: conv.name, status: terminated ? 'terminated' : 'idle', sandbox: { mode: 'persistent' } } } };
    if (method === 'GET') return { status: 200, body: { data: path.includes('agents') ? agent : environment } };
    return { status: 204 };
  }));
  conv = { kind: 'conversation', id: randomUUID(), name: `suite-${f.manifest.run_id}-conversation-2`, agent_id: agent.id, environment_id: environment.id, sandbox_id: randomUUID(), sandbox_mode: 'persistent', state: 'created' };
  f.manifest.resources.push(conv); f.save();
  await f.terminateConversation(conv, { ...conv, channel_id: conv.name, sandbox: { mode: 'persistent' } }, AbortSignal.timeout(1000), { preserveHome: true });
  assert.equal(terminated, true); assert.equal(reset, false);
  assert.deepEqual(await f.cleanup(AbortSignal.timeout(1000)), []);
  assert.equal(reset, true);
  const deletes = calls.filter(([method]) => method === 'DELETE').map(([, path]) => path);
  assert.deepEqual(deletes, [`/api/sandboxes/${conv.sandbox_id}`, `/api/conversations/${conv.id}`, `/api/environments/${environment.id}`, `/api/agents/${agent.id}`]);
});

test('persistent cleanup refuses changed ownership and retains parents and cleanup intent', async t => {
  let f, agent, environment, conv;
  const deletes = [];
  ({ f, agent, environment } = fixtures(t, async (method, path) => {
    if (method === 'DELETE') deletes.push(path);
    if (path.endsWith('/terminate')) return { status: 204 };
    if (path.includes('/sandboxes/')) return { status: 200, body: { data: { mode: 'persistent', status: 'ready', agent_id: agent.id, environment_id: randomUUID() } } };
    return { status: 200, body: { data: { ...conv, channel_id: conv.name, status: 'terminated', sandbox: { mode: 'persistent' } } } };
  }));
  conv = { kind: 'conversation', id: randomUUID(), name: `suite-${f.manifest.run_id}-conversation-2`, agent_id: agent.id, environment_id: environment.id, sandbox_id: randomUUID(), sandbox_mode: 'persistent', state: 'created' };
  f.manifest.resources.push(conv); f.save();
  assert.equal((await f.cleanup(AbortSignal.timeout(1000))).length, 3);
  assert.deepEqual(deletes, []);
});

test('legacy ephemeral manifests cannot opt themselves into resetting an existing home', async t => {
  const { f, agent, environment } = fixtures(t, async () => { throw new Error('Must refuse before public mutation'); });
  const conv = { agent_id: agent.id, environment_id: environment.id, name: 'run-owned' };
  await assert.rejects(f.terminateConversation(conv, { ...conv, channel_id: conv.name, sandbox: { mode: 'persistent' } }, AbortSignal.timeout(1000)), /unrecorded mode/);
});
