import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createWebhookReceiver, verifySignature } from '../receivers/webhooks.mjs';
import { verifyWebhookDeliveries, webhookEvidenceSettled } from '../profiles/webhooks.mjs';
import { Fixtures } from '../lib/fixtures.mjs';
import { configFrom } from '../lib/runner.mjs';
import { ciConfig } from '../ci.mjs';

const secret = () => `whsec_${randomBytes(32).toString('base64url')}`;
const sign = (body, key, time) => `t=${time},v1=${createHmac('sha256', key).update(`${time}.${body}`).digest('hex')}`;
function temporary(t) { const dir = mkdtempSync(join(tmpdir(), 'fountain-webhooks-test-')); t.after(() => rmSync(dir, { force: true, recursive: true })); return dir; }
function payload() { return { id: '123', type: 'conversation.terminate.done', created_at: '2026-09-06T12:00:00.123456Z', data: {
  conversation_id: randomUUID(), agent_id: randomUUID(), parent_conversation_id: null, status: 'terminated', stage: 'terminate', state: 'done', turn_id: null, duration_ms: null, labels: {} } }; }
async function receiver(t, opts = {}) {
  const adminKey = randomUUID(), key = secret(), id = randomUUID(), event = payload();
  const server = createWebhookReceiver({ adminKey, ...opts });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const url = `http://127.0.0.1:${server.address().port}`;
  const request = async (method, path, body, headers = {}) => {
    const response = await fetch(url + path, { method, headers: { authorization: `Bearer ${adminKey}`, 'content-type': 'application/json', ...headers }, body });
    const text = await response.text(); return { status: response.status, body: text ? JSON.parse(text) : null };
  };
  const runPath = `/_suite/runs/${id}`;
  const spec = { signing_secret: key, conversation_id: event.data.conversation_id, agent_id: event.data.agent_id };
  assert.equal((await request('PUT', runPath, JSON.stringify(spec))).status, 201);
  const deliver = (attempt, eventBody = JSON.stringify(event), headers = {}) => request('POST', `/hook/${id}`, eventBody, {
    authorization: '', 'fountain-signature': sign(eventBody, key, Math.floor((opts.now?.() ?? Date.now()) / 1000)),
    'fountain-event-id': event.id, 'fountain-event-type': event.type, 'fountain-delivery-attempt': String(attempt), ...headers });
  return { request, deliver, key, id, event, runPath, spec };
}

test('webhook verification uses raw bytes, signed timestamp and constant-time HMAC comparison', () => {
  const key = secret(), body = '{"a": 1}', time = 1788696000, header = sign(body, key, time);
  assert.equal(verifySignature(header, Buffer.from(body), key, time * 1000), true);
  assert.equal(verifySignature(header, Buffer.from('{"a":1}'), key, time * 1000), false);
  assert.equal(verifySignature(header, Buffer.from(body), secret(), time * 1000), false);
  assert.equal(verifySignature(header, Buffer.from(body), key, (time + 301) * 1000), false);
  assert.equal(verifySignature(header + `,t=${time}`, Buffer.from(body), key, time * 1000), false);
  assert.equal(verifySignature(header.replace(`t=${time}`, `t=${time + 1}`), Buffer.from(body), key, time * 1000), false);
});

test('actual receiver fails one signed event transiently, accepts retries/duplicates and retains safe receipts', async t => {
  const f = await receiver(t), deliveries = [];
  for (const attempt of [1, 2, 2, 3]) {
    const response = await f.deliver(attempt);
    assert.equal(response.status, attempt === 1 ? 503 : 200);
    deliveries.push({ id: randomUUID(), event_id: f.event.id, event_type: f.event.type, attempt, status_code: response.status, response_body: JSON.stringify(response.body) });
  }
  const observations = (await f.request('GET', f.runPath)).body.observations;
  assert.ok(!JSON.stringify(observations).includes(f.key));
  const event = { id: Number(f.event.id), ts: f.event.created_at, stage: 'terminate', state: 'done', turn_id: null, duration_ms: null };
  const summary = verifyWebhookDeliveries(observations, deliveries.reverse(), event, { id: f.event.data.conversation_id, agent_id: f.event.data.agent_id });
  assert.equal(summary.repeated_attempt_records, 1);
  assert.equal(summary.repeated_event_deliveries, 3);
  assert.equal((await f.request('DELETE', f.runPath)).status, 204);
  assert.equal((await f.request('GET', f.runPath)).status, 404);
  assert.equal((await f.deliver(4)).status, 404);
});

test('invalid signatures and extra payload values are refused without consuming the transient failure', async t => {
  const f = await receiver(t);
  assert.equal((await f.deliver(1, JSON.stringify(f.event), { 'fountain-signature': 'invalid-private-value' })).status, 401);
  assert.equal((await f.deliver(1, JSON.stringify({ ...f.event, prompt: 'private-do-not-store' }))).status, 422);
  assert.equal((await f.deliver(1, JSON.stringify(f.event), { 'fountain-event-id': '999' })).status, 422);
  assert.equal((await f.deliver(1)).status, 503);
  const observed = JSON.stringify((await f.request('GET', f.runPath)).body);
  assert.ok(!observed.includes('private-do-not-store'));
  assert.ok(!observed.includes('invalid-private-value'));
  assert.equal((await f.request('GET', f.runPath, undefined, { authorization: '' })).status, 401);
  assert.equal((await f.request('PUT', f.runPath, JSON.stringify(f.spec))).status, 409);
});

test('webhook receiver bounds requests, capacity and expiration', async t => {
  let now = 1788696000000;
  const f = await receiver(t, { now: () => now, ttlMs: 100, maxRuns: 1 });
  assert.equal((await f.request('PUT', `/_suite/runs/${randomUUID()}`, JSON.stringify(f.spec))).status, 503);
  for (let i = 0; i < 64; i++) await f.deliver(2);
  assert.equal((await f.deliver(2)).status, 429);
  now += 101;
  assert.equal((await f.deliver(2)).status, 404);
  assert.equal((await f.request('GET', f.runPath)).status, 404);
});

test('a delivery verdict rejects manual attempt-counter resets, fabricated receipts and event drift', () => {
  const data = payload(), event = { id: 123, ts: data.created_at, stage: 'terminate', state: 'done', turn_id: null, duration_ms: null };
  const conversation = { id: data.data.conversation_id, agent_id: data.data.agent_id };
  const observations = [503, 200].map((status, i) => ({ receipt_id: randomUUID(), signature_valid: true, payload_valid: true, headers_match: true, payload: data, attempt: i + 1, status }));
  const deliveries = observations.map(o => ({ id: randomUUID(), event_id: '123', event_type: data.type, attempt: o.attempt, status_code: o.status, response_body: JSON.stringify({ receipt_id: o.receipt_id }) }));
  verifyWebhookDeliveries(observations, deliveries, event, conversation);
  assert.equal(webhookEvidenceSettled(observations, deliveries.slice(0, 1)), false);
  assert.equal(webhookEvidenceSettled(observations.slice(0, 1), deliveries), false);
  assert.equal(webhookEvidenceSettled(observations, deliveries), true);
  for (const mutate of [o => o[1].attempt = 1, o => o[0].signature_valid = false, o => o[1].receipt_id = randomUUID(),
    o => o[1].payload.created_at = '2026-09-06T12:00:01Z', o => o[1].payload.data.conversation_id = randomUUID(),
    // A webhook carrying labels the conversation does not have is drift too.
    o => o[1].payload.data.labels = { env: 'drifted' }]) {
    const bad = structuredClone(observations); mutate(bad); assert.throws(() => verifyWebhookDeliveries(bad, deliveries, event, conversation));
  }
});

test('lost webhook create reply recovers exact description and URL; disable failure still attempts deletion', async t => {
  const runId = randomUUID(), ownerId = randomUUID(), calls = [], id = randomUUID();
  let endpoint, deleted = false;
  const client = { baseUrl: 'https://fountain.example.test', async request(method, path, options) {
    calls.push(method);
    if (method === 'POST') { endpoint = { ...options.body, id }; throw new Error('reply lost'); }
    if (method === 'PATCH') throw new Error('disable reply lost');
    if (method === 'DELETE') { deleted = true; return { status: 204 }; }
    if (path === '/api/webhooks') return { status: 200, body: { data: [endpoint] } };
    return deleted ? { status: 404 } : { status: 200, body: { data: endpoint } };
  } };
  const f = new Fixtures(join(temporary(t), 'cleanup.json'), client, { runId, ownerId, baseUrl: client.baseUrl });
  await assert.rejects(f.create('webhook', { url: 'https://receiver.example.test/hook/run' }), /reply lost/);
  const loaded = Fixtures.load(f.path, client, ownerId);
  assert.deepEqual(await loaded.cleanup(AbortSignal.timeout(1000)), []);
  assert.equal(deleted, true); assert.ok(calls.indexOf('PATCH') < calls.indexOf('DELETE'));
});

test('webhook cleanup rejects changed targets and runs before later-created ordinary fixtures', async t => {
  const runId = randomUUID(), ownerId = randomUUID(), id = randomUUID(), agentId = randomUUID(), calls = [];
  let changed = true, deleted = false;
  const webhook = { kind: 'webhook', name: `suite-${runId}-webhook-0`, id, url: 'https://receiver.example.test/hook/run', state: 'created' };
  const agent = { kind: 'agent', name: `suite-${runId}-agent-1`, id: agentId, state: 'created' };
  const client = { async request(method, path) {
    calls.push([method, path]);
    if (path.startsWith('/api/agents/')) return method === 'GET' ? { status: 200, body: { data: { id: agentId, name: agent.name } } } : { status: 204 };
    if (method === 'GET') return deleted ? { status: 404 } : { status: 200, body: { data: { id, description: webhook.name, url: changed ? 'https://foreign.example.test/hook' : webhook.url } } };
    if (method === 'DELETE') deleted = true;
    return { status: method === 'PATCH' ? 200 : 204 };
  } };
  const f = new Fixtures(join(temporary(t), 'cleanup.json'), client, { runId, ownerId, baseUrl: 'https://fountain.example.test' });
  f.manifest.resources.push(webhook, agent);
  assert.match((await f.cleanup(AbortSignal.timeout(1000)))[0].error, /ownership/);
  assert.equal(deleted, false);
  changed = false; agent.state = 'created'; calls.length = 0;
  assert.deepEqual(await f.cleanup(AbortSignal.timeout(1000)), []);
  assert.ok(calls.findIndex(([m, p]) => m === 'DELETE' && p.includes('/webhooks/')) < calls.findIndex(([m, p]) => m === 'DELETE' && p.includes('/agents/')));
});

const config = () => ({ base_url: 'https://fountain.example.test', profiles: ['webhooks'], credentials: { primary: 'KEY', secondary: 'OTHER' },
  execution: { runtime: 'claude', model: 'anthropic/claude-haiku-4-5', sandbox_provider: 'e2b', max_turns: 0 },
  webhooks: { receiver_url: 'https://receiver.example.test', admin_credential: 'RECEIVER_KEY' } });
test('webhooks are independently selected with zero inference and bounded receiver configuration', t => {
  const path = join(temporary(t), 'target.json'), env = { KEY: randomUUID(), OTHER: randomUUID(), RECEIVER_KEY: randomUUID() };
  writeFileSync(path, JSON.stringify(config())); assert.equal(configFrom(path, env).execution.max_turns, 0);
  for (const mutate of [c => c.profiles.push('mcp'), c => c.execution.max_turns = 1, c => c.webhooks.receiver_url = 'http://receiver.example.test',
    c => c.webhooks.delivery_ms = 300001, c => c.webhooks.observe_ms = 60001, c => c.limits = { resources: 3 }, c => c.limits = { run_ms: 600001 }]) {
    const bad = config(); mutate(bad); writeFileSync(path, JSON.stringify(bad)); assert.throws(() => configFrom(path, env));
  }
  assert.equal(ciConfig({ SUITE_TARGET: 'staging', SUITE_ENABLED: 'true', SUITE_PROFILE: 'webhooks', SUITE_MODE: 'public', SUITE_TARGET_JSON: JSON.stringify(config()) }).execution.max_turns, 0);
});

// The fixture above once omitted `labels`, matching the receiver rather than
// the payload Fountain sends, so a receiver that rejected every real delivery
// still passed. These pin the envelope as `Fountain.Webhooks.payload/3` builds
// it, and keep the "nothing else, ever" promise enforced.
test('the receiver accepts the envelope Fountain actually sends, labels included', async t => {
  const r = await receiver(t);
  const labelled = structuredClone(r.event);
  labelled.data.labels = { env: 'prod', 'drift': 'true' };
  const body = JSON.stringify(labelled);
  const first = await r.deliver(1, body);
  assert.equal(first.status, 503, 'a valid envelope reaches the deliberate first failure');
  const { body: evidence } = await r.request('GET', r.runPath);
  assert.equal(evidence.observations[0].payload_valid, true);
  assert.equal(evidence.observations[0].headers_match, true);
});

test('an envelope field Fountain does not promise is still refused', async t => {
  const r = await receiver(t);
  const leaky = structuredClone(r.event);
  leaky.data.prompt = 'content that must never ride in a webhook';
  const res = await r.deliver(1, JSON.stringify(leaky));
  assert.equal(res.status, 422, 'an added field is content arriving unnoticed, not a compatible change');
});

for (const [name, labels] of [
  ['an array', ['env']],
  ['a non-string value', { env: 1 }],
  ['an empty key', { '': 'x' }],
  ['a key over 64 bytes', { ['k'.repeat(65)]: 'x' }],
  ['a value over 256 bytes', { env: 'v'.repeat(257) }],
  ['more than 32 entries', Object.fromEntries(Array.from({ length: 33 }, (_, i) => [`k${i}`, 'v']))],
]) {
  test(`labels as ${name} are refused`, async t => {
    const r = await receiver(t);
    const bad = structuredClone(r.event);
    bad.data.labels = labels;
    assert.equal((await r.deliver(1, JSON.stringify(bad))).status, 422);
  });
}

test('a delivery verdict requires the webhook to carry the conversation\'s own labels', () => {
  const data = payload(), labels = { env: 'prod', team: 'ops' };
  data.data.labels = labels;
  const event = { id: 123, ts: data.created_at, stage: 'terminate', state: 'done', turn_id: null, duration_ms: null };
  const observations = [503, 200].map((status, i) => ({ receipt_id: randomUUID(), signature_valid: true, payload_valid: true, headers_match: true, payload: data, attempt: i + 1, status }));
  const deliveries = observations.map(o => ({ id: randomUUID(), event_id: '123', event_type: data.type, attempt: o.attempt, status_code: o.status, response_body: JSON.stringify({ receipt_id: o.receipt_id }) }));
  const conversation = { id: data.data.conversation_id, agent_id: data.data.agent_id, labels };
  verifyWebhookDeliveries(observations, deliveries, event, conversation);
  assert.throws(() => verifyWebhookDeliveries(observations, deliveries, event, { ...conversation, labels: { env: 'prod' } }),
    /differs from the public conversation event/);
});
