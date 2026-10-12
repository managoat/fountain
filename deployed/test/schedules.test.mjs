import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Fixtures } from '../lib/fixtures.mjs';
import { scheduleTime, createSchedule, armSchedule, discoverScheduledConversations, validateScheduleManifest } from '../lib/scheduled-fixtures.mjs';
import { verifyFiredSchedule, verifyScheduledTurn } from '../profiles/schedules.mjs';
import { configFrom } from '../lib/runner.mjs';
import { ciConfig } from '../ci.mjs';

function temporary(t) { const dir = mkdtempSync(join(tmpdir(), 'fountain-schedule-test-')); t.after(() => rmSync(dir, { force: true, recursive: true })); return dir; }
async function fixture(t, opts = {}) {
  const dir = temporary(t), runId = randomUUID(), ownerId = randomUUID(), rows = new Map(), calls = [], conversations = [], sandboxes = [];
  const timing = scheduleTime(); let schedule;
  const client = { baseUrl: 'https://fountain.example.test', async request(method, path, options = {}) {
    calls.push({ method, path, body: options.body });
    if (path.includes('/schedules')) {
      if (method === 'POST') {
        schedule = { ...options.body, id: randomUUID(), agent_id: path.split('/')[3], next_run_at: timing.due_at, last_run_at: null, last_conversation_id: null, last_error: null };
        if (opts.loseCreate) throw new Error('create reply lost');
        return { status: 201, body: { data: schedule } };
      }
      if (method === 'GET') return path.endsWith('/schedules') ? { status: 200, body: { data: schedule ? [schedule] : [] } } :
        schedule ? { status: 200, body: { data: { ...schedule } } } : { status: 404 };
      if (method === 'PATCH') {
        if (options.body.enabled === false && opts.failDisable) throw new Error('disable failed');
        Object.assign(schedule, options.body);
        if (options.body.enabled && opts.loseEnable) throw new Error('enable reply lost');
        return { status: 200, body: { data: { ...schedule } } };
      }
      if (opts.failDelete) throw new Error('delete failed');
      schedule = undefined; return { status: 204 };
    }
    if (path.startsWith('/api/conversations?')) return { status: 200, body: { data: conversations.map(c => ({ ...c })) } };
    if (path === '/api/sandboxes') return { status: 200, body: { data: sandboxes } };
    if (path.startsWith('/api/sandboxes/')) return { status: 200, body: { data: sandboxes.find(s => path.endsWith(s.id)) } };
    if (path.startsWith('/api/conversations/')) {
      const id = path.split('/')[3], index = conversations.findIndex(c => c.id === id), value = conversations[index];
      if (method === 'GET') return value ? { status: 200, body: { data: { ...value } } } : { status: 404 };
      if (method === 'POST') { value.status = 'terminated'; value.sandbox.status = 'terminated'; return { status: 204 }; }
      conversations.splice(index, 1); return { status: 204 };
    }
    if (method === 'POST') { const value = { ...options.body, id: randomUUID() }; rows.set(`${path}/${value.id}`, value); return { status: 201, body: { data: value } }; }
    if (method === 'GET') return rows.has(path) ? { status: 200, body: { data: rows.get(path) } } : { status: 404 };
    rows.delete(path); return { status: 204 };
  } };
  const fixtures = new Fixtures(join(dir, 'cleanup.json'), client, { runId, ownerId, baseUrl: client.baseUrl, maxResources: 4 });
  const environment = await fixtures.create('environment');
  const agent = await fixtures.create('agent', { environment_id: environment.id, sandbox_mode: 'ephemeral' });
  const create = () => createSchedule(fixtures, { agentId: agent.id, environmentId: environment.id, prompt: 'bounded fixture nonce', ...timing });
  const spawn = () => {
    const sandbox = { id: randomUUID(), agent_id: agent.id, environment_id: environment.id, vault_id: null, mode: 'ephemeral', status: 'ready' };
    sandboxes.push(sandbox);
    const value = { id: randomUUID(), agent_id: agent.id, environment_id: null, channel_id: null, parent_conversation_id: null, vault_id: null, sandbox_id: sandbox.id, sandbox, status: 'idle' };
    conversations.push(value); return value;
  };
  return { fixtures, client, ownerId, create, spawn, calls, conversations, sandboxes, agent, environment, rows, timing, schedule: () => schedule };
}

test('date-specific UTC schedule stays at least two minutes ahead across year/month boundaries', () => {
  for (const now of ['2026-12-31T23:59:30Z', '2028-02-28T23:59:50Z', '2026-09-06T12:00:00Z']) {
    const timing = scheduleTime(Date.parse(now)), due = new Date(timing.due_at), delta = +due - Date.parse(now);
    assert.ok(delta >= 120000 && delta < 180000);
    assert.equal(due.getUTCSeconds(), 0);
    assert.equal(timing.cron, `${due.getUTCMinutes()} ${due.getUTCHours()} ${due.getUTCDate()} ${due.getUTCMonth() + 1} *`);
  }
});

test('schedule is created disabled and a lost enable reply consumes its single authorization', async t => {
  const f = await fixture(t, { loseEnable: true });
  await f.create(); assert.equal(f.schedule().enabled, false);
  assert.equal(f.fixtures.manifest.inference_attempts, undefined);
  await assert.rejects(armSchedule(f.fixtures), /enable reply lost/);
  const persisted = JSON.parse(readFileSync(f.fixtures.path));
  assert.equal(persisted.inference_attempts, 1); assert.equal(persisted.schedule.armed, true);
  await assert.rejects(armSchedule(f.fixtures), /already authorized/);
  const posts = f.calls.filter(c => c.method === 'POST');
  assert.ok(posts.every(c => !c.path.endsWith('/run') && !c.path.includes('/prompts')));
});

test('scheduled conversation cleanup recovers a lost create response and still deletes after disable failure', async t => {
  const f = await fixture(t, { loseCreate: true, failDisable: true });
  await assert.rejects(f.create(), /create reply lost/);
  const loaded = Fixtures.load(f.fixtures.path, f.client, f.ownerId);
  assert.deepEqual(await loaded.cleanup(AbortSignal.timeout(10000)), []);
  assert.equal(loaded.remainingCount(), 0); assert.equal(f.schedule(), undefined);
  const patch = f.calls.findIndex(c => c.method === 'PATCH');
  const deletion = f.calls.findIndex(c => c.method === 'DELETE' && c.path.includes('/schedules/'));
  assert.ok(patch >= 0 && deletion > patch);
});

test('cleanup adopts duplicate scheduler-created conversations and stops source before turns or parents', async t => {
  const f = await fixture(t); await f.create(); await armSchedule(f.fixtures);
  f.spawn(); f.spawn();
  assert.equal((await discoverScheduledConversations(f.fixtures)).length, 2);
  const loaded = Fixtures.load(f.fixtures.path, f.client, f.ownerId);
  assert.deepEqual(await loaded.cleanup(AbortSignal.timeout(10000)), []);
  assert.equal(loaded.manifest.schedule.conversations.length, 2);
  assert.equal(loaded.remainingCount(), 0);
  const source = f.calls.findIndex(c => c.method === 'DELETE' && c.path.includes('/schedules/'));
  const terminate = f.calls.findIndex(c => c.method === 'POST' && c.path.endsWith('/terminate'));
  const parent = f.calls.findIndex(c => c.method === 'DELETE' && c.path.startsWith('/api/agents/'));
  assert.ok(source < terminate && terminate < parent);
});

test('source deletion failure still stops existing execution and retains its owned parents', async t => {
  const f = await fixture(t, { failDelete: true }); await f.create(); f.spawn();
  const errors = await f.fixtures.cleanup(AbortSignal.timeout(5000));
  assert.ok(errors.some(e => e.error === 'delete failed'));
  assert.equal(f.conversations.length, 0);
  assert.ok(f.fixtures.manifest.resources.every(r => r.state === 'created'));
  assert.ok(errors.filter(e => e.error.includes('Retaining parent')).length === 2);
});

test('cleanup flags orphan live sandboxes and refuses changed parent or conversation ownership', async t => {
  const f = await fixture(t); await f.create();
  f.sandboxes.push({ id: randomUUID(), agent_id: f.agent.id, status: 'ready' });
  const errors = await f.fixtures.cleanup(AbortSignal.timeout(10000));
  assert.ok(errors.some(e => e.error.includes('live sandbox')));
  assert.equal(f.fixtures.manifest.schedule.remaining_sandbox_ids.length, 1);
  assert.ok(f.fixtures.manifest.resources.every(r => r.state === 'created'));
  const g = await fixture(t); await g.create();
  const conv = g.spawn(); conv.environment_id = g.environment.id;
  await assert.rejects(discoverScheduledConversations(g.fixtures), /outside.*ownership/);
  conv.environment_id = null;
  g.agent.name = 'changed-owner-marker';
  await assert.rejects(discoverScheduledConversations(g.fixtures), /parent ownership/);
  assert.ok(!g.calls.some(c => c.method === 'DELETE'));
});

test('schedule manifests cannot reference arbitrary parents or permit the ordinary conversation marker to disappear', async t => {
  const f = await fixture(t); await f.create();
  const data = structuredClone(f.fixtures.manifest); data.schedule.agent_id = randomUUID();
  assert.throws(() => validateScheduleManifest(data), /recorded run-owned parents/);
  const ordinary = structuredClone(f.fixtures.manifest); delete ordinary.schedule;
  ordinary.resources.push({ kind: 'conversation', id: randomUUID(), name: null, state: 'created', agent_id: f.agent.id, environment_id: f.environment.id });
  writeFileSync(f.fixtures.path, JSON.stringify(ordinary));
  assert.throws(() => Fixtures.load(f.fixtures.path, f.client, f.ownerId), /Invalid cleanup resource/);
});

test('firing evidence requires the intended UTC window, disabled cron and matching public conversation', async t => {
  const f = await fixture(t); await f.create();
  const source = f.fixtures.manifest.schedule, id = randomUUID();
  const row = { ...f.schedule(), last_conversation_id: id, last_run_at: source.due_at, next_run_at: new Date(Date.parse(source.due_at) + 365 * 86400000).toISOString() };
  verifyFiredSchedule(source, row, id, 180000);
  for (const mutate of [r => r.enabled = true, r => r.last_run_at = new Date(Date.parse(source.due_at) - 1000).toISOString(),
    r => r.last_conversation_id = randomUUID(), r => r.next_run_at = source.due_at, r => r.last_error = 'failed', r => r.one_off = false]) {
    const bad = { ...row }; mutate(bad); assert.throws(() => verifyFiredSchedule(source, bad, id, 180000));
  }
});

test('scheduled completion requires one real completed turn and a paired tool result', () => {
  const id = randomUUID(), turns = [{ id, turn_number: 1, status: 'completed', prompt: 'nonce task', exit_code: 0 }];
  const events = [{ turn_id: id, blocks: [{ kind: 'tool_use', id: 'tool', name: 'shell' }, { kind: 'tool_result', tool_id: 'tool', body: 'nonce-output', error: false }] }];
  verifyScheduledTurn(turns, events, 'nonce task', 'nonce-output', id);
  assert.throws(() => verifyScheduledTurn([...turns, ...turns], events, 'nonce task', 'nonce-output', id));
  assert.throws(() => verifyScheduledTurn(turns, [{ turn_id: id, blocks: [{ kind: 'text', body: 'nonce-output' }] }], 'nonce task', 'nonce-output', id));
  const unpaired = structuredClone(events); unpaired[0].blocks[1].tool_id = 'other';
  assert.throws(() => verifyScheduledTurn(turns, unpaired, 'nonce task', 'nonce-output', id));
});

const config = () => ({ base_url: 'https://fountain.example.test', profiles: ['schedules'], credentials: { primary: 'KEY', secondary: 'OTHER' },
  execution: { runtime: 'claude', model: 'anthropic/claude-haiku-4-5', sandbox_provider: 'runner', max_turns: 1 },
  schedules: { start_ms: 180000, observe_ms: 120000 }, limits: { run_ms: 900000, cleanup_ms: 90000, resources: 4 } });
test('scheduled profile has one authorization, independent selection and explicit bounded windows', t => {
  const path = join(temporary(t), 'target.json'), env = { KEY: randomUUID(), OTHER: randomUUID() };
  writeFileSync(path, JSON.stringify(config())); assert.equal(configFrom(path, env).execution.max_turns, 1);
  for (const change of [c => c.profiles.push('mcp'), c => c.execution.max_turns = 2, c => c.execution.sandbox_mode = 'persistent',
    c => c.schedules.observe_ms = 119999, c => c.schedules.start_ms = 59999, c => c.limits.resources = 3, c => c.limits.run_ms = 900001]) {
    const bad = config(); change(bad); writeFileSync(path, JSON.stringify(bad)); assert.throws(() => configFrom(path, env));
  }
  const ci = ciConfig({ SUITE_TARGET: 'staging', SUITE_ENABLED: 'true', SUITE_PROFILE: 'schedules', SUITE_MODE: 'public', SUITE_TARGET_JSON: JSON.stringify(config()) });
  assert.equal(ci.execution.max_turns, 1); assert.equal(ci.limits.run_ms, 900000);
});
