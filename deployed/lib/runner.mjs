import { mkdirSync, readFileSync, appendFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { observeDeployment, validateDeployment, verifyStable } from '../adapters/kubernetes.mjs';
import { Contract } from './contract.mjs';
import { Client, Redactor } from './http.mjs';
import { atomicJson, Fixtures } from './fixtures.mjs';
import { journalSettled } from './receiver-journal.mjs';
import { probe } from '../profiles/probe.mjs';
import { basic } from '../profiles/basic.mjs';
import { execution } from '../profiles/execution.mjs';
import { deterministic } from '../profiles/deterministic.mjs';
import { browser } from '../profiles/browser.mjs';
import { validateBrowser } from './browser-config.mjs';
import { recovery } from '../profiles/recovery.mjs';
import { validateRecovery, restoreRecoveryControls } from './recovery.mjs';
import { schedules } from '../profiles/schedules.mjs';
import { webhooks } from '../profiles/webhooks.mjs';
import { ControlledReceiverSession, controlledOrigin } from './controlled-receiver.mjs';
import { WEBHOOK_VERSION } from '../receivers/webhooks.mjs';
import { mcp } from '../profiles/mcp.mjs';
import { mcpOrigin, McpReceiverSession } from './mcp-receiver.mjs';
import { secrets } from '../profiles/secrets.mjs';
import { receiverOrigins, ReceiverSession } from './receiver.mjs';

export const VERSION = '0.1.0';
export const profiles = { probe, basic, execution, streaming: execution, secrets, mcp, webhooks, schedules, deterministic, recovery, browser };
const contractPath = fileURLToPath(new URL('../../sdk/contract/contract.json', import.meta.url));

function requireThat(condition, message) { if (!condition) throw new Error(message); }
function positive(value, fallback, max) {
  const n = value ?? fallback;
  requireThat(Number.isSafeInteger(n) && n > 0 && n <= max, `Expected positive integer limit <= ${max}`);
  return n;
}

export function configFrom(path, env = process.env) {
  const config = JSON.parse(readFileSync(path, 'utf8'));
  const allowed = ['base_url', 'credentials', 'profiles', 'contract', 'required_capabilities', 'optional_capabilities', 'limits', 'execution', 'deployment', 'secrets', 'mcp', 'webhooks', 'schedules', 'fixture', 'recovery', 'browser'];
  requireThat(Object.keys(config).every(key => allowed.includes(key)), 'Unknown configuration field');
  const url = new URL(config.base_url);
  requireThat(['http:', 'https:'].includes(url.protocol) && !url.username && !url.password && !url.search && !url.hash,
    'base_url must be an HTTP(S) URL without credentials, query, or fragment');
  config.base_url = url.href.replace(/\/$/, '');
  requireThat(config.credentials && typeof config.credentials.primary === 'string', 'credentials.primary must name a dedicated test key environment variable');
  requireThat(/^[A-Z][A-Z0-9_]*$/.test(config.credentials.primary), 'Invalid credential environment variable name');
  config.key = env[config.credentials.primary];
  requireThat(typeof config.key === 'string' && config.key.trim().length > 0, `Missing test credential: ${config.credentials.primary}`);
  config.profiles ??= ['probe'];
  requireThat(Array.isArray(config.profiles) && config.profiles.length > 0 && new Set(config.profiles).size === config.profiles.length &&
    config.profiles.every(name => Object.hasOwn(profiles, name)), 'Unknown, empty, or duplicate profile selection');
  requireThat(Object.keys(config.credentials).every(k => ['primary', 'secondary'].includes(k)), 'Unknown credential role');
  requireThat(!(config.profiles.includes('execution') && config.profiles.includes('streaming')), 'Select streaming or execution; streaming already includes execution');
  if (config.profiles.some(name => ['basic', 'execution', 'streaming', 'secrets', 'mcp', 'webhooks', 'schedules', 'deterministic', 'recovery'].includes(name))) {
    requireThat(typeof config.credentials.secondary === 'string' && /^[A-Z][A-Z0-9_]*$/.test(config.credentials.secondary), 'Selected profile requires credentials.secondary environment variable');
    config.secondaryKey = env[config.credentials.secondary];
    requireThat(typeof config.secondaryKey === 'string' && config.secondaryKey.trim().length > 0, `Missing test credential: ${config.credentials.secondary}`);
  }
  if (config.profiles.some(name => ['execution', 'streaming', 'secrets', 'mcp', 'webhooks', 'schedules'].includes(name))) {
    const settings = config.execution;
    requireThat(settings && Object.keys(settings).every(k => ['runtime', 'model', 'sandbox_provider', 'sandbox_mode', 'provision_ms', 'turn_ms', 'max_turns'].includes(k)), 'Expected explicit execution configuration');
    requireThat(['claude', 'codex', 'gemini', 'opencode'].includes(settings.runtime) &&
      typeof settings.model === 'string' && /^[a-z0-9_-]+\/[a-z0-9._-]+$/.test(settings.model) &&
      ['sprites', 'e2b', 'daytona', 'runner'].includes(settings.sandbox_provider), 'Pin an execution runtime, model, and sandbox provider');
    settings.provision_ms = positive(settings.provision_ms, 120000, 300000);
    settings.sandbox_mode ??= 'ephemeral';
    requireThat(['ephemeral', 'persistent'].includes(settings.sandbox_mode), 'Unknown execution sandbox mode');
    settings.turn_ms = positive(settings.turn_ms, 90000, 300000);
    const turns = config.profiles.includes('webhooks') ? 0 : config.profiles.some(name => ['secrets', 'schedules'].includes(name)) ? 1 : 2;
    requireThat(settings.max_turns === turns, `Execution must explicitly authorize max_turns: ${turns}`);
  }
  if (config.profiles.includes('secrets')) {
    requireThat(config.profiles.length === 1, 'Run the secrets profile separately');
    requireThat(config.execution.sandbox_mode === 'ephemeral' && ['sprites', 'e2b', 'daytona'].includes(config.execution.sandbox_provider), 'Secrets requires an ephemeral broker-capable hosted provider; runners cannot enforce broker egress');
    requireThat(config.secrets && Object.keys(config.secrets).every(k => ['allowed_url', 'blocked_url', 'admin_credential', 'bootstrap_hosts'].includes(k)), 'Expected explicit controlled receiver configuration');
    const origins = receiverOrigins(config.secrets);
    requireThat(Array.isArray(config.secrets.bootstrap_hosts) && config.secrets.bootstrap_hosts.length <= 10 &&
      config.secrets.bootstrap_hosts.every(host => typeof host === 'string' && /^(?:[a-z0-9-]+\.)+[a-z]{2,}$/.test(host) && host !== origins[1].hostname), 'Declare bounded bootstrap hostnames without the blocked receiver');
    requireThat(typeof config.secrets.admin_credential === 'string' && /^[A-Z][A-Z0-9_]*$/.test(config.secrets.admin_credential), 'Receiver admin_credential must name an environment variable');
    requireThat(typeof env[config.secrets.admin_credential] === 'string' && env[config.secrets.admin_credential].length >= 32, 'Missing controlled receiver admin credential');
  }
  if (config.profiles.includes('mcp')) {
    requireThat(config.profiles.length === 1 && config.execution.sandbox_mode === 'ephemeral', 'Run MCP separately in an ephemeral sandbox');
    requireThat(config.mcp && Object.keys(config.mcp).every(k => ['receiver_url', 'admin_credential', 'auth_mode'].includes(k)), 'Expected explicit MCP receiver configuration');
    mcpOrigin(config.mcp);
    requireThat(config.mcp.auth_mode === 'static_bearer', 'MCP conversation authentication is a gap tracked by #1405; select static_bearer explicitly');
    requireThat(typeof config.mcp.admin_credential === 'string' && /^[A-Z][A-Z0-9_]*$/.test(config.mcp.admin_credential), 'MCP admin_credential must name an environment variable');
    requireThat(typeof env[config.mcp.admin_credential] === 'string' && env[config.mcp.admin_credential].length >= 32, 'Missing MCP receiver admin credential');
  }
  if (config.profiles.includes('webhooks')) {
    requireThat(config.profiles.length === 1 && config.execution.sandbox_mode === 'ephemeral', 'Run webhooks independently in an ephemeral sandbox');
    requireThat(config.webhooks && Object.keys(config.webhooks).every(k => ['receiver_url', 'admin_credential', 'delivery_ms', 'observe_ms'].includes(k)), 'Expected explicit webhook receiver configuration');
    controlledOrigin(config.webhooks);
    requireThat(typeof config.webhooks.admin_credential === 'string' && /^[A-Z][A-Z0-9_]*$/.test(config.webhooks.admin_credential), 'Webhook admin_credential must name an environment variable');
    requireThat(typeof env[config.webhooks.admin_credential] === 'string' && env[config.webhooks.admin_credential].length >= 32, 'Missing webhook receiver admin credential');
    config.webhooks.delivery_ms = positive(config.webhooks.delivery_ms, 180000, 300000);
    config.webhooks.observe_ms = positive(config.webhooks.observe_ms, 30000, 60000);
  }
  if (config.profiles.includes('schedules')) {
    requireThat(config.profiles.length === 1 && config.execution.sandbox_mode === 'ephemeral', 'Run schedules independently in an ephemeral sandbox');
    requireThat(config.schedules && Object.keys(config.schedules).every(k => ['start_ms', 'observe_ms'].includes(k)), 'Expected explicit schedule windows');
    config.schedules.start_ms = positive(config.schedules.start_ms, 180000, 300000);
    config.schedules.observe_ms = positive(config.schedules.observe_ms, 120000, 180000);
    requireThat(config.schedules.start_ms >= 60000 && config.schedules.observe_ms >= 120000, 'Schedule windows must cover at least one dispatch minute and two observation minutes');
  }
  if (config.profiles.includes('deterministic')) {
    requireThat(config.profiles.length === 1 && !config.execution, 'Run deterministic fixture separately from real-model profiles');
    const fixture = config.fixture;
    requireThat(fixture && Object.keys(fixture).every(k => ['sandbox_provider', 'provision_ms', 'turn_ms', 'max_turns'].includes(k)), 'Expected explicit fixture configuration');
    requireThat(['sprites', 'e2b', 'daytona', 'runner'].includes(fixture.sandbox_provider), 'Pin a fixture sandbox provider');
    fixture.provision_ms = positive(fixture.provision_ms, 120000, 300000);
    fixture.turn_ms = positive(fixture.turn_ms, 30000, 60000);
    requireThat(fixture.max_turns === 7, 'Fixture requires an explicit seven-prompt budget');
  }
  config.contract = config.contract ? resolve(dirname(path), config.contract) : contractPath;
  if (config.profiles.includes('recovery')) validateRecovery(config, env);
  const limits = config.limits ?? {};
  requireThat(Object.keys(limits).every(k => ['request_ms', 'run_ms', 'cleanup_ms', 'resources'].includes(k)), 'Unknown limit');
  config.limits = {
    request_ms: positive(limits.request_ms, 10000, 120000),
    run_ms: positive(limits.run_ms, 120000, config.profiles.includes('recovery') && config.recovery.deployment.environment === 'production' ? 7200000 : 3600000),
    cleanup_ms: positive(limits.cleanup_ms, 30000, 300000), resources: positive(limits.resources, 20, 100),
  };
  if (config.profiles.includes('browser')) validateBrowser(config, env);
  if (config.profiles.includes('secrets')) {
    requireThat(config.limits.run_ms <= 600000, 'Secrets run must fit within receiver retention');
    requireThat(config.limits.resources >= 5, 'Secrets profile requires a five-resource budget');
  }
  if (config.profiles.includes('mcp')) {
    requireThat(config.limits.run_ms <= 600000 && config.limits.resources >= 3, 'MCP requires a bounded ten-minute run and three-resource budget');
  }
  if (config.profiles.includes('webhooks')) {
    requireThat(config.limits.run_ms <= 600000 && config.limits.resources >= 4, 'Webhooks require a ten-minute run bound and four resources');
  }
  if (config.profiles.includes('schedules')) {
    requireThat(config.limits.run_ms <= 900000 && config.limits.resources >= 4 && config.limits.cleanup_ms >= 30000, 'Schedules require a fifteen-minute run bound, four resources and thirty seconds for cleanup');
  }
  if (config.profiles.includes('recovery')) {
    const production = config.recovery.deployment.environment === 'production';
    requireThat(config.limits.run_ms <= (production ? 7200000 : 1800000) && config.limits.resources >= 3 && config.limits.cleanup_ms >= 30000,
      'Recovery requires its environment-specific run bound, three resources and thirty seconds for fixture cleanup');
    if (production) requireThat(config.limits.run_ms >= config.recovery.idle_wait_ms + 4 * config.recovery.turn_ms + config.recovery.provision_ms + 300000,
      'Production recovery must budget the existing idle policy, four turns, provisioning and control overhead');
  }
  for (const field of ['required_capabilities', 'optional_capabilities']) {
    config[field] ??= {};
    requireThat(Object.keys(config[field]).every(k => ['runtimes', 'sandbox_providers'].includes(k)), `Unknown ${field} category`);
    for (const entries of Object.values(config[field])) {
      requireThat(Array.isArray(entries), `Expected ${field} arrays`);
      for (const item of entries) {
        requireThat(field === 'required_capabilities' ? typeof item === 'string' && item.length > 0 :
          typeof item?.name === 'string' && typeof item?.reason === 'string' && item.reason.trim().length > 0,
        `Invalid ${field} entry`);
      }
    }
  }
  if (config.deployment) validateDeployment(config.deployment);
  return config;
}

const xml = value => String(value).replace(/[<>&"']/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[c]);
export function writeReport(out, report, redactor) {
  const safe = redactor.strings(report);
  atomicJson(resolve(out, 'result.json'), safe);
  const cases = safe.checks.map(c => `<testcase name="${xml(c.name)}" time="${(c.duration_ms / 1000).toFixed(3)}">` +
    (c.status === 'failed' ? `<failure message="${xml(c.error)}"/>` : c.status === 'skipped' ? `<skipped message="${xml(c.reason)}"/>` : '') + '</testcase>');
  writeFileSync(resolve(out, 'junit.xml'), `<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="fountain-deployed" tests="${cases.length}" failures="${safe.checks.filter(c => c.status === 'failed').length}" skipped="${safe.checks.filter(c => c.status === 'skipped').length}">${cases.join('')}</testsuite>\n`, { mode: 0o600 });
  return safe;
}

export async function run({ configPath, out, manifestPath, signal, env = process.env, log = console.log, deploymentObserver = observeDeployment }) {
  mkdirSync(out, { mode: 0o700 }); // Exclusive run directory; never overwrite another run's evidence.
  const redactor = new Redactor();
  const report = { suite_version: VERSION, run_id: randomUUID(), started_at: new Date().toISOString(),
    mode: manifestPath ? 'cleanup' : 'run', status: 'setup_failed', checks: [], revision: { verified: false, reason: 'No deployment revision adapter configured' } };
  let config, fixtures, deploymentBefore;
  const afterCleanup = [];
  const beforeCleanup = [];
  try {
    const git = (...args) => execFileSync('git', args, {
      cwd: fileURLToPath(new URL('../..', import.meta.url)), encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    report.suite_revision = git('rev-parse', 'HEAD');
    report.suite_dirty = Boolean(git('status', '--porcelain', '--untracked-files=normal'));
  } catch { report.suite_revision = null; report.suite_dirty = null; }
  const check = async (name, fn) => {
    const started = performance.now();
    try {
      await fn();
      report.checks.push({ name, status: 'passed', duration_ms: performance.now() - started });
      log(`PASS ${name}`); return true;
    } catch (error) {
      const message = redactor.text(error.message);
      report.checks.push({ name, status: 'failed', duration_ms: performance.now() - started, error: message });
      log(`FAIL ${name}: ${message}`); return false;
    } finally { writeReport(out, report, redactor); }
  };
  try {
    config = configFrom(configPath, env);
    redactor.add(config.key);
    redactor.add(config.secondaryKey);
    if (config.secrets) redactor.add(env[config.secrets.admin_credential]);
    if (config.mcp) redactor.add(env[config.mcp.admin_credential]);
    if (config.webhooks) redactor.add(env[config.webhooks.admin_credential]);
    if (config.recovery) redactor.add(env[config.recovery.relay.admin_credential]);
    if (config.browser) {
      redactor.add(env[config.browser.email]); redactor.add(env[config.browser.password]);
      if (config.browser.credential_setup) redactor.add(env[config.browser.credential_setup.value]?.trim());
    }
    report.target = config.base_url;
    report.profiles = config.profiles;
    report.limits = { ...config.limits, concurrency: 1, inference_turns: config.execution?.max_turns ?? config.browser?.conversations?.max_turns ?? 0, fixture_prompts: config.fixture?.max_turns ?? 0 };
    const contract = new Contract(config.contract);
    report.contract_sha256 = contract.sha256;
    const timeout = AbortSignal.timeout(config.limits.run_ms);
    const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
    const client = new Client({ baseUrl: config.base_url, key: config.key, redactor, contract, signal: combined,
      timeoutMs: config.limits.request_ms, trace: entry => appendFileSync(resolve(out, 'http.jsonl'), JSON.stringify(redactor.value(entry)) + '\n', { mode: 0o600 }) });
    if (config.profiles.includes('recovery') && manifestPath) {
      const manifest = JSON.parse(readFileSync(manifestPath));
      requireThat(manifest.base_url === config.base_url && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(manifest.run_id),
        'Recovery cleanup manifest target or run ID differs');
      await restoreRecoveryControls({ config, report, redactor, check, env }, dirname(manifestPath), manifest.run_id);
    }
    if (config.deployment && !manifestPath) {
      const ready = await check('setup/deployment', async () => {
        deploymentBefore = await deploymentObserver(config.deployment, combined);
        report.revision = { verified: false, before: deploymentBefore, reason: 'Awaiting post-run deployment check' };
      });
      if (!ready) throw new Error('Intended deployment is not serving');
    }
    let ownerId;
    const identityOk = await check('setup/identity', async () => {
      const { body } = await client.request('GET', '/api/auth/me', { expected: 200 });
      requireThat(typeof body.id === 'string' && body.email_verified === true, 'Expected a verified dedicated test account');
      ownerId = body.id;
      report.owner_id = ownerId;
    });
    if (!identityOk) throw new Error('Cannot establish fixture owner');
    fixtures = manifestPath ? Fixtures.load(manifestPath, client, ownerId) :
      new Fixtures(resolve(out, 'cleanup.json'), client, { runId: report.run_id, baseUrl: config.base_url, ownerId, maxResources: config.limits.resources });
    if (!manifestPath) {
      const capabilitiesOk = await check('setup/capabilities', async () => {
        const { body } = await client.request('GET', '/api/catalog', { expected: 200 });
        const available = { runtimes: body.data?.runtimes, sandbox_providers: body.data?.sandbox_providers?.enabled };
        requireThat(Object.values(available).every(Array.isArray), 'Catalog capability arrays missing');
        report.capabilities = available;
        if (config.profiles.some(name => ['execution', 'streaming', 'secrets', 'mcp', 'webhooks', 'schedules'].includes(name))) {
          requireThat(available.runtimes.includes(config.execution.runtime), 'Execution runtime is unavailable');
          requireThat(available.sandbox_providers.includes(config.execution.sandbox_provider), 'Execution sandbox provider is unavailable');
        }
        if (config.profiles.some(name => ['deterministic', 'recovery'].includes(name))) {
          requireThat(available.runtimes.includes('fountain-fixture'), 'Deterministic runtime is not enabled on this target');
          requireThat(available.sandbox_providers.includes(config.fixture.sandbox_provider), 'Fixture sandbox provider is unavailable');
        }
        for (const [kind, names] of Object.entries(config.required_capabilities)) {
          for (const name of names) requireThat(available[kind].includes(name), `Missing required ${kind}: ${name}`);
        }
        for (const [kind, entries] of Object.entries(config.optional_capabilities)) {
          for (const { name, reason } of entries) if (!available[kind].includes(name)) {
            report.checks.push({ name: `capability/${kind}/${name}`, status: 'skipped', reason, duration_ms: 0 });
          }
        }
      });
      if (!capabilitiesOk) throw new Error('Required capabilities unavailable');
      report.status = 'running';
      const ctx = { client, fixtures, config, report, redactor, check, require: requireThat, signal: combined, out, env, beforeCleanup, afterCleanup,
        persist: () => writeReport(out, report, redactor) };
      for (const name of config.profiles) {
        combined.throwIfAborted();
        await profiles[name](ctx);
      }
    } else {
      report.status = 'running'; report.cleanup_run_id = fixtures.manifest.run_id;
      const webhookPath = resolve(dirname(manifestPath), 'webhook-receiver.json');
      // A journal that already records its receiver as settled owes nothing,
      // so it must not demand a configuration the run may no longer have: a
      // receiver hosted for that run is stopped by the time a replay runs.
      if (existsSync(webhookPath) && journalSettled(webhookPath, fixtures.manifest.run_id)) {
        afterCleanup.push({ name: 'webhooks/receiver-cleanup', run: async () => {} });
      } else if (existsSync(webhookPath)) afterCleanup.push({ name: 'webhooks/receiver-cleanup', run: async () => {
        requireThat(config.webhooks, 'Webhook cleanup requires the original target configuration');
        const receiver = new ControlledReceiverSession({ settings: config.webhooks, adminKey: env[config.webhooks.admin_credential], path: webhookPath,
          runId: fixtures.manifest.run_id, redactor, version: WEBHOOK_VERSION });
        receiver.loadCleanup();
        await receiver.cleanup(AbortSignal.timeout(config.limits.cleanup_ms));
      } });
      const mcpPath = resolve(dirname(manifestPath), 'mcp-receiver.json');
      // A journal that already records its receiver as settled owes nothing,
      // so it must not demand a configuration the run may no longer have: a
      // receiver hosted for that run is stopped by the time a replay runs.
      if (existsSync(mcpPath) && journalSettled(mcpPath, fixtures.manifest.run_id)) {
        afterCleanup.push({ name: 'mcp/receiver-cleanup', run: async () => {} });
      } else if (existsSync(mcpPath)) afterCleanup.push({ name: 'mcp/receiver-cleanup', run: async () => {
        requireThat(config.mcp, 'MCP cleanup requires the original target configuration');
        const receiver = new McpReceiverSession({ settings: config.mcp, adminKey: env[config.mcp.admin_credential], path: mcpPath,
          runId: fixtures.manifest.run_id, redactor });
        receiver.loadCleanup();
        await receiver.cleanup(AbortSignal.timeout(config.limits.cleanup_ms));
      } });
      const receiverPath = resolve(dirname(manifestPath), 'receiver.json');
      // A journal that already records its receiver as settled owes nothing,
      // so it must not demand a configuration the run may no longer have: a
      // receiver hosted for that run is stopped by the time a replay runs.
      if (existsSync(receiverPath) && journalSettled(receiverPath, fixtures.manifest.run_id)) {
        afterCleanup.push({ name: 'secrets/receiver-cleanup', run: async () => {} });
      } else if (existsSync(receiverPath)) afterCleanup.push({ name: 'secrets/receiver-cleanup', run: async () => {
        requireThat(config.secrets, 'Receiver cleanup requires the original secrets target configuration');
        const receiver = new ReceiverSession({ settings: config.secrets, adminKey: env[config.secrets.admin_credential], path: receiverPath,
          runId: fixtures.manifest.run_id, redactor });
        receiver.loadCleanup();
        await receiver.cleanup(AbortSignal.timeout(config.limits.cleanup_ms));
      } });
    }
    if (report.status !== 'setup_failed') report.status = report.checks.some(c => c.status === 'failed') ? 'failed' : 'passed';
  } catch (error) {
    if (report.status === 'running') report.status = 'failed';
    report.checks.push({ name: report.status === 'setup_failed' ? 'setup/configuration' : 'run', status: 'failed', duration_ms: 0, error: redactor.text(error.message) });
  } finally {
    for (const prepare of beforeCleanup) await prepare();
    if (fixtures) {
      const failures = await fixtures.cleanup(AbortSignal.timeout(config.limits.cleanup_ms));
      report.cleanup = { failures, remaining: fixtures.remainingCount() };
      if (fixtures.manifest.browser_credential) report.cleanup.provider_setup = { ...fixtures.manifest.browser_credential };
      if (fixtures.manifest.schedule) report.cleanup.schedule = { state: fixtures.manifest.schedule.state, deleted: fixtures.manifest.schedule.deleted, conversations: fixtures.manifest.schedule.conversations, remaining_sandbox_ids: fixtures.manifest.schedule.remaining_sandbox_ids ?? [] };
      report.prompt_attempts = fixtures.manifest.inference_attempts ?? 0;
      report.inference_attempts = config.profiles.some(name => ['deterministic', 'recovery'].includes(name)) ? 0 : report.prompt_attempts;
      if (failures.length) {
        report.status = 'cleanup_failed';
        report.checks.push({ name: 'cleanup', status: 'failed', duration_ms: 0, error: 'Resources remain; see cleanup manifest and result.json' });
      }
    }
    for (const finalizer of afterCleanup.reverse()) {
      const ok = await check(finalizer.name, finalizer.run);
      if (!ok) report.status = finalizer.name.endsWith('cleanup') ? 'cleanup_failed' : report.status === 'cleanup_failed' ? 'cleanup_failed' : 'failed';
    }
    if (deploymentBefore) {
      const stable = await check('deployment/stable', async () => {
        const after = await deploymentObserver(config.deployment, AbortSignal.timeout(20000));
        report.revision = verifyStable(deploymentBefore, after);
      });
      if (!stable && report.status === 'passed') report.status = 'failed';
    }
    if (signal?.aborted) report.status = 'cancelled';
    if (report.recovery?.cleanup_failed) report.status = 'cleanup_failed';
    report.ended_at = new Date().toISOString();
    writeReport(out, report, redactor);
    log(`${report.status.toUpperCase()} — ${resolve(out, 'result.json')}`);
  }
  return { passed: 0, failed: 1, setup_failed: 2, cleanup_failed: 3, cancelled: 130 }[report.status];
}
