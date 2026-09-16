import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { verifyConfig, summarize, resolveCredentials, targetOrigin, verifyMain, VERIFY_PROFILES, CREDENTIALS } from '../verify.mjs';
import { hostsReceiver } from '../lib/local-receiver.mjs';
import { ciConfig } from '../ci.mjs';
import { configFrom } from '../lib/runner.mjs';
import { PROFILES } from '../lib/target.mjs';

const keys = { FOUNTAIN_SUITE_KEY: 'primary-key', FOUNTAIN_SUITE_OTHER_KEY: 'secondary-key' };
const args = (changes = {}) => ({ profile: 'streaming', runtime: 'claude',
  model: 'anthropic/claude-haiku-4-5', sandbox: 'sprites', baseUrl: 'https://example.test', ...changes });

test('an unknown profile names the approved ones instead of running', () => {
  assert.throws(() => verifyConfig(args({ profile: 'everything' }), keys), /Unknown profile/);
});

// Advertising a profile this command cannot configure only produces targets
// that fail setup. Each advertised one is composed exactly as a run composes
// it — receiver settings included — and loaded through the real loader.
const stubReceiver = profile => (profile === 'secrets'
  ? { allowed_url: 'https://allowed.example.com/', blocked_url: 'https://blocked.example.com/',
      admin_credential: 'FOUNTAIN_RECEIVER_ADMIN_KEY', bootstrap_hosts: ['registry.npmjs.org'] }
  : profile === 'mcp'
    ? { receiver_url: 'https://mcp.example.com/', admin_credential: 'FOUNTAIN_MCP_ADMIN_KEY', auth_mode: 'static_bearer' }
    : { receiver_url: 'https://hook.example.com/', admin_credential: 'FOUNTAIN_WEBHOOK_ADMIN_KEY',
        delivery_ms: 180000, observe_ms: 30000 });

test('every advertised profile composes a target the runner accepts', () => {
  const dir = mkdtempSync(join(tmpdir(), 'fountain-verify-profiles-'));
  const env = { ...keys, FOUNTAIN_RECEIVER_ADMIN_KEY: 'x'.repeat(64),
    FOUNTAIN_MCP_ADMIN_KEY: 'x'.repeat(64), FOUNTAIN_WEBHOOK_ADMIN_KEY: 'x'.repeat(64) };
  try {
    for (const profile of VERIFY_PROFILES) {
      const composed = verifyConfig(args({ profile }), env, hostsReceiver(profile) ? stubReceiver(profile) : undefined);
      const path = join(dir, `${profile}.json`);
      writeFileSync(path, JSON.stringify(composed));
      assert.deepEqual(configFrom(path, env).profiles, composed.profiles, profile);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a receiver profile cannot compose without its receiver, and vice versa', () => {
  assert.throws(() => verifyConfig(args({ profile: 'secrets' }), keys), /needs a receiver/);
  assert.throws(() => verifyConfig(args({ profile: 'streaming' }), keys, stubReceiver('mcp')), /uses no receiver/);
});

test('a profile this command cannot configure is refused and points at the CLI', () => {
  assert.ok(!VERIFY_PROFILES.includes('schedules'));
  assert.throws(() => verifyConfig(args({ profile: 'schedules' }), keys),
    /needs configuration this command cannot supply.*cli\.mjs/s);
});

test('a credential-bearing target is refused without echoing it', () => {
  const secret = 'ftn_fake_userinfo_secret_probe';
  for (const target of [`https://user:${secret}@example.test`, `https://${secret}@example.test`]) {
    assert.throws(() => targetOrigin(target), error => {
      assert.match(error.message, /must not carry credentials/);
      assert.ok(!error.message.includes(secret), 'the refusal must not quote the credential back');
      return true;
    });
  }
  for (const target of [`https://example.test/?token=${secret}`, `https://example.test/#${secret}`]) {
    assert.throws(() => targetOrigin(target), error => {
      assert.ok(!error.message.includes(secret));
      return /query or a fragment/.test(error.message);
    });
  }
  assert.throws(() => targetOrigin('https://example.test/some/path'), /must be an origin/);
});

test('a refused target is rejected before any credential is resolved', () => {
  let looked = false;
  assert.throws(() => {
    const origin = targetOrigin('https://user:pw@example.test').origin;
    resolveCredentials(origin, {}, { lookup: () => { looked = true; return 'key'; } });
  }, /must not carry credentials/);
  assert.equal(looked, false);
});

test('a remote target must be encrypted, a loopback one need not be', () => {
  assert.throws(() => verifyConfig(args({ baseUrl: 'http://example.test' }), keys), /requires HTTPS ingress/);
  assert.throws(() => verifyConfig(args({ baseUrl: 'ftp://example.test' }), keys), /absolute http\(s\) URL/);
  assert.throws(() => verifyConfig(args({ baseUrl: 'example.test' }), keys), /absolute http\(s\) URL/);
  for (const host of ['localhost', '127.0.0.1', '[::1]']) {
    assert.equal(verifyConfig(args({ baseUrl: `http://${host}:4000` }), keys).base_url, `http://${host}:4000/`);
  }
});

// A stored key belongs to one deployment. Sending a production key to
// whatever URL happens to be typed is the disclosure; the later identity
// failure cannot take it back.
test('a stored key is only offered to the exact target it was stored for', () => {
  const stored = { [`https://managoat.com|FOUNTAIN_SUITE_KEY`]: 'production-primary',
    [`https://managoat.com|FOUNTAIN_SUITE_OTHER_KEY`]: 'production-secondary' };
  const lookup = (service, account) => stored[account];

  const matched = resolveCredentials('https://managoat.com', {}, { lookup });
  assert.equal(matched.env.FOUNTAIN_SUITE_KEY, 'production-primary');
  assert.deepEqual(matched.fromKeychain, CREDENTIALS);

  for (const other of ['http://localhost:4000', 'https://example.test', 'https://managoat.com.evil.test']) {
    const resolved = resolveCredentials(other, {}, { lookup });
    assert.deepEqual(resolved.fromKeychain, [], other);
    for (const name of CREDENTIALS) assert.equal(resolved.env[name], undefined, `${other} received ${name}`);
  }
});

test('one exported key does not pull the other from an unrelated target', () => {
  const lookup = (service, account) => (account === 'https://managoat.com|FOUNTAIN_SUITE_OTHER_KEY' ? 'production-secondary' : undefined);
  const resolved = resolveCredentials('http://localhost:4000', { FOUNTAIN_SUITE_KEY: 'local-primary' }, { lookup });
  assert.equal(resolved.env.FOUNTAIN_SUITE_KEY, 'local-primary');
  assert.equal(resolved.env.FOUNTAIN_SUITE_OTHER_KEY, undefined);
  assert.deepEqual(resolved.fromKeychain, []);
});

test('an exported key always wins over a stored one', () => {
  const resolved = resolveCredentials('https://managoat.com', { FOUNTAIN_SUITE_KEY: 'exported' },
    { lookup: () => 'stored' });
  assert.equal(resolved.env.FOUNTAIN_SUITE_KEY, 'exported');
  assert.deepEqual(resolved.fromKeychain, ['FOUNTAIN_SUITE_OTHER_KEY']);
});

test('missing credentials fail setup before any request', () => {
  assert.throws(() => verifyConfig(args(), {}), /FOUNTAIN_SUITE_KEY/);
  assert.throws(() => verifyConfig(args(), { FOUNTAIN_SUITE_KEY: 'primary-key' }), /FOUNTAIN_SUITE_OTHER_KEY/);
});

test('probe needs one account; every other profile proves isolation with two', () => {
  const probe = verifyConfig(args({ profile: 'probe' }), { FOUNTAIN_SUITE_KEY: 'primary-key' });
  assert.deepEqual(probe.credentials, { primary: 'FOUNTAIN_SUITE_KEY' });
  assert.deepEqual(probe.required_capabilities.sandbox_providers, []);
  assert.equal(probe.execution, undefined, 'probe asserts on advertisement, not on a turn');
  const streaming = verifyConfig(args(), keys);
  assert.deepEqual(streaming.credentials, { primary: 'FOUNTAIN_SUITE_KEY', secondary: 'FOUNTAIN_SUITE_OTHER_KEY' });
  assert.deepEqual(streaming.required_capabilities, { runtimes: ['claude'], sandbox_providers: ['sprites'] });
});

test('basic declares the runtime it needs without provisioning a sandbox', () => {
  const basic = verifyConfig(args({ profile: 'basic' }), keys);
  assert.deepEqual(basic.required_capabilities, { runtimes: ['claude'], sandbox_providers: [] });
  assert.equal(basic.execution, undefined);
});

test('the declared runtime, model and provider reach the execution block', () => {
  const config = verifyConfig(args({ runtime: 'codex', model: 'openai/gpt-5.5', sandbox: 'e2b' }), keys);
  assert.equal(config.execution.runtime, 'codex');
  assert.equal(config.execution.model, 'openai/gpt-5.5');
  assert.equal(config.execution.sandbox_provider, 'e2b');
  assert.deepEqual(config.required_capabilities, { runtimes: ['codex'], sandbox_providers: ['e2b'] });
});

test('an expected contract is carried through and otherwise left to the default', () => {
  assert.equal(verifyConfig(args(), keys).contract, undefined);
  assert.equal(verifyConfig(args({ contract: '../pinned.json' }), keys).contract, '../pinned.json');
});

// The button is only worth having if its verdict means what CI's verdict
// means. Both compose through lib/target.mjs; this pins that they agree.
test('a local run composes the same profiles, limits and turns as CI', () => {
  const env = { ...keys, FOUNTAIN_RECEIVER_ADMIN_KEY: 'x'.repeat(64),
    FOUNTAIN_MCP_ADMIN_KEY: 'x'.repeat(64), FOUNTAIN_WEBHOOK_ADMIN_KEY: 'x'.repeat(64) };
  for (const profile of VERIFY_PROFILES) {
    const local = verifyConfig(args({ profile }), env, hostsReceiver(profile) ? stubReceiver(profile) : undefined);
    const ci = ciConfig({
      SUITE_TARGET: 'production', SUITE_ENABLED: 'true', SUITE_PROFILE: profile, SUITE_MODE: 'public',
      SUITE_TARGET_JSON: JSON.stringify({ base_url: 'https://example.test',
        execution: { runtime: 'claude', model: 'anthropic/claude-haiku-4-5', sandbox_provider: 'sprites' } }),
    });
    assert.deepEqual(local.profiles, ci.profiles, profile);
    assert.deepEqual(local.limits, ci.limits, profile);
    if (local.execution) assert.equal(local.execution.max_turns, ci.execution.max_turns, profile);
  }
});

test('the summary reports failures, skips, cleanup and unverified revision', () => {
  const lines = [];
  summarize({ status: 'failed',
    checks: [{ name: 'identity', status: 'passed' }, { name: 'first-turn', status: 'failed', error: 'no artifact' },
      { name: 'capability/sandbox_providers/e2b', status: 'skipped', reason: 'Not configured' }],
    cleanup: { remaining: 2 },
    revision: { verified: false, reason: 'No deployment revision adapter configured' } }, line => lines.push(line));
  const text = lines.join('\n');
  assert.match(text, /1 passed, 1 failed, 1 skipped/);
  assert.match(text, /failed {5}first-turn: no artifact/);
  assert.match(text, /skipped {4}capability\/sandbox_providers\/e2b: Not configured/);
  assert.match(text, /cleanup {4}2 resource\(s\) remaining/);
  assert.match(text, /unverified \(No deployment revision adapter configured\)/);
});

test('a run that wrote no report says so instead of claiming a pass', () => {
  const lines = [];
  summarize(undefined, line => lines.push(line));
  assert.match(lines.join('\n'), /no result\.json/);
});

// Hosting a receiver is the first abortable phase of a run. Ctrl-C during it
// is an operator cancelling, and the documented exit contract must not depend
// on whether the signal lands before or after the run starts.
test('an interrupt while the receiver is coming up exits 130, not 2', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'fountain-verify-interrupt-'));
  try {
    const env = { ...keys, TMPDIR: dir };
    let stopped = false;
    // Stands in for hosting: hosting spawns cloudflared, and this must not
    // depend on that binary being present or on how fast it starts.
    const hostReceiverFn = (profile, { signal }) => new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => { stopped = true; reject(new Error('Interrupted')); }, { once: true });
    });
    const started = verifyMain(['https://example.test', '--profile', 'mcp'], env, { hostReceiverFn });
    setTimeout(() => process.emit('SIGINT'), 10);
    assert.equal(await started, 130, 'an operator cancellation is not a setup failure');
    assert.equal(stopped, true, 'the hosting phase is told to stop');
    assert.deepEqual(readdirSync(dir), [], 'a cancelled run leaves no evidence directory');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
