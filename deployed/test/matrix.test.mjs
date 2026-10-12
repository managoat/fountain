import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, basename } from 'node:path';
import { randomUUID } from 'node:crypto';
import { validateMatrix, compareCatalog, runMatrix } from '../matrix.mjs';
import { ciConfig } from '../ci.mjs';

const example = () => JSON.parse(readFileSync(new URL('../matrix.example.json', import.meta.url)));
const catalog = { runtimes: ['claude', 'codex', 'gemini'], sandbox_providers: ['runner'] };

test('matrix declares both modes, bounded subsets, and linked intentional gaps', () => {
  assert.equal(validateMatrix(example(), 'canary').length, 1);
  assert.equal(validateMatrix(example(), 'scheduled').length, 2);
  for (const mutate of [
    m => m.cells.pop(), m => m.cells.push({ ...m.cells[0], id: 'duplicate' }),
    m => m.catalog_gaps.runtimes[0].issue = '', m => m.subsets.canary.push('not-declared'),
    m => m.limits.max_turns = 1, m => m.limits.run_ms = 3000001,
    m => m.cells[0].capabilities = ['artifact'], m => m.cells[0].status = 'gap',
    m => m.subsets.full.pop(), m => m.version = 2,
  ]) {
    const m = example(); mutate(m); assert.throws(() => validateMatrix(m, 'full'));
  }
});

test('catalog cannot shrink required coverage or silently gain an untested runtime', () => {
  compareCatalog(example(), catalog);
  assert.throws(() => compareCatalog(example(), { ...catalog, sandbox_providers: [] }), /disappeared/);
  assert.throws(() => compareCatalog(example(), { ...catalog, runtimes: [...catalog.runtimes, 'future-runtime'] }), /undeclared/);
});

function setup(t) {
  const root = mkdtempSync(join(tmpdir(), 'fountain-matrix-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const configPath = join(root, 'target.json'), matrixPath = join(root, 'matrix.json'), out = join(root, 'results');
  const env = { KEY: randomUUID(), OTHER: randomUUID() };
  writeFileSync(configPath, JSON.stringify({ base_url: 'https://example.test', credentials: { primary: 'KEY', secondary: 'OTHER' } }));
  writeFileSync(matrixPath, JSON.stringify(example()));
  const calls = [], paths = [];
  const fake = overrides => async ({ configPath: path, out: dir, signal }) => {
    signal.throwIfAborted();
    paths.push(path);
    const config = JSON.parse(readFileSync(path));
    const id = basename(dir); calls.push({ id, config });
    mkdirSync(dir);
    const result = { suite_revision: 'test-revision', suite_dirty: false, status: 'passed', capabilities: catalog,
      cleanup: { remaining: 0, failures: [] }, inference_attempts: id === 'preflight' ? 0 : 2,
      execution: { usage_total: { input: 7, output: 3 }, versions: { runtime: { available: false } } },
      ...overrides?.(id) };
    writeFileSync(join(dir, 'result.json'), JSON.stringify(result));
    return result.status === 'passed' ? 0 : result.status === 'cleanup_failed' ? 3 : 1;
  };
  return { configPath, matrixPath, out, env, subset: 'scheduled', calls, paths, fake, result: () => JSON.parse(readFileSync(join(out, 'result.json'))) };
}

test('matrix reuses execution sequentially with separate budgets and per-cell evidence', async t => {
  const s = setup(t);
  assert.equal(await runMatrix({ ...s, execute: s.fake() }), 0);
  assert.deepEqual(s.calls.map(c => c.id), ['preflight', 'codex-runner-ephemeral', 'codex-runner-persistent']);
  assert.deepEqual(s.calls.slice(1).map(c => c.config.execution.sandbox_mode), ['ephemeral', 'persistent']);
  assert.ok(s.calls.slice(1).every(c => c.config.execution.max_turns === 2 && c.config.limits.resources === 3));
  const result = s.result();
  assert.equal(result.inference_attempts, 4);
  assert.equal(result.cells[1].usage.input, 7);
  assert.equal(result.matrix_sha256.length, 64);
  assert.equal(result.suite_revision, 'test-revision');
  assert.ok(s.paths.every(path => !existsSync(path)), 'temporary configurations are removed');
});

test('a healthy later cell does not hide an earlier cell assertion failure', async t => {
  const s = setup(t);
  assert.equal(await runMatrix({ ...s, execute: s.fake(id => id.endsWith('ephemeral') ? { status: 'failed' } : {}) }), 1);
  assert.equal(s.calls.length, 3);
  assert.deepEqual(s.result().cells.map(c => c.status), ['failed', 'passed']);
});

test('cleanup failure stops before another sandbox can be provisioned', async t => {
  const s = setup(t);
  assert.equal(await runMatrix({ ...s, execute: s.fake(id => id.endsWith('ephemeral') ? { status: 'cleanup_failed', cleanup: { remaining: 3, failures: ['leak'] } } : {}) }), 3);
  assert.equal(s.calls.length, 2);
  assert.deepEqual(s.result().cells.map(c => c.status), ['cleanup_failed', 'not_run']);
});

test('preflight detects disappeared required provider before any execution', async t => {
  const s = setup(t);
  assert.equal(await runMatrix({ ...s, execute: s.fake(() => ({ capabilities: { ...catalog, sandbox_providers: [] } })) }), 2);
  assert.equal(s.calls.length, 1);
  assert.ok(s.result().checks.some(c => c.error?.includes('disappeared')));
});

test('all credentials and budgets are checked before even preflight runs', async t => {
  const s = setup(t);
  assert.equal(await runMatrix({ ...s, env: { KEY: s.env.KEY }, execute: s.fake() }), 2);
  assert.equal(s.calls.length, 0);
  assert.ok(!readFileSync(join(s.out, 'result.json'), 'utf8').includes(s.env.KEY));
});

test('cancellation stops the matrix and preserves every required cell verdict', async t => {
  const s = setup(t);
  const controller = new AbortController(); controller.abort();
  assert.equal(await runMatrix({ ...s, signal: controller.signal, execute: s.fake() }), 130);
  assert.equal(s.calls.length, 0);
  assert.equal(s.result().cells.filter(c => c.status === 'not_run').length, 2);
});

test('CI exposes declared matrix profiles without changing target approval or rollout verification', () => {
  for (const profile of ['matrix-canary', 'matrix-scheduled', 'matrix-full']) {
    const env = { SUITE_TARGET: 'staging', SUITE_ENABLED: 'true', SUITE_PROFILE: profile, SUITE_MODE: 'public', SUITE_TARGET_JSON: '{"base_url":"https://example.test"}' };
    assert.deepEqual(ciConfig(env).profiles, ['probe']);
    assert.throws(() => ciConfig({ ...env, SUITE_TARGET: 'arbitrary' }), /approved/);
    assert.throws(() => ciConfig({ ...env, SUITE_MODE: 'rollout' }), /adapter/);
  }
});

test('missing cell result retains the prompt reservation and an incomplete cleanup verdict', async t => {
  const s = setup(t);
  const preflight = s.fake();
  const execute = async args => {
    if (basename(args.out) === 'preflight') return preflight(args);
    throw new Error('Cell failed before its final evidence could be written');
  };
  assert.equal(await runMatrix({ ...s, execute }), 1);
  assert.deepEqual(s.result().cells.map(c => c.status), ['incomplete', 'not_run']);
  assert.equal(s.result().reserved_turns, 2);
  assert.equal(s.result().usage_complete, false);
  assert.equal(s.result().cells[0].inference_attempts, null);
});
