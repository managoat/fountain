import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Client, Redactor } from '../lib/http.mjs';
import { Fixtures } from '../lib/fixtures.mjs';
import { inventoryFixtures, reconstructFixtures } from '../lib/fixture-recovery.mjs';

async function world(t) {
  const dir = mkdtempSync(join(tmpdir(), 'fixture-recovery-'));
  const ownerId = randomUUID(), runId = randomUUID();
  const collections = { environment: '/api/environments', vault: '/api/vaults', agent: '/api/agents', api_key: '/api/auth/api-keys', conversation: '/api/conversations', sandbox: '/api/sandboxes' };
  const rows = Object.fromEntries(Object.keys(collections).map(kind => [kind, []]));
  const mutations = [], requests = [];
  let schedules = [];
  const server = createServer(async (req, res) => {
    requests.push(`${req.method} ${req.url}`);
    const url = new URL(req.url, 'http://localhost');
    const send = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(body === undefined ? undefined : JSON.stringify(body)); };
    if (req.headers.authorization !== 'Bearer dedicated-test') return send(401, { error: 'unauthorized' });
    if (req.url === '/api/auth/me') return send(200, { id: ownerId, email_verified: true });
    if (req.url.match(/^\/api\/team\/.+\/schedules$/)) return send(200, { data: schedules });
    const kind = Object.keys(collections).find(k => url.pathname === collections[k] || url.pathname.startsWith(collections[k] + '/'));
    if (!kind) return send(404, { error: 'unknown' });
    const id = url.pathname.slice(collections[kind].length + 1).split('/')[0];
    const row = rows[kind].find(r => r.id === id);
    if (req.method !== 'GET') mutations.push(`${req.method} ${req.url}`);
    if (req.method === 'GET') {
      if (!id) return send(200, { data: rows[kind] });
      return send(row ? 200 : 404, row ? { data: row } : { error: 'not_found' });
    }
    if (req.method === 'POST' && url.pathname.endsWith('/terminate')) {
      if (row) {
        row.status = 'terminated';
        const sandbox = rows.sandbox.find(s => s.id === row.sandbox_id);
        if (sandbox?.mode === 'ephemeral') sandbox.status = 'terminated';
      }
      return send(row ? 204 : 404);
    }
    if (req.method === 'DELETE') {
      if (kind === 'sandbox' && row) row.status = 'terminated';
      else if (row) rows[kind].splice(rows[kind].indexOf(row), 1);
      for (const sandbox of rows.sandbox) sandbox.conversations = sandbox.conversations.filter(c => c.id !== id);
      return send(row ? 204 : 404);
    }
    return send(405);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); rmSync(dir, { recursive: true, force: true }); });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const client = new Client({ baseUrl, key: 'dedicated-test', redactor: new Redactor(), trace: () => {} });
  const evidence = { version: 1, base_url: baseUrl, owner_id: ownerId, run_id: runId, profiles: ['execution'],
    ownership_evidence: 'Operator correlated the exact run UUID with the dedicated account and launch record.',
    writers_stopped: 'Original runner is dead and automatic retry is disabled. Every submitted create is listed.',
    intent_inventory: 'Suite revision and interruption checkpoint establish these exact submitted create intents.', resources: [] };
  function add(kind, attrs = {}) {
    const r = { kind, name: `suite-${runId}-${kind}-${evidence.resources.length}`, id: randomUUID() };
    evidence.resources.push(r);
    rows[kind].push({ id: r.id, [kind === 'conversation' ? 'channel_id' : 'name']: r.name, ...attrs });
    return r;
  }
  function conversation(mode = 'ephemeral') {
    const environment = add('environment'), agent = add('agent', { environment_id: environment.id });
    const sandbox = { id: randomUUID(), agent_id: agent.id, environment_id: environment.id, vault_id: null, mode, status: 'ready', conversations: [] };
    const conv = add('conversation', { agent_id: agent.id, environment_id: environment.id, vault_id: null,
      sandbox_id: sandbox.id, sandbox, status: 'running', parent_conversation_id: null });
    Object.assign(conv, { agent_id: agent.id, environment_id: environment.id, vault_id: null, sandbox_id: sandbox.id, sandbox_mode: mode });
    sandbox.conversations.push({ id: conv.id }); rows.sandbox.push(sandbox);
    return { environment, agent, conv, sandbox };
  }
  const manifestPath = join(dir, 'cleanup.json');
  return { dir, ownerId, runId, client, evidence, rows, mutations, requests, add, conversation, manifestPath,
    schedule: value => { schedules = value; },
    reconstruct: () => reconstructFixtures(client, evidence, manifestPath),
    load: () => Fixtures.load(manifestPath, client, ownerId) };
}

test('lost journal and create response recover exact names, stop execution, keep ordering and repeat safely', async t => {
  const w = await world(t);
  const { conv, sandbox } = w.conversation();
  delete conv.id; conv.sandbox_id = null; // The create committed, but neither response nor journal survived.
  const manifest = await w.reconstruct();
  assert.equal(w.mutations.length, 0, 'reconstruction is read-only');
  assert.equal(manifest.resources.at(-1).id, w.rows.conversation[0].id);
  assert.equal(manifest.resources.at(-1).sandbox_id, sandbox.id);
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(sandbox.status, 'terminated');
  assert.match(w.mutations[0], /POST .*\/terminate$/);
  const deletedConversation = w.mutations.findIndex(p => p.startsWith('DELETE /api/conversations/'));
  const deletedAgent = w.mutations.findIndex(p => p.startsWith('DELETE /api/agents/'));
  assert.ok(deletedConversation > 0 && deletedAgent > deletedConversation);
  const count = w.mutations.length;
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(w.mutations.length, count, 'repeat pass has no mutations');
  assert.equal(w.load().remainingCount(), 0);
});

test('empty inventory is not proof an unknown create cannot commit later', async t => {
  const w = await world(t);
  const r = w.add('environment'); const row = w.rows.environment.pop(); delete r.id;
  await w.reconstruct();
  const failed = await w.load().cleanup(AbortSignal.timeout(5000));
  assert.match(failed[0].error, /Unresolved create intent/);
  assert.equal(w.load().remainingCount(), 1);
  assert.equal(w.mutations.length, 0);
  w.rows.environment.push(row); // Commit becomes visible only after the failed recovery.
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(w.load().remainingCount(), 0);
});

for (const scenario of ['owner', 'target', 'prefix', 'duplicate', 'parent', 'mode', 'sandbox', 'notes', 'profile']) {
  test(`refuses ${scenario} mismatch before writing an executable journal or mutating`, async t => {
    const w = await world(t); const { conv } = w.conversation();
    if (scenario === 'owner') w.evidence.owner_id = randomUUID();
    if (scenario === 'target') w.evidence.base_url = 'https://another.example';
    if (scenario === 'prefix') w.evidence.resources[0].name = 'suite-';
    if (scenario === 'duplicate') w.rows.environment.push({ ...w.rows.environment[0], id: randomUUID() });
    if (scenario === 'parent') conv.agent_id = randomUUID();
    if (scenario === 'mode') conv.sandbox_mode = 'persistent';
    if (scenario === 'sandbox') conv.sandbox_id = randomUUID();
    if (scenario === 'notes') w.evidence.intent_inventory = '';
    if (scenario === 'profile') w.evidence.profiles = ['schedules'];
    await assert.rejects(w.reconstruct());
    assert.equal(existsSync(w.manifestPath), false);
    assert.equal(w.mutations.length, 0);
  });
}

for (const scenario of ['conversation', 'sandbox', 'cotenant', 'schedule', 'changed-parent', 'new-fixture', 'foreign-agent']) {
  test(`rechecks ${scenario} arriving after reconstruction and retains all parent evidence`, async t => {
    const w = await world(t); const { agent, sandbox } = w.conversation();
    await w.reconstruct();
    if (scenario === 'conversation') w.rows.conversation.push({ id: randomUUID(), agent_id: agent.id, channel_id: 'foreign' });
    if (scenario === 'sandbox') w.rows.sandbox.push({ ...sandbox, id: randomUUID(), conversations: [] });
    if (scenario === 'cotenant') sandbox.conversations.push({ id: randomUUID() });
    if (scenario === 'schedule') w.schedule([{ id: randomUUID() }]);
    if (scenario === 'changed-parent') w.rows.agent[0].name = 'foreign';
    if (scenario === 'foreign-agent') w.rows.agent.push({ id: randomUUID(), name: 'foreign', environment_id: w.rows.environment[0].id });
    if (scenario === 'new-fixture') w.rows.vault.push({ id: randomUUID(), name: `suite-${w.runId}-vault-9` });
    const failures = await w.load().cleanup(AbortSignal.timeout(5000));
    assert.equal(failures[0].kind, 'recovery');
    assert.equal(w.mutations.length, 0);
    assert.equal(w.load().remainingCount(), 3);
  });
}

test('inventory is a non-executable candidate with only exact run names and no response secrets', async t => {
  const w = await world(t); w.conversation();
  w.rows.environment[0].env_vars = { secret: 'private-value' };
  w.rows.agent.push({ id: randomUUID(), name: `suite-${randomUUID()}-agent-1` });
  const candidate = await inventoryFixtures(w.client, { ownerId: w.ownerId, runId: w.runId });
  assert.equal(candidate.resources.length, 3);
  assert.equal(JSON.stringify(candidate).includes('private-value'), false);
  await assert.rejects(reconstructFixtures(w.client, candidate, w.manifestPath), /supports|Record/);
  assert.equal(w.mutations.length, 0);
});

test('persistent home reset is limited to the recorded parents and follows termination', async t => {
  const w = await world(t); const { sandbox } = w.conversation('persistent');
  await w.reconstruct();
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(sandbox.status, 'terminated');
  assert.ok(w.mutations.indexOf(`DELETE /api/sandboxes/${sandbox.id}`) > 0);
});

test('lost delete response tolerates an already absent agent on repeat', async t => {
  const w = await world(t); w.add('agent');
  await w.reconstruct();
  w.rows.agent.length = 0;
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(w.load().remainingCount(), 0);
});


test('a sandbox becoming live after a completed pass cannot yield a false repeat success', async t => {
  const w = await world(t); const { sandbox } = w.conversation();
  await w.reconstruct();
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  sandbox.status = 'ready';
  const count = w.mutations.length;
  const failures = await w.load().cleanup(AbortSignal.timeout(5000));
  assert.match(failures[0].error, /live sandbox/);
  assert.equal(w.mutations.length, count);
});

test('changing a null vault to another vault refuses conversation termination and retains parents', async t => {
  const w = await world(t); w.conversation();
  await w.reconstruct();
  w.rows.conversation[0].vault_id = randomUUID();
  const failures = await w.load().cleanup(AbortSignal.timeout(5000));
  assert.match(failures[0].error, /vault ownership/);
  assert.equal(w.mutations.length, 0);
  assert.equal(w.load().remainingCount(), 3);
});
