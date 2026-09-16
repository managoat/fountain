import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createReceiver, fingerprint, RECEIVER_VERSION } from '../receivers/secrets.mjs';
import { SecretEvidence } from '../lib/secret-evidence.mjs';
import { Client, Redactor } from '../lib/http.mjs';
import { Fixtures } from '../lib/fixtures.mjs';
import { streamEvents } from '../lib/sse.mjs';
import { configFrom, run } from '../lib/runner.mjs';
import { receiverOrigins } from '../lib/receiver.mjs';
import { ReceiverSession } from '../lib/receiver.mjs';
import { ciConfig } from '../ci.mjs';
import { secretScript, verifyEchoEvidence } from '../profiles/secrets.mjs';

const secret = () => `suite_secret_${randomUUID()}`;
function temporary(t) { const dir = mkdtempSync(join(tmpdir(), 'fountain-secrets-test-')); t.after(() => rmSync(dir, { force: true, recursive: true })); return dir; }
async function listen(t, server) {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  return `http://127.0.0.1:${server.address().port}`;
}
async function receiver(t, options = {}) {
  const adminKey = randomUUID(), nonce = randomUUID(), id = randomUUID(), bound = secret(), plain = secret();
  const url = await listen(t, createReceiver({ adminKey, ...options }));
  const request = async (method, path, body, headers = {}) => {
    const response = await fetch(url + path, { method, headers: { authorization: `Bearer ${adminKey}`, 'content-type': 'application/json', ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: response.status, body: response.status === 204 ? null : await response.json() };
  };
  const spec = { nonce, bound_sha256: fingerprint(bound), plain_sha256: fingerprint(plain), placeholder: '__suite_sample_bound__' };
  return { url, request, adminKey, nonce, id, bound, plain, spec, runPath: `/_suite/runs/${id}`, capturePath: `/capture/${id}/allowed/${nonce}` };
}

test('controlled receiver observes actual injected bytes and retains only receipt/match evidence', async t => {
  const f = await receiver(t);
  assert.equal((await f.request('GET', '/_suite/identity')).body.version, RECEIVER_VERSION);
  assert.equal((await f.request('PUT', f.runPath, f.spec)).status, 201);
  const payload = { nonce: f.nonce, plain: f.plain, placeholder: f.spec.placeholder };
  const observed = await f.request('POST', f.capturePath, payload, { authorization: '', 'x-fountain-fixture': f.bound });
  assert.equal(observed.status, 200);
  assert.equal(observed.body.bound_echo, f.bound);
  assert.equal(observed.body.plain_echo, f.plain);
  const evidence = await f.request('GET', f.runPath);
  assert.equal(evidence.body.observations.length, 1);
  assert.equal(evidence.body.observations[0].id, observed.body.receipt_id);
  for (const name of ['nonce_matches', 'bound_matches', 'plain_matches', 'placeholder_matches']) assert.equal(evidence.body.observations[0][name], true);
  assert.ok(!JSON.stringify(evidence).includes(f.bound));
  assert.ok(!JSON.stringify(evidence).includes(f.plain));
  assert.equal((await f.request('DELETE', f.runPath)).status, 204);
  assert.equal((await f.request('GET', f.runPath)).status, 404);
});

test('receiver rejects bad credentials, non-synthetic echoes, replacement runs and wrong nonces', async t => {
  const f = await receiver(t);
  assert.equal((await f.request('PUT', f.runPath, f.spec, { authorization: 'Bearer wrong' })).status, 401);
  assert.equal((await f.request('PUT', f.runPath, f.spec)).status, 201);
  assert.equal((await f.request('PUT', f.runPath, f.spec)).status, 409);
  const payload = { nonce: f.nonce, plain: f.plain, placeholder: f.spec.placeholder };
  const wrong = await f.request('POST', f.capturePath, payload, { 'x-fountain-fixture': 'accidental-third-party-value' });
  assert.equal(wrong.status, 403); assert.ok(!JSON.stringify(wrong).includes('accidental-third-party-value'));
  assert.equal((await f.request('POST', f.capturePath.replace(f.nonce, randomUUID()), payload)).status, 404);
  const evidence = await f.request('GET', f.runPath);
  assert.equal(evidence.body.observations[0].bound_matches, false);
  assert.equal((await f.request('GET', f.runPath, undefined, { authorization: '' })).status, 401);
});

test('receiver records blocked arrivals and has bounded capacity, requests and expiration', async t => {
  let now = 0;
  const f = await receiver(t, { now: () => now, maxRuns: 1, ttlMs: 100 });
  await f.request('PUT', f.runPath, f.spec);
  assert.equal((await f.request('PUT', `/_suite/runs/${randomUUID()}`, f.spec)).status, 503);
  for (let i = 0; i < 8; i++) assert.equal((await f.request('POST', f.capturePath.replace('/allowed/', '/blocked/'), {})).status, 403);
  assert.equal((await f.request('POST', f.capturePath, {})).status, 429);
  assert.ok((await f.request('GET', f.runPath)).body.observations.every(o => o.phase === 'blocked'));
  now = 101;
  assert.equal((await f.request('GET', f.runPath)).status, 404);
  assert.equal((await f.request('POST', f.capturePath, {})).status, 404);
  assert.equal((await f.request('PUT', f.runPath, f.spec)).status, 201);
});

test('HTTP non-disclosure fails on raw leaked values even when its retained trace is redacted', async t => {
  const value = secret(), trace = [];
  const url = await listen(t, createServer((_req, res) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ data: { output: value } })); }));
  const evidence = new SecretEvidence([value]);
  const client = new Client({ baseUrl: url, redactor: new Redactor([value]), trace: entry => trace.push(entry) });
  client.assertPublicSafe = (body, source) => evidence.inspect(body, source);
  await assert.rejects(client.request('GET', '/api/example', { expected: 200 }), /Synthetic secret disclosed/);
  assert.equal(evidence.leaks.length, 1);
  assert.ok(!JSON.stringify(trace).includes(value));
});

test('SSE non-disclosure checks raw frames and never emits the secret into trace evidence', async t => {
  const value = secret(), trace = [], id = randomUUID();
  const url = await listen(t, createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end(`id: 1\nevent: output\ndata: ${JSON.stringify({ kind: 'output', data: value })}\n\n`);
  }));
  const evidence = new SecretEvidence([value]);
  const client = new Client({ baseUrl: url, key: randomUUID(), redactor: new Redactor([value]), trace: entry => trace.push(entry) });
  client.assertPublicSafe = (body, source) => evidence.inspect(body, source);
  await assert.rejects(async () => { for await (const _ of streamEvents(client, `/api/conversations/${id}/stream`, { signal: AbortSignal.timeout(1000) })) {} }, /Synthetic secret disclosed/);
  assert.equal(evidence.inspected.sse, 1);
  assert.ok(!JSON.stringify(trace).includes(value));
});

test('secret inspection covers base64 file responses and reports/scrubs an artifact leak', t => {
  const value = secret(), evidence = new SecretEvidence([value]), dir = temporary(t);
  assert.throws(() => evidence.inspect({ data: { encoding: 'base64', content: Buffer.from(value).toString('base64') } }, { path: '/file' }), /disclosed/);
  writeFileSync(join(dir, 'http.jsonl'), JSON.stringify({ output: value }));
  assert.throws(() => evidence.scanArtifacts(dir, new Redactor([value])), /artifact/);
  assert.ok(!readFileSync(join(dir, 'http.jsonl'), 'utf8').includes(value));
});

test('cleanup can read ownership despite a leak while preserving the failed non-disclosure evidence', () => {
  const value = secret(), evidence = new SecretEvidence([value]);
  evidence.throwOnLeak = false;
  evidence.inspect({ data: { name: 'run-owned-fixture', unexpected: value } }, { path: '/api/environments/owned' });
  assert.equal(evidence.leaks.length, 1);
  assert.equal(evidence.inspected.http, 1);
});

test('binding response loss can recover only its exact run marker and host during cleanup', async t => {
  const dir = temporary(t), runId = randomUUID(), ownerId = randomUUID(), id = randomUUID();
  let binding, deleted = false;
  const client = { baseUrl: 'https://example.test', async request(method, path, options) {
    if (method === 'POST') { binding = { ...options.body, id }; throw new Error('response lost'); }
    if (method === 'GET') return { status: 200, body: { data: [binding] } };
    assert.equal(path, `/api/secret-bindings/${id}`); deleted = true; return { status: 204 };
  } };
  const f = new Fixtures(join(dir, 'cleanup.json'), client, { runId, ownerId, baseUrl: client.baseUrl });
  await assert.rejects(f.create('binding', { host: 'receiver.example.test', auth_type: 'api_key' }), /response lost/);
  const loaded = Fixtures.load(f.path, client, ownerId);
  assert.deepEqual(await loaded.cleanup(AbortSignal.timeout(1000)), []);
  assert.equal(deleted, true);
  assert.ok(binding.key.startsWith(`SUITE_${runId.replaceAll('-', '').toUpperCase()}_BINDING_`));
});

test('changed binding ownership is not deleted and a leaked conversation retains its vault and bindings', async t => {
  const dir = temporary(t), runId = randomUUID(), ownerId = randomUUID();
  const f = new Fixtures(join(dir, 'cleanup.json'), { request: async () => { throw new Error('Must retain intent'); } }, { runId, ownerId, baseUrl: 'https://example.test' });
  const vault = { kind: 'vault', id: randomUUID(), name: `suite-${runId}-vault-0`, state: 'created' };
  const binding = { kind: 'binding', id: randomUUID(), name: `SUITE_${runId.replaceAll('-', '').toUpperCase()}_BINDING_1`, host: 'receiver.example.test', state: 'created' };
  const conv = { kind: 'conversation', id: randomUUID(), name: `suite-${runId}-conversation-2`, vault_id: vault.id, agent_id: randomUUID(), environment_id: randomUUID(), state: 'created' };
  f.manifest.resources.push(vault, binding, conv);
  const failures = await f.cleanup(AbortSignal.timeout(1000));
  assert.equal(failures.length, 3);
  assert.ok(failures.slice(1).every(f => f.error.includes('Retaining parent')));
  f.manifest.resources.pop(); f.manifest.resources.shift();
  f.client.request = async (method) => { assert.equal(method, 'GET'); return { status: 200, body: { data: [{ id: binding.id, key: binding.name, host: 'changed.example.test' }] } }; };
  assert.match((await f.cleanup(AbortSignal.timeout(1000)))[0].error, /ownership/);
});

const config = () => ({ base_url: 'https://fountain.example.test', credentials: { primary: 'KEY', secondary: 'OTHER' }, profiles: ['secrets'],
  execution: { runtime: 'claude', model: 'anthropic/claude-haiku-4-5', sandbox_provider: 'e2b', max_turns: 1 },
  secrets: { allowed_url: 'https://allowed.example.test', blocked_url: 'https://blocked.example.test', admin_credential: 'RECEIVER_KEY', bootstrap_hosts: ['registry.npmjs.org'] } });

test('secrets profile requires one explicit prompt, two HTTPS receiver hosts, admin credentials and broker-capable provider', t => {
  const dir = temporary(t), path = join(dir, 'target.json'), env = { KEY: randomUUID(), OTHER: randomUUID(), RECEIVER_KEY: randomUUID() };
  writeFileSync(path, JSON.stringify(config()));
  assert.equal(configFrom(path, env).execution.max_turns, 1);
  for (const change of [c => c.execution.max_turns = 2, c => c.execution.sandbox_provider = 'runner',
    c => c.secrets.blocked_url = c.secrets.allowed_url, c => c.secrets.allowed_url = 'http://allowed.example.test',
    c => c.secrets.allowed_url = 'https://127.0.0.1', c => c.profiles.push('execution'),
    c => c.secrets.bootstrap_hosts.push('blocked.example.test'), c => c.limits = { run_ms: 600001 }, c => c.limits = { resources: 4 }]) {
    const c = config(); change(c); writeFileSync(path, JSON.stringify(c)); assert.throws(() => configFrom(path, env));
  }
  writeFileSync(path, JSON.stringify(config()));
  assert.throws(() => configFrom(path, { KEY: env.KEY, OTHER: env.OTHER }), /receiver admin/);
  assert.throws(() => receiverOrigins({ allowed_url: 'https://user:password@example.test', blocked_url: 'https://other.example.test' }));
});

test('missing broker feature fails setup before receiver access or resource mutations', async t => {
  const requests = [], c = config(), dir = temporary(t), path = join(dir, 'target.json');
  const ids = [randomUUID(), randomUUID()], keys = [randomUUID(), randomUUID()];
  c.base_url = await listen(t, createServer((req, res) => {
    requests.push([req.method, req.url]);
    res.writeHead(req.url === '/api/secret-bindings' ? 404 : 200, { 'content-type': 'application/json' });
    if (req.url === '/api/auth/me') res.end(JSON.stringify({ id: ids[req.headers.authorization === `Bearer ${keys[0]}` ? 0 : 1], email: 'suite@example.test', role: 'user', email_verified: true }));
    else if (req.url === '/api/catalog') res.end(JSON.stringify({ data: { runtimes: ['claude'], models: {}, sandbox_providers: { enabled: ['e2b'], default: 'e2b' }, package_managers: [], apps: { conversations: null, team: null }, first_request: { curl: '', typescript: '', prompt: '', placeholders: [] } } }));
    else res.end(JSON.stringify({ error: 'brokerage_not_enabled' }));
  }));
  writeFileSync(path, JSON.stringify(c));
  const out = join(dir, 'results');
  const code = await run({ configPath: path, out, env: { KEY: keys[0], OTHER: keys[1], RECEIVER_KEY: randomUUID() }, log() {} });
  assert.equal(code, 2);
  assert.ok(requests.some(([, path]) => path === '/api/secret-bindings'));
  assert.ok(requests.every(([method]) => method === 'GET'));
  assert.equal(JSON.parse(readFileSync(join(out, 'result.json'))).cleanup.remaining, 0);
});

test('sandbox script carries only names/nonces, reads actual environment values and makes bounded curl attempts', () => {
  const script = secretScript({ allowed: 'https://allowed.example.test', blocked: 'https://blocked.example.test', runId: randomUUID(), nonce: randomUUID(), boundKey: 'SUITE_BOUND', plainKey: 'SUITE_PLAIN' });
  assert.match(script, /os\.environ\["SUITE_BOUND"\]/);
  // A refused tunnel is identified by the proxy's CONNECT 403. Both curl exit codes
  // curl has used for it are accepted, and nothing else, so a request that
  // succeeded or failed some other way still fails the fixture.
  assert.match(script, /denied\.returncode not in \(7, 56\) or denied\.stdout != '403'/);
  assert.equal((script.match(/subprocess\.run/g) ?? []).length, 2);
  assert.ok(!script.includes('FOUNTAIN_RECEIVER_ADMIN_KEY'));
});

test('receiver echo verification requires the independently observed receipt and both redacted fields', () => {
  const receipt = randomUUID();
  const events = [{ data: JSON.stringify({ output: `fixture-receiver-echo=${JSON.stringify({ receipt_id: receipt, bound_echo: '[REDACTED]', plain_echo: '[REDACTED]' })}` }) }];
  verifyEchoEvidence(events, receipt);
  assert.throws(() => verifyEchoEvidence(events, randomUUID()), /receipt/);
  assert.throws(() => verifyEchoEvidence([{ data: receipt + ' fixture-receiver-echo=' }], receipt), /redacted echoes/);
});

test('receiver session pins both identities, retains lost-create intent and rejects a retargeted cleanup manifest', async t => {
  const dir = temporary(t), path = join(dir, 'receiver.json'), runId = randomUUID(), instanceId = randomUUID();
  const session = new ReceiverSession({ settings: config().secrets, adminKey: randomUUID(), path, runId, redactor: new Redactor() });
  session.client.request = async () => ({ body: { version: RECEIVER_VERSION, instance_id: instanceId } });
  session.publicClient.request = async () => ({ body: { version: RECEIVER_VERSION, instance_id: randomUUID() } });
  await assert.rejects(session.verify(), /same controlled receiver/);
  session.publicClient.request = session.client.request;
  await session.verify();
  session.client.request = async () => { throw new Error('lost create reply'); };
  await assert.rejects(session.create({}), /lost create reply/);
  assert.equal(JSON.parse(readFileSync(path)).state, 'pending');
  session.loadCleanup();
  writeFileSync(path, JSON.stringify({ ...session.manifest, base_url: 'https://foreign.example.test' }));
  assert.throws(() => session.loadCleanup(), /does not match/);
});

test('manual CI secrets selection retains its one-prompt budget and approved target guard', () => {
  const env = { SUITE_TARGET: 'staging', SUITE_PROFILE: 'secrets', SUITE_ENABLED: 'true', SUITE_MODE: 'public', SUITE_TARGET_JSON: JSON.stringify(config()) };
  assert.equal(ciConfig(env).execution.max_turns, 1);
  assert.deepEqual(ciConfig(env).profiles, ['secrets']);
  assert.throws(() => ciConfig({ ...env, SUITE_TARGET: 'unknown' }), /approved/);
});
