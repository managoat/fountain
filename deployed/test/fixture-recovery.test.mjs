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
  let buzzReply = { status: 200, body: { data: [] } };
  const queue = [], deleteFailures = new Set(), lostDeleteReplies = new Set();
  let queueReply;
  const server = createServer(async (req, res) => {
    requests.push(`${req.method} ${req.url}`);
    const url = new URL(req.url, 'http://localhost');
    const send = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(body === undefined ? undefined : JSON.stringify(body)); };
    if (req.headers.authorization !== 'Bearer dedicated-test') return send(401, { error: 'unauthorized' });
    if (req.url === '/api/buzz/agents') return send(buzzReply.status, buzzReply.body);
    if (req.url === '/api/sandbox-queue') return queueReply
      ? send(queueReply.status, queueReply.body)
      : send(200, { data: queue.filter(row => row.status === 'queued').map(({ attrs, ...row }) => row) });
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
      if (deleteFailures.delete(kind)) return send(503, { error: 'transient deletion failure' });
      if (kind === 'sandbox' && row) row.status = 'terminated';
      else if (row) rows[kind].splice(rows[kind].indexOf(row), 1);
      for (const sandbox of rows.sandbox) {
        sandbox.conversations = sandbox.conversations.filter(c => c.id !== id);
        if (['agent', 'environment', 'vault'].includes(kind) && sandbox[`${kind}_id`] === id) sandbox[`${kind}_id`] = null;
      }
      if (kind === 'agent') {
        for (let i = queue.length - 1; i >= 0; i--) if (queue[i].agent_id === id) queue.splice(i, 1);
      }
      if (lostDeleteReplies.delete(kind)) return send(503, { error: 'reply lost after committed deletion' });
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
    queue_account_settlement_evidence: 'Account-wide launch logs establish no accepted queue requests remain unsettled; all writers are stopped and all resulting resources are accounted for.',
    intent_inventory: 'Suite revision and interruption checkpoint establish these exact submitted create intents.', resources: [] };
  function add(kind, attrs = {}) {
    const r = { kind, name: `suite-${runId}-${kind}-${evidence.resources.length}`, id: randomUUID() };
    evidence.resources.push(r);
    rows[kind].push({ id: r.id, [kind === 'conversation' ? 'channel_id' : 'name']: r.name, ...attrs });
    return r;
  }
  function conversation(mode = 'ephemeral', withVault = false) {
    const environment = add('environment'), vault = withVault ? add('vault') : null;
    const agent = add('agent', { environment_id: environment.id });
    const sandbox = { id: randomUUID(), agent_id: agent.id, environment_id: environment.id, vault_id: vault?.id ?? null, mode, status: 'ready', conversations: [] };
    const conv = add('conversation', { agent_id: agent.id, environment_id: environment.id, vault_id: sandbox.vault_id,
      sandbox_id: sandbox.id, sandbox, status: 'running', parent_conversation_id: null });
    Object.assign(conv, { agent_id: agent.id, environment_id: environment.id, vault_id: sandbox.vault_id, sandbox_id: sandbox.id, sandbox_mode: mode });
    sandbox.conversations.push({ id: conv.id }); rows.sandbox.push(sandbox);
    return { environment, vault, agent, conv, sandbox };
  }
  const manifestPath = join(dir, 'cleanup.json');
  return { dir, ownerId, runId, client, evidence, rows, mutations, requests, add, conversation, manifestPath, queue,
    schedule: value => { schedules = value; },
    buzz: (body, status = 200) => { buzzReply = { body, status }; },
    queueResponse: (body, status = 200) => { queueReply = { body, status }; },
    failDelete: kind => deleteFailures.add(kind),
    loseDeleteReply: kind => lostDeleteReplies.add(kind),
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

for (const kind of ['environment', 'vault']) {
  for (const phase of ['reconstruction', 'replay']) {
    test(`refuses an unrecorded agent's ${kind} allowlist during ${phase}`, async t => {
      const w = await world(t);
      const source = w.add(kind);
      if (phase === 'replay') await w.reconstruct();
      const foreign = { id: randomUUID(), name: 'unrecorded-agent', environment_id: null,
        allowed_environment_ids: [], allowed_vault_ids: [], [`allowed_${kind}_ids`]: [source.id] };
      w.rows.agent.push(foreign);
      if (phase === 'reconstruction') {
        await assert.rejects(w.reconstruct(), /Unrecorded agent/);
        assert.equal(existsSync(w.manifestPath), false);
      } else {
        const failures = await w.load().cleanup(AbortSignal.timeout(5000));
        assert.match(failures[0]?.error, /Unrecorded agent/);
        assert.equal(w.load().remainingCount(), 1, 'retain the source cleanup intent');
      }
      assert.deepEqual(w.mutations, [], 'refuse before source deletion could version another agent');
      assert.equal(w.rows[kind][0].id, source.id, 'retain the source fixture');
      assert.deepEqual(foreign[`allowed_${kind}_ids`], [source.id]);
    });
  }
}

for (const phase of ['reconstruction', 'replay']) {
  test(`refuses a child on different resources during ${phase} and retains its parent`, async t => {
    const w = await world(t);
    const { conv } = w.conversation();
    if (phase === 'replay') await w.reconstruct();
    const environment = { id: randomUUID(), name: 'child-environment' };
    const vault = { id: randomUUID(), name: 'child-vault' };
    const agent = { id: randomUUID(), name: 'child-agent', environment_id: environment.id };
    const child = { id: randomUUID(), channel_id: 'unrecorded-child', parent_conversation_id: conv.id,
      agent_id: agent.id, environment_id: environment.id, vault_id: vault.id, status: 'running' };
    const sandbox = { id: randomUUID(), agent_id: agent.id, environment_id: environment.id,
      vault_id: vault.id, mode: 'ephemeral', status: 'ready', conversations: [{ id: child.id }] };
    Object.assign(child, { sandbox_id: sandbox.id, sandbox });
    w.rows.environment.push(environment); w.rows.vault.push(vault); w.rows.agent.push(agent);
    w.rows.conversation.push(child); w.rows.sandbox.push(sandbox);
    if (phase === 'reconstruction') {
      await assert.rejects(w.reconstruct(), /Unrecorded conversation/);
      assert.equal(existsSync(w.manifestPath), false);
    } else {
      const failures = await w.load().cleanup(AbortSignal.timeout(5000));
      assert.match(failures[0]?.error, /Unrecorded conversation/);
      assert.equal(w.load().remainingCount(), 3, 'retain every parent cleanup intent');
    }
    assert.deepEqual(w.mutations, [], 'do not terminate or delete the recovered parent');
    assert.ok(w.rows.conversation.some(row => row.id === conv.id));
    assert.equal(w.rows.conversation.find(row => row.id === conv.id).status, 'running');
    assert.equal(child.status, 'running', 'escalate the child instead of implicitly adopting it');
    assert.equal(sandbox.status, 'ready');
  });
}

test('null, empty and unrelated allowlists do not prevent cleanup of independent fixtures', async t => {
  const w = await world(t);
  w.add('environment'); w.add('vault');
  for (const allowed of [null, [], [randomUUID()]]) {
    w.rows.agent.push({ id: randomUUID(), name: 'unrelated-agent', environment_id: null,
      allowed_environment_ids: allowed, allowed_vault_ids: allowed });
  }
  await w.reconstruct();
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(w.load().remainingCount(), 0);
  assert.equal(w.rows.agent.length, 3);
  assert.equal(w.mutations.length, 2);
  assert.ok(w.mutations.every(request => /^DELETE \/api\/(environments|vaults)\//.test(request)));
});

test('allowlists on an exactly recorded agent permit cleanup of its recorded sources', async t => {
  const w = await world(t);
  const environment = w.add('environment'), vault = w.add('vault');
  w.add('agent', { environment_id: null, allowed_environment_ids: [environment.id], allowed_vault_ids: [vault.id] });
  await w.reconstruct();
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(w.load().remainingCount(), 0);
  assert.equal(w.rows.agent.length, 0);
  assert.equal(w.rows.environment.length + w.rows.vault.length, 0);
});

test('a recorded pending agent is reconciled before dependent refusal and replay remains idempotent', async t => {
  const w = await world(t);
  const environment = w.add('environment');
  const agent = w.add('agent', { environment_id: environment.id, allowed_environment_ids: [environment.id] });
  const late = w.rows.agent.pop(); delete agent.id;
  const reconstructed = await w.reconstruct();
  assert.equal(reconstructed.resources[1].state, 'pending');
  assert.equal(reconstructed.resources[1].id, undefined);
  w.rows.agent.push(late);
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.deepEqual(w.mutations, [`DELETE /api/agents/${late.id}`, `DELETE /api/environments/${environment.id}`]);
  assert.equal(w.load().remainingCount(), 0);
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(w.mutations.length, 2, 'repeat pass does not mutate');
});

for (const scenario of ['duplicate-name', 'changed-id', 'changed-name', 'cleaned']) {
  test(`late dependent-agent reconciliation still refuses ${scenario} before mutation`, async t => {
    const w = await world(t);
    const environment = w.add('environment');
    const agent = w.add('agent', { environment_id: environment.id });
    if (scenario === 'duplicate-name') {
      const late = w.rows.agent.pop(); delete agent.id;
      await w.reconstruct();
      w.rows.agent.push(late, { ...late, id: randomUUID() });
    } else {
      await w.reconstruct();
      if (scenario === 'changed-id') w.rows.agent[0].id = randomUUID();
      if (scenario === 'changed-name') w.rows.agent[0].name = 'different-owner-marker';
      if (scenario === 'cleaned') {
        const f = w.load(); f.manifest.resources[1].state = 'cleaned'; f.save();
      }
    }
    const failures = await w.load().cleanup(AbortSignal.timeout(5000));
    assert.match(failures[0]?.error, /ownership changed|cleaned fixture/);
    assert.deepEqual(w.mutations, []);
    assert.equal(w.rows.environment[0].id, environment.id);
  });
}

for (const kind of ['agent', 'environment', 'vault']) {
  for (const phase of ['reconstruction', 'replay']) {
    test(`refuses a Buzz identity's ${kind} dependency during ${phase} without a conversation`, async t => {
      const w = await world(t); const source = w.add(kind);
      w.evidence.buzz_absence_evidence = 'Earlier operator verification found no stored Buzz dependencies; current inventory must still be checked.';
      if (phase === 'replay') await w.reconstruct();
      w.buzz({ data: [{ id: randomUUID(), agent_id: randomUUID(), environment_id: null, vault_id: randomUUID(), [`${kind}_id`]: source.id }] });
      if (phase === 'reconstruction') {
        await assert.rejects(w.reconstruct(), /Buzz identity/);
        assert.equal(existsSync(w.manifestPath), false);
      } else {
        const failures = await w.load().cleanup(AbortSignal.timeout(5000));
        assert.match(failures[0]?.error, /Buzz identity/);
        assert.equal(w.load().remainingCount(), 1);
      }
      assert.deepEqual(w.mutations, [], 'no deletion may cascade or clear the identity reference');
      assert.equal(w.rows[kind][0].id, source.id);
    });
  }
}

test('an unrelated Buzz identity permits ordinary fixture cleanup', async t => {
  const w = await world(t); w.conversation();
  w.buzz({ data: [{ id: randomUUID(), agent_id: randomUUID(), environment_id: randomUUID(), vault_id: randomUUID() }] });
  await w.reconstruct();
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(w.load().remainingCount(), 0);
  assert.equal(w.requests.filter(r => r === 'GET /api/buzz/agents').length, 2);
});

for (const phase of ['reconstruction', 'replay']) {
  test(`unavailable Buzz inventory requires operator absence evidence during ${phase}`, async t => {
    const w = await world(t); w.add('environment');
    if (phase === 'replay') await w.reconstruct();
    w.buzz({ error: 'Not found', reason: 'not_found' }, 404);
    if (phase === 'reconstruction') await assert.rejects(w.reconstruct(), /Buzz.*unavailable/);
    else {
      const failures = await w.load().cleanup(AbortSignal.timeout(5000));
      assert.match(failures[0]?.error, /Buzz.*unavailable/);
      assert.equal(w.load().remainingCount(), 1);
    }
    assert.deepEqual(w.mutations, []);
  });
}

test('verified core-only absence evidence survives reconstruction and repeat replay', async t => {
  const w = await world(t); w.add('environment');
  w.buzz({ error: 'Not found', reason: 'not_found' }, 404);
  w.evidence.buzz_absence_evidence = 'Operator checked deployment/database history: this core-only instance has never had Buzz identity storage.';
  await w.reconstruct();
  assert.equal(w.load().manifest.recovery.buzz_absence_evidence, w.evidence.buzz_absence_evidence);
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(w.mutations.length, 1);
});

for (const response of [
  { status: 403, body: { error: 'forbidden' } },
  { status: 503, body: { error: 'unavailable' } },
  { status: 404, body: { error: 'proxy route missing' } },
  { status: 200, body: {} },
  { status: 200, body: { data: [{ id: randomUUID() }] } },
  { status: 200, body: { data: [], has_more: true } },
]) {
  test(`Buzz inventory errors fail closed (${response.status} ${JSON.stringify(response.body)})`, async t => {
    const w = await world(t); w.add('environment');
    w.evidence.buzz_absence_evidence = 'Operator checked this core-only instance never had Buzz identity storage.';
    w.buzz(response.body, response.status);
    await assert.rejects(w.reconstruct());
    assert.deepEqual(w.mutations, []);
    assert.equal(existsSync(w.manifestPath), false);
  });
}

for (const phase of ['reconstruction', 'replay']) {
  test(`refuses waiting queue work during ${phase} before agent deletion could cascade it`, async t => {
    const w = await world(t); const agent = w.add('agent');
    if (phase === 'replay') await w.reconstruct();
    const request = { id: randomUUID(), agent_id: agent.id, status: 'queued', conversation_id: null };
    w.queue.push(request);
    if (phase === 'reconstruction') {
      await assert.rejects(w.reconstruct(), /queued request/);
      assert.equal(existsSync(w.manifestPath), false);
    } else {
      const failures = await w.load().cleanup(AbortSignal.timeout(5000));
      assert.match(failures[0]?.error, /queued request/);
      assert.equal(w.load().remainingCount(), 1);
    }
    assert.ok(w.requests.includes('GET /api/sandbox-queue'));
    assert.deepEqual(w.mutations, []);
    assert.deepEqual(w.queue, [request], 'retain the request and its agent; do not cancel or adopt it');
    assert.equal(w.rows.agent[0].id, agent.id);
  });

  test(`an empty waiting list cannot authorize ${phase} without claimed-work settlement evidence`, async t => {
    const w = await world(t); const agent = w.add('agent');
    if (phase === 'replay') await w.reconstruct();
    w.queue.push({ id: randomUUID(), agent_id: agent.id, status: 'starting', conversation_id: null });
    if (phase === 'reconstruction') {
      delete w.evidence.queue_account_settlement_evidence;
      await assert.rejects(w.reconstruct(), /queue settlement evidence/);
      assert.equal(existsSync(w.manifestPath), false);
    } else {
      const fixtures = w.load(); delete fixtures.manifest.recovery.queue_account_settlement_evidence; fixtures.save();
      const failures = await w.load().cleanup(AbortSignal.timeout(5000));
      assert.match(failures[0]?.error, /queue settlement evidence/);
      assert.equal(w.load().remainingCount(), 1);
    }
    assert.ok(w.requests.includes('GET /api/sandbox-queue'));
    assert.deepEqual(w.mutations, []);
    assert.equal(w.queue[0].status, 'starting', 'the waiting-only list omits claimed requests');
    assert.equal(w.rows.agent[0].id, agent.id);
  });
}

test('waiting work on a different agent blocks cleanup until the operator settles it', async t => {
  const w = await world(t); w.conversation();
  const request = { id: randomUUID(), agent_id: randomUUID(), status: 'queued', conversation_id: null };
  await w.reconstruct();
  assert.equal(w.load().manifest.recovery.queue_account_settlement_evidence, w.evidence.queue_account_settlement_evidence);
  w.queue.push(request);
  const failures = await w.load().cleanup(AbortSignal.timeout(5000));
  assert.match(failures[0]?.error, /queued request/);
  assert.deepEqual(w.mutations, []);
  assert.deepEqual(w.queue, [request]);
  // An operator establishes the terminal outcome and refreshes the evidence.
  request.status = 'cancelled';
  const fixtures = w.load();
  fixtures.manifest.recovery.queue_account_settlement_evidence = 'Operator verified every accepted account request is terminal, reconciled all resulting resources and kept every writer stopped.';
  fixtures.save();
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.deepEqual(w.queue, [request]);
  assert.equal(w.requests.filter(r => r === 'GET /api/sandbox-queue').length, 4);
});

for (const response of [
  { status: 404, body: { error: 'not_found' } },
  { status: 503, body: { error: 'unavailable' } },
  { status: 200, body: {} },
  { status: 200, body: { data: [{ id: randomUUID(), status: 'queued' }] } },
  { status: 200, body: { data: [], has_more: true } },
]) {
  test(`unavailable or incomplete queue inventory fails closed (${JSON.stringify(response)})`, async t => {
    const w = await world(t); w.add('agent');
    await w.reconstruct();
    w.queueResponse(response.body, response.status);
    const failures = await w.load().cleanup(AbortSignal.timeout(5000));
    assert.equal(failures[0]?.kind, 'recovery');
    assert.equal(w.load().remainingCount(), 1);
    assert.deepEqual(w.mutations, []);
    rmSync(w.manifestPath);
    await assert.rejects(w.reconstruct());
    assert.equal(existsSync(w.manifestPath), false);
    assert.deepEqual(w.mutations, []);
  });
}

for (const mode of ['ephemeral', 'persistent']) {
  for (const lostReply of [false, true]) {
    test(`partial ${mode} cleanup retries after FK nulling${lostReply ? ' and a lost parent-delete reply' : ''}`, async t => {
      const w = await world(t); const { agent, environment, vault, sandbox } = w.conversation(mode, true);
      await w.reconstruct();
      if (lostReply) w.loseDeleteReply('agent'); else w.failDelete('environment');
      const failures = await w.load().cleanup(AbortSignal.timeout(5000));
      assert.ok(failures.some(f => f.kind === 'environment'));
      assert.equal(sandbox.status, 'terminated');
      assert.equal(sandbox.agent_id, null);
      assert.equal(sandbox.vault_id, lostReply ? vault.id : null, 'an unconfirmed agent deletion retains the vault too');
      assert.equal(sandbox.environment_id, environment.id);
      assert.equal(w.load().manifest.resources.find(r => r.id === agent.id).state, lostReply ? 'created' : 'cleaned');
      const count = w.mutations.length;
      const requestCount = w.requests.length;
      assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
      const remainingDeletes = [...(lostReply ? [`DELETE /api/vaults/${vault.id}`] : []), `DELETE /api/environments/${environment.id}`];
      assert.deepEqual(w.mutations.slice(count), remainingDeletes);
      assert.ok(w.requests.slice(requestCount).includes(`GET /api/agents/${agent.id}`), 'verify the deleted agent by exact ID on this retry');
      assert.ok(w.requests.slice(requestCount).includes(`GET /api/vaults/${vault.id}`), 'check the retained or deleted vault by exact ID on this retry');
      assert.equal(sandbox.environment_id, null);
      assert.equal(w.load().remainingCount(), 0);
      assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
      assert.equal(w.mutations.length, count + remainingDeletes.length, 'all-null terminal history remains an idempotent no-op');
    });
  }
}

for (const scenario of ['live', 'foreign-parent', 'mode', 'cotenant', 'sandbox-id', 'missing-field', 'parent-present']) {
  test(`a terminal sandbox's deleted-parent allowance still refuses ${scenario}`, async t => {
    const w = await world(t); const { agent, sandbox } = w.conversation();
    await w.reconstruct();
    w.failDelete('environment');
    if (scenario === 'parent-present') w.failDelete('agent');
    assert.ok((await w.load().cleanup(AbortSignal.timeout(5000))).length > 0);
    if (scenario === 'live') sandbox.status = 'ready';
    if (scenario === 'foreign-parent') sandbox.agent_id = randomUUID();
    if (scenario === 'mode') sandbox.mode = 'persistent';
    if (scenario === 'cotenant') sandbox.conversations.push({ id: randomUUID() });
    if (scenario === 'sandbox-id') sandbox.id = randomUUID();
    if (scenario === 'missing-field') delete sandbox.agent_id;
    if (scenario === 'parent-present') {
      sandbox.agent_id = null;
      assert.equal(w.rows.agent[0].id, agent.id);
    }
    const count = w.mutations.length;
    const failures = await w.load().cleanup(AbortSignal.timeout(5000));
    assert.equal(failures[0]?.kind, 'recovery');
    assert.equal(w.mutations.length, count, 'retain the remaining environment without further mutations');
    assert.ok(w.load().remainingCount() > 0);
  });
}

for (const kind of ['environment', 'vault']) {
  for (const phase of ['reconstruction', 'replay']) {
    for (const mixed of [false, true]) {
      test(`hidden queued ${kind} override refuses ${phase} with ${mixed ? 'mixed' : 'source-only'} evidence`, async t => {
        const w = await world(t); const source = w.add(kind);
        if (mixed) w.add('agent');
        const foreignAgent = { id: randomUUID(), name: 'other-same-account-agent', environment_id: null,
          allowed_environment_ids: null, allowed_vault_ids: null };
        w.rows.agent.push(foreignAgent);
        if (phase === 'replay') await w.reconstruct();
        const request = { id: randomUUID(), agent_id: foreignAgent.id, status: 'queued', conversation_id: null,
          attrs: { [`${kind}_id`]: source.id, prompt: 'unrecorded submitted work' } };
        w.queue.push(request);
        const { body } = await w.client.request('GET', '/api/sandbox-queue', { expected: 200, recordBody: false });
        assert.equal(body.data[0].attrs, undefined, 'the public API does not expose the dependency');
        const before = w.requests.length;
        if (phase === 'reconstruction') {
          await assert.rejects(w.reconstruct(), /queued request/);
          assert.equal(existsSync(w.manifestPath), false);
        } else {
          const failures = await w.load().cleanup(AbortSignal.timeout(5000));
          assert.match(failures[0]?.error, /queued request/);
          assert.equal(w.load().remainingCount(), mixed ? 2 : 1);
        }
        assert.ok(w.requests.slice(before).includes('GET /api/sandbox-queue'), 'source-only recovery must inspect the queue too');
        assert.deepEqual(w.mutations, [], 'retain the source before teardown can damage accepted work');
        assert.equal(w.rows[kind][0].id, source.id);
        assert.deepEqual(w.queue, [request]);
        assert.equal(request.attrs[`${kind}_id`], source.id);
      });
    }
  }
}

for (const phase of ['reconstruction', 'replay']) {
  test(`hidden queued parent conversation refuses ${phase} before termination`, async t => {
    const w = await world(t); const { conv, sandbox } = w.conversation();
    const foreignAgent = { id: randomUUID(), name: 'unrecorded-agent', environment_id: null,
      allowed_environment_ids: null, allowed_vault_ids: null };
    w.rows.agent.push(foreignAgent);
    if (phase === 'replay') await w.reconstruct();
    const request = { id: randomUUID(), agent_id: foreignAgent.id, status: 'queued', conversation_id: null,
      attrs: { parent_conversation_id: conv.id } };
    w.queue.push(request);
    if (phase === 'reconstruction') {
      await assert.rejects(w.reconstruct(), /queued request/);
      assert.equal(existsSync(w.manifestPath), false);
    } else {
      const failures = await w.load().cleanup(AbortSignal.timeout(5000));
      assert.match(failures[0]?.error, /queued request/);
      assert.equal(w.load().remainingCount(), 3);
    }
    assert.deepEqual(w.mutations, []);
    assert.equal(w.rows.conversation[0].status, 'running');
    assert.equal(sandbox.status, 'ready');
    assert.deepEqual(w.queue, [request]);
  });

  for (const kind of ['environment', 'vault', 'conversation']) {
    test(`agent-scoped evidence cannot authorize ${kind} ${phase} while claimed work is hidden`, async t => {
      const w = await world(t);
      const source = kind === 'conversation' ? w.conversation().conv : w.add(kind);
      if (phase === 'replay') await w.reconstruct();
      const request = { id: randomUUID(), agent_id: randomUUID(), status: 'starting', conversation_id: null,
        attrs: { [kind === 'conversation' ? 'parent_conversation_id' : `${kind}_id`]: source.id } };
      w.queue.push(request);
      const oldEvidence = 'Launch records confirm no accepted queued requests used the recovered agents; other agents may have accepted work.';
      if (phase === 'reconstruction') {
        delete w.evidence.queue_account_settlement_evidence;
        w.evidence.queue_settlement_evidence = oldEvidence;
        await assert.rejects(w.reconstruct(), /queue settlement evidence/);
        assert.equal(existsSync(w.manifestPath), false);
      } else {
        const fixtures = w.load();
        delete fixtures.manifest.recovery.queue_account_settlement_evidence;
        fixtures.manifest.recovery.queue_settlement_evidence = oldEvidence;
        fixtures.save();
        const failures = await w.load().cleanup(AbortSignal.timeout(5000));
        assert.match(failures[0]?.error, /queue settlement evidence/);
        assert.ok(w.load().remainingCount() > 0);
      }
      assert.ok(w.requests.includes('GET /api/sandbox-queue'));
      assert.deepEqual(w.mutations, []);
      assert.deepEqual(w.queue, [request]);
      assert.ok(w.rows[kind].some(row => row.id === source.id));
    });
  }
}

for (const kind of ['environment', 'vault']) {
  for (const explicitDependency of [false, true]) {
    test(`an invisible agent retains its ${kind} with ${explicitDependency ? 'explicit' : 'unknown'} source evidence until a later pass`, async t => {
      const w = await world(t); const source = w.add(kind);
      const attrs = kind === 'environment'
        ? { environment_id: source.id, allowed_environment_ids: [source.id] }
        : { environment_id: null, allowed_vault_ids: [source.id] };
      const agent = w.add('agent', attrs);
      if (explicitDependency) Object.assign(agent, attrs);
      const late = w.rows.agent.pop(); delete agent.id;
      const manifest = await w.reconstruct();
      assert.equal(manifest.resources[1].state, 'pending');
      assert.equal(manifest.resources[1].id, undefined);
      for (let attempt = 0; attempt < 2; attempt++) {
        const failures = await w.load().cleanup(AbortSignal.timeout(5000));
        assert.ok(failures.some(f => f.kind === 'agent' && /Unresolved create intent/.test(f.error)));
        assert.deepEqual(w.mutations, [], 'an unsettled direct agent POST must not lose its possible source');
        assert.equal(w.rows[kind][0].id, source.id);
        assert.deepEqual(w.load().manifest.resources.map(r => r.state), ['created', 'pending']);
        assert.equal(w.load().remainingCount(), 2);
      }
      w.rows.agent.push(late);
      assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
      assert.deepEqual(w.mutations, [`DELETE /api/agents/${late.id}`, `DELETE /api/${kind === 'vault' ? 'vaults' : 'environments'}/${source.id}`]);
      assert.equal(w.load().remainingCount(), 0);
      assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
      assert.equal(w.mutations.length, 2);
    });
  }
}

for (const lostReply of [false, true]) {
  test(`agent deletion ${lostReply ? 'with a lost reply' : 'failure'} retains every possible source until retry`, async t => {
    const w = await world(t);
    const environment = w.add('environment'), vault = w.add('vault');
    const agent = w.add('agent', { environment_id: environment.id, allowed_vault_ids: [vault.id] });
    await w.reconstruct();
    if (lostReply) w.loseDeleteReply('agent'); else w.failDelete('agent');
    const failures = await w.load().cleanup(AbortSignal.timeout(5000));
    assert.ok(failures.some(f => f.kind === 'agent'));
    assert.deepEqual(w.mutations, [`DELETE /api/agents/${agent.id}`]);
    assert.equal(w.rows.environment[0].id, environment.id);
    assert.equal(w.rows.vault[0].id, vault.id);
    assert.equal(w.load().remainingCount(), 3);
    assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
    assert.equal(w.load().remainingCount(), 0);
    assert.deepEqual(w.mutations.slice(lostReply ? 1 : 2), [`DELETE /api/vaults/${vault.id}`, `DELETE /api/environments/${environment.id}`]);
    const count = w.mutations.length;
    assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
    assert.equal(w.mutations.length, count);
  });
}

test('combined profile recovery cleans every agent before sources regardless of creation index', async t => {
  const w = await world(t);
  w.evidence.profiles = ['basic', 'execution'];
  const basicEnvironment = w.add('environment'), basicAgent = w.add('agent');
  w.rows.agent.pop(); // Basic lifecycle already deleted this agent, but cleanup has not reconciled it.
  const { environment, agent, conv } = w.conversation();
  await w.reconstruct();
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(w.load().remainingCount(), 0);
  const deletes = w.mutations.filter(request => request.startsWith('DELETE'));
  assert.deepEqual(deletes, [`DELETE /api/conversations/${conv.id}`, `DELETE /api/agents/${agent.id}`,
    `DELETE /api/environments/${environment.id}`, `DELETE /api/environments/${basicEnvironment.id}`]);
  const firstSource = w.requests.indexOf(`DELETE /api/environments/${environment.id}`);
  assert.ok(w.requests.lastIndexOf(`GET /api/agents/${basicAgent.id}`) < firstSource, 'reconcile the older agent before the newer source');
  const count = w.mutations.length;
  assert.deepEqual(await w.load().cleanup(AbortSignal.timeout(5000)), []);
  assert.equal(w.mutations.length, count);
});
