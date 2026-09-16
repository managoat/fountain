import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { verifyConfig, summarize, resolveCredentials, targetOrigin, VERIFY_PROFILES, CREDENTIALS } from '../verify.mjs';
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
// that fail setup. Each advertised one is validated through the real loader.
test('every advertised profile composes a target the runner accepts', () => {
  const dir = mkdtempSync(join(tmpdir(), 'fountain-verify-profiles-'));
  try {
    for (const profile of VERIFY_PROFILES) {
      const path = join(dir, `${profile}.json`);
      writeFileSync(path, JSON.stringify(verifyConfig(args({ profile }), keys)));
      const loaded = configFrom(path, keys);
      assert.deepEqual(loaded.profiles, verifyConfig(args({ profile }), keys).profiles, profile);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a profile this command cannot configure is refused and points at the CLI', () => {
  for (const profile of ['secrets', 'mcp', 'webhooks', 'schedules']) {
    assert.ok(!VERIFY_PROFILES.includes(profile));
    assert.throws(() => verifyConfig(args({ profile }), keys),
      /needs configuration this command cannot supply.*cli\.mjs/s, profile);
  }
});

// The suite's redaction contract covers what it prints and persists, so a
// credential in the URL has to be refused before either happens.
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
  for (const profile of VERIFY_PROFILES) {
    const local = verifyConfig(args({ profile }), keys);
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
