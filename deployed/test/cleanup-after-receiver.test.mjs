import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { replayCleanup } from '../cleanup-replay.mjs';
import { cleanupTarget } from '../verify.mjs';
import { journalSettled, discardJournal, TERMINAL } from '../lib/receiver-journal.mjs';
import { MCP_VERSION } from '../receivers/mcp.mjs';

// A run that hosts its own receiver publishes it over borrowed origins and
// takes both down when it ends. If a fixture survived that run, the operator
// has to be able to delete it afterwards — and the run's own target names a
// receiver credential that no longer exists and origins that no longer
// resolve, so replaying through it is refused before the first Fountain call.
function workspace(t, baseUrl, ownerId) {
  const dir = mkdtempSync(join(tmpdir(), 'fountain-cleanup-after-receiver-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const resultsRoot = join(dir, 'results');
  mkdirSync(resultsRoot, { recursive: true });
  // A fixture's name carries the run that owns it; cleanup checks that before
  // deleting anything.
  const runId = randomUUID();
  const leftover = { kind: 'environment', id: randomUUID(), name: `suite-${runId}-environment-0`, state: 'created' };
  writeFileSync(join(resultsRoot, 'cleanup.json'), JSON.stringify(
    { version: 1, run_id: runId, base_url: baseUrl, owner_id: ownerId, resources: [leftover] }));
  return { dir, resultsRoot, leftover, runId };
}

// The target a secrets run composes: the profile, the receiver block and the
// generated credential's variable name.
const ranTarget = baseUrl => ({
  base_url: baseUrl,
  credentials: { primary: 'SUITE_TEST_KEY', secondary: 'SUITE_OTHER_KEY' },
  profiles: ['secrets'],
  limits: { request_ms: 30000, run_ms: 420000, cleanup_ms: 90000, resources: 12 },
  execution: { runtime: 'claude', model: 'anthropic/claude-haiku-4-5', sandbox_provider: 'sprites',
    sandbox_mode: 'ephemeral', provision_ms: 120000, turn_ms: 90000, max_turns: 1 },
  secrets: { allowed_url: 'https://gone-allowed.trycloudflare.com/', blocked_url: 'https://gone-blocked.trycloudflare.com/',
    admin_credential: 'FOUNTAIN_RECEIVER_ADMIN_KEY', bootstrap_hosts: ['registry.npmjs.org'] },
});

async function fountain(t, ownerId, key) {
  const requests = [], deleted = [];
  // Cleanup re-reads each resource and refuses to delete one whose name does
  // not match the manifest, so the stub has to carry that ownership evidence.
  const live = new Map();
  const server = createServer((req, res) => {
    requests.push([req.method, req.url]);
    let status = 404, body = { error: 'not_found' };
    if (req.url === '/api/auth/me') {
      status = 200; body = { id: ownerId, email: 'suite@example.test', email_verified: true, role: 'user' };
    } else if (req.url.startsWith('/api/environments/')) {
      const id = req.url.split('/').at(-1);
      if (live.has(id)) {
        if (req.method === 'DELETE') { deleted.push(id); live.delete(id); status = 204; body = undefined; }
        else { status = 200; body = { data: live.get(id) }; }
      }
    }
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(body && JSON.stringify(body));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  return { baseUrl: `http://127.0.0.1:${server.address().port}`, requests, deleted, live };
}

test('the run target cannot replay cleanup once its receiver is gone', async t => {
  const ownerId = randomUUID(), key = randomUUID();
  const api = await fountain(t, ownerId, key);
  const w = workspace(t, api.baseUrl, ownerId);
  api.live.set(w.leftover.id, { id: w.leftover.id, name: w.leftover.name });
  const configPath = join(w.dir, 'target.json');
  writeFileSync(configPath, JSON.stringify(ranTarget(api.baseUrl)));

  // The receiver has stopped, so its generated credential is gone with it.
  const code = await replayCleanup({ configPath, resultsRoot: w.resultsRoot, out: join(w.dir, 'replay'),
    env: { SUITE_TEST_KEY: key, SUITE_OTHER_KEY: randomUUID() } });
  assert.notEqual(code, 0, 'replay cannot succeed through a stopped receiver');
  assert.deepEqual(api.requests, [], 'it never reaches a Fountain call, so the fixture survives');
  assert.equal(api.live.has(w.leftover.id), true);
});

test('the cleanup target written beside it deletes the leftover fixture', async t => {
  const ownerId = randomUUID(), key = randomUUID();
  const api = await fountain(t, ownerId, key);
  const w = workspace(t, api.baseUrl, ownerId);
  api.live.set(w.leftover.id, { id: w.leftover.id, name: w.leftover.name });

  const configPath = join(w.dir, 'cleanup-target.json');
  writeFileSync(configPath, JSON.stringify(cleanupTarget(ranTarget(api.baseUrl))));

  const code = await replayCleanup({ configPath, resultsRoot: w.resultsRoot, out: join(w.dir, 'replay'),
    env: { SUITE_TEST_KEY: key, SUITE_OTHER_KEY: randomUUID() } });
  assert.deepEqual(api.deleted, [w.leftover.id], 'the run-owned fixture is deleted');
  assert.equal(api.live.has(w.leftover.id), false);
  assert.equal(code, 0);
});

test('a cleanup target keeps the instance and account, and drops what a receiver owns', () => {
  const target = cleanupTarget(ranTarget('https://example.test'));
  assert.equal(target.base_url, 'https://example.test');
  assert.deepEqual(target.credentials, { primary: 'SUITE_TEST_KEY', secondary: 'SUITE_OTHER_KEY' });
  assert.equal(target.secrets, undefined, 'a stopped receiver cannot be reached, so it is not required');
  assert.equal(target.execution, undefined, 'cleanup runs no turn');
  assert.deepEqual(target.profiles, ['probe'], 'the manifest drives cleanup, not the profile');
});

// A real run writes a receiver journal beside cleanup.json. Cleanup mode
// schedules receiver cleanup whenever one exists, and used to demand the
// receiver configuration even when the journal said there was nothing left to
// do — so a replay through the receiver-free cleanup target deleted every
// fixture and still exited 3, permanently.
const journal = (resultsRoot, runId, state) => writeFileSync(join(resultsRoot, 'mcp-receiver.json'),
  JSON.stringify({ version: MCP_VERSION, run_id: runId, base_url: 'https://gone-mcp.trycloudflare.com', state }));

for (const state of TERMINAL) {
  test(`replay succeeds with a ${state} receiver journal beside the manifest`, async t => {
    const ownerId = randomUUID(), key = randomUUID();
    const api = await fountain(t, ownerId, key);
    const w = workspace(t, api.baseUrl, ownerId);
    api.live.set(w.leftover.id, { id: w.leftover.id, name: w.leftover.name });
    journal(w.resultsRoot, w.runId, state);

    const configPath = join(w.dir, 'cleanup-target.json');
    writeFileSync(configPath, JSON.stringify(cleanupTarget(ranTarget(api.baseUrl))));
    const code = await replayCleanup({ configPath, resultsRoot: w.resultsRoot, out: join(w.dir, 'replay'),
      env: { SUITE_TEST_KEY: key, SUITE_OTHER_KEY: randomUUID() } });
    assert.deepEqual(api.deleted, [w.leftover.id], 'the fixture is deleted');
    assert.equal(code, 0, 'and the replay reports success rather than owing a stopped receiver');
  });
}

// The obligation survives for a receiver the operator hosts: it is still
// reachable, so its records still have to go.
test('an unsettled journal still demands the receiver configuration', async t => {
  const ownerId = randomUUID(), key = randomUUID();
  const api = await fountain(t, ownerId, key);
  const w = workspace(t, api.baseUrl, ownerId);
  api.live.set(w.leftover.id, { id: w.leftover.id, name: w.leftover.name });
  journal(w.resultsRoot, w.runId, 'created');

  const configPath = join(w.dir, 'cleanup-target.json');
  writeFileSync(configPath, JSON.stringify(cleanupTarget(ranTarget(api.baseUrl))));
  const code = await replayCleanup({ configPath, resultsRoot: w.resultsRoot, out: join(w.dir, 'replay'),
    env: { SUITE_TEST_KEY: key, SUITE_OTHER_KEY: randomUUID() } });
  assert.notEqual(code, 0, 'a receiver that may still hold run records is not silently forgiven');
});

test('a journal is settled only for this run, and only in a terminal state', () => {
  const dir = mkdtempSync(join(tmpdir(), 'fountain-journal-'));
  try {
    const runId = randomUUID(), path = join(dir, 'mcp-receiver.json');
    for (const [state, settled] of [['cleaned', true], ['discarded', true], ['created', false], ['pending', false]]) {
      writeFileSync(path, JSON.stringify({ version: MCP_VERSION, run_id: runId, state }));
      assert.equal(journalSettled(path, runId), settled, state);
    }
    // Another run's journal, a malformed one and a missing one all owe work.
    writeFileSync(path, JSON.stringify({ version: MCP_VERSION, run_id: randomUUID(), state: 'cleaned' }));
    assert.equal(journalSettled(path, runId), false, 'a different run');
    writeFileSync(path, 'not json');
    assert.equal(journalSettled(path, runId), false, 'unreadable');
    assert.equal(journalSettled(join(dir, 'absent.json'), runId), false, 'missing');

    // Discarding records a stopped receiver, and never overwrites a verdict.
    writeFileSync(path, JSON.stringify({ version: MCP_VERSION, run_id: runId, state: 'created' }));
    assert.equal(discardJournal(path, runId), true);
    assert.equal(JSON.parse(readFileSync(path, 'utf8')).state, 'discarded');
    writeFileSync(path, JSON.stringify({ version: MCP_VERSION, run_id: runId, state: 'cleaned' }));
    assert.equal(discardJournal(path, runId), false, 'a cleaned journal keeps its own verdict');
    assert.equal(JSON.parse(readFileSync(path, 'utf8')).state, 'cleaned');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
