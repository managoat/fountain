#!/usr/bin/env node
import { readFileSync, mkdirSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { run, configFrom, writeReport } from './lib/runner.mjs';
import { Redactor } from './lib/http.mjs';

const ensure = (ok, message) => { if (!ok) throw new Error(message); };
const keys = (value, allowed) => value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).every(k => allowed.includes(k));
const unique = values => new Set(values).size === values.length;
// Either owner: the repo moved to managoat (0048) and a matrix.json written
// before that still cites issues under the old account, which redirect.
const issue = value => typeof value === 'string' && /^https:\/\/github\.com\/(?:managoat|BinaryBourbon)\/fountain\/issues\/[1-9][0-9]*$/.test(value);
const capabilities = ['execution', 'artifact', 'follow_up', 'tenant_isolation', 'lifecycle', 'streaming'];

export function validateMatrix(matrix, subset) {
  ensure(keys(matrix, ['version', 'cells', 'subsets', 'catalog_gaps', 'limits']) && matrix.version === 1, 'Expected matrix version 1');
  ensure(Array.isArray(matrix.cells) && matrix.cells.length > 0 && matrix.cells.length <= 100, 'Expected bounded matrix cells');
  for (const cell of matrix.cells) {
    ensure(keys(cell, ['id', 'runtime', 'model', 'sandbox_provider', 'sandbox_mode', 'status', 'capabilities', 'reason', 'issue']) &&
      /^[a-z0-9][a-z0-9-]{0,79}$/.test(cell.id), 'Invalid matrix cell');
    ensure(['claude', 'codex', 'gemini'].includes(cell.runtime) &&
      ['sprites', 'e2b', 'runner', 'render'].includes(cell.sandbox_provider) &&
      ['ephemeral', 'persistent'].includes(cell.sandbox_mode), 'Unknown matrix combination');
    if (cell.status === 'supported') {
      ensure(cell.sandbox_provider !== 'render', 'Render remains a declared gap until #1439 verifies its execution contract');
      ensure(typeof cell.model === 'string' && /^[a-z0-9_-]+\/[a-z0-9._-]+$/.test(cell.model), 'Supported cells require a pinned model');
      ensure(Array.isArray(cell.capabilities) && unique(cell.capabilities) &&
        capabilities.slice(0, 5).every(c => cell.capabilities.includes(c)) && cell.capabilities.every(c => capabilities.includes(c)), 'Supported cell capabilities must include the shared execution contract');
    } else ensure(cell.status === 'gap' && typeof cell.reason === 'string' && cell.reason.trim() && issue(cell.issue), 'Intentional gaps require a reason and issue');
  }
  ensure(unique(matrix.cells.map(c => c.id)), 'Duplicate matrix cell ID');
  ensure(unique(matrix.cells.map(c => [c.runtime, c.sandbox_provider, c.sandbox_mode].join('/'))), 'Duplicate matrix combination');
  // Every declared axis pair/mode needs an explicit verdict. Discovery never
  // chooses a smaller Cartesian product on the operator's behalf.
  for (const runtime of new Set(matrix.cells.map(c => c.runtime))) {
    for (const provider of new Set(matrix.cells.map(c => c.sandbox_provider))) {
      for (const mode of ['ephemeral', 'persistent']) ensure(matrix.cells.some(c => c.runtime === runtime && c.sandbox_provider === provider && c.sandbox_mode === mode), 'Matrix leaves an undeclared combination');
    }
  }
  ensure(keys(matrix.catalog_gaps, ['runtimes', 'sandbox_providers']), 'Expected explicit catalog gap lists');
  for (const kind of ['runtimes', 'sandbox_providers']) {
    const entries = matrix.catalog_gaps[kind];
    ensure(Array.isArray(entries) && unique(entries.map(e => e.name)) && entries.every(e =>
      keys(e, ['name', 'reason', 'issue']) && typeof e.name === 'string' && e.name.length > 0 && typeof e.reason === 'string' && e.reason.trim() && issue(e.issue)), 'Catalog gaps require unique names, reasons and issues');
    const field = kind === 'runtimes' ? 'runtime' : 'sandbox_provider';
    ensure(entries.every(e => !matrix.cells.some(c => c[field] === e.name)), 'Catalog gap overlaps a declared matrix axis');
  }
  ensure(keys(matrix.subsets, ['canary', 'scheduled', 'full']), 'Unknown matrix subset');
  for (const name of ['canary', 'scheduled', 'full']) {
    const ids = matrix.subsets[name];
    ensure(Array.isArray(ids) && ids.length > 0 && ids.length <= (name === 'canary' ? 2 : 16) && unique(ids) &&
      ids.every(id => matrix.cells.some(c => c.id === id && c.status === 'supported')), 'Subsets must explicitly select supported cells within the bound');
  }
  ensure(matrix.subsets.canary.every(id => matrix.subsets.scheduled.includes(id)) &&
    matrix.subsets.scheduled.every(id => matrix.subsets.full.includes(id)) &&
    matrix.cells.filter(c => c.status === 'supported').every(c => matrix.subsets.full.includes(c.id)), 'Full must cover all supported cells; scheduled must include canary');
  ensure(Object.hasOwn(matrix.subsets, subset), 'Unknown matrix subset selection');
  ensure(keys(matrix.limits, ['max_turns', 'run_ms']) && Number.isSafeInteger(matrix.limits.max_turns) &&
    matrix.limits.max_turns >= matrix.subsets[subset].length * 2 && matrix.limits.max_turns <= 32 &&
    Number.isSafeInteger(matrix.limits.run_ms) && matrix.limits.run_ms > 0 && matrix.limits.run_ms <= 3000000, 'Matrix requires an explicit prompt and wall-clock budget');
  return matrix.subsets[subset].map(id => matrix.cells.find(c => c.id === id));
}

export function requiredCatalog(matrix) {
  const supported = matrix.cells.filter(c => c.status === 'supported');
  return { runtimes: [...new Set(supported.map(c => c.runtime))], sandbox_providers: [...new Set(supported.map(c => c.sandbox_provider))] };
}

export function compareCatalog(matrix, catalog) {
  for (const [kind, required] of Object.entries(requiredCatalog(matrix))) {
    ensure(Array.isArray(catalog?.[kind]), 'Catalog capability array missing');
    for (const name of required) ensure(catalog[kind].includes(name), `Required matrix ${kind} disappeared: ${name}`);
    const field = kind === 'runtimes' ? 'runtime' : 'sandbox_provider';
    for (const name of catalog[kind]) ensure(matrix.cells.some(c => c[field] === name) || matrix.catalog_gaps[kind].some(e => e.name === name), `Catalog ${kind} has undeclared coverage: ${name}`);
  }
}

export async function runMatrix({ configPath, matrixPath, subset, out, env = process.env, signal, execute = run }) {
  mkdirSync(out, { mode: 0o700 });
  const redactor = new Redactor();
  const report = { suite_version: '0.1.0', mode: 'matrix', subset, started_at: new Date().toISOString(), status: 'setup_failed', checks: [], cells: [], inference_attempts: 0, reserved_turns: 0, usage_complete: true };
  const save = () => writeReport(out, report, redactor);
  let selected = [], configDir;
  try {
    const bytes = readFileSync(matrixPath);
    const matrix = JSON.parse(bytes);
    selected = validateMatrix(matrix, subset);
    report.matrix_sha256 = createHash('sha256').update(bytes).digest('hex');
    report.matrix_version = matrix.version;
    report.limits = { ...matrix.limits, concurrency: 1, selected_turn_limit: selected.length * 2 };
    report.gaps = { cells: matrix.cells.filter(c => c.status === 'gap'), catalog: matrix.catalog_gaps };
    report.cells = selected.map(cell => ({ ...cell, status: 'not_run', inference_attempts: 0 }));
    save();
    const base = JSON.parse(readFileSync(configPath));
    for (const name of Object.values(base.credentials ?? {})) redactor.add(env[name]);
    if (base.contract) base.contract = resolve(dirname(configPath), base.contract);
    delete base.execution;
    const required = requiredCatalog(matrix);
    for (const kind of Object.keys(required)) required[kind] = [...new Set([...required[kind], ...(base.required_capabilities?.[kind] ?? [])])];
    base.required_capabilities = required;
    const configs = [{ id: 'preflight', config: { ...base, profiles: ['probe'] } }, ...selected.map(cell => ({ id: cell.id, config: { ...base,
      profiles: [cell.capabilities.includes('streaming') ? 'streaming' : 'execution'],
      execution: { runtime: cell.runtime, model: cell.model, sandbox_provider: cell.sandbox_provider, sandbox_mode: cell.sandbox_mode, max_turns: 2, provision_ms: 120000, turn_ms: 90000 },
      limits: { request_ms: 30000, run_ms: 420000, cleanup_ms: 90000, resources: 3 } } }))];
    configDir = mkdtempSync(join(tmpdir(), 'fountain-matrix-config-'));
    // Validate all configurations and credentials before the first public run.
    for (const entry of configs) {
      entry.path = resolve(configDir, `${entry.id}.target.json`);
      writeFileSync(entry.path, JSON.stringify(entry.config), { mode: 0o600, flag: 'wx' });
      configFrom(entry.path, env);
    }
    const deadline = AbortSignal.timeout(matrix.limits.run_ms);
    const combined = signal ? AbortSignal.any([signal, deadline]) : deadline;
    const executeCell = async entry => {
      combined.throwIfAborted();
      const resultDir = resolve(out, entry.id);
      const code = await execute({ configPath: entry.path, out: resultDir, env, signal: combined });
      return { code, result: JSON.parse(readFileSync(resolve(resultDir, 'result.json'))) };
    };
    const preflight = await executeCell(configs[0]);
    report.suite_revision = preflight.result.suite_revision;
    report.suite_dirty = preflight.result.suite_dirty;
    report.capabilities = preflight.result.capabilities;
    ensure(preflight.code === 0 && preflight.result.status === 'passed', 'Matrix preflight failed; no cells started');
    compareCatalog(matrix, report.capabilities);
    report.checks.push({ name: 'matrix/catalog', status: 'passed', duration_ms: 0 });
    report.status = 'running';
    save();
    for (const [index, entry] of configs.slice(1).entries()) {
      combined.throwIfAborted();
      const cell = report.cells[index];
      Object.assign(cell, { status: 'running', evidence: `${entry.id}/result.json` });
      report.reserved_turns += 2;
      save(); // A missing result must not make started work look unattempted.
      const started = performance.now();
      const { code, result } = await executeCell(entry);
      Object.assign(cell, { status: result.status, evidence: `${entry.id}/result.json`, cleanup: result.cleanup,
        inference_attempts: result.inference_attempts ?? 0, usage: result.execution?.usage_total ?? null,
        versions: result.execution?.versions ?? null, lifecycle: result.execution?.lifecycle ?? null, revision: result.revision });
      report.inference_attempts += cell.inference_attempts;
      report.checks.push({ name: `matrix/${cell.id}`, status: code === 0 && result.status === 'passed' ? 'passed' : 'failed', duration_ms: performance.now() - started,
        ...(code === 0 && result.status === 'passed' ? {} : { error: `Cell ${cell.status}; see per-cell evidence` }) });
      save();
      ensure(report.inference_attempts <= matrix.limits.max_turns, 'Matrix prompt budget exceeded');
      if (result.status === 'cleanup_failed' || result.cleanup?.remaining > 0) {
        report.status = 'cleanup_failed';
        throw new Error('Matrix stopped because a cell left owned resources');
      }
    }
    report.status = report.checks.some(c => c.status === 'failed') ? 'failed' : 'passed';
  } catch (error) {
    if (report.status === 'running') report.status = 'failed';
    for (const cell of report.cells.filter(c => c.status === 'running')) {
      Object.assign(cell, { status: 'incomplete', inference_attempts: null, cleanup: { verified: false } });
      report.usage_complete = false;
      report.checks.push({ name: `matrix/${cell.id}`, status: 'failed', error: 'Started cell has no final result; inspect its evidence and cleanup manifest', duration_ms: 0 });
    }
    report.checks.push({ name: 'matrix/run', status: 'failed', error: redactor.text(error.message), duration_ms: 0 });
  } finally {
    if (configDir) rmSync(configDir, { recursive: true, force: true });
    for (const cell of report.cells.filter(c => c.status === 'not_run')) {
      report.checks.push({ name: `matrix/${cell.id}`, status: 'skipped', reason: 'Matrix stopped before this required cell; overall run is unsuccessful', duration_ms: 0 });
    }
    report.finished_at = new Date().toISOString();
    save();
  }
  return signal?.aborted ? 130 : { passed: 0, failed: 1, setup_failed: 2, cleanup_failed: 3 }[report.status];
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const controller = new AbortController();
  const cancel = () => controller.abort(new Error('Interrupted'));
  process.on('SIGINT', cancel); process.on('SIGTERM', cancel);
  try {
    const { values } = parseArgs({ options: { config: { type: 'string' }, matrix: { type: 'string' }, subset: { type: 'string' }, out: { type: 'string' } } });
    ensure(['config', 'matrix', 'subset', 'out'].every(k => values[k]), 'Usage: node deployed/matrix.mjs --config target.json --matrix matrix.json --subset canary|scheduled|full --out NEW_DIR');
    process.exitCode = await runMatrix({ configPath: resolve(values.config), matrixPath: resolve(values.matrix), subset: values.subset, out: resolve(values.out), signal: controller.signal });
  } catch { console.error('Matrix setup failed; verify arguments and configuration'); process.exitCode = 2; }
  finally { process.off('SIGINT', cancel); process.off('SIGTERM', cancel); }
}
