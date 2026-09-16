import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyConfig, summarize } from '../verify.mjs';
import { ciConfig } from '../ci.mjs';
import { PROFILES } from '../lib/target.mjs';

const keys = { FOUNTAIN_SUITE_KEY: 'primary-key', FOUNTAIN_SUITE_OTHER_KEY: 'secondary-key' };
const args = (changes = {}) => ({ profile: 'streaming', runtime: 'claude',
  model: 'anthropic/claude-haiku-4-5', sandbox: 'sprites', baseUrl: 'https://example.test', ...changes });

test('an unknown profile names the approved ones instead of running', () => {
  assert.throws(() => verifyConfig(args({ profile: 'everything' }), keys), /Unknown profile/);
});

test('a remote target must be encrypted, a loopback one need not be', () => {
  assert.throws(() => verifyConfig(args({ baseUrl: 'http://example.test' }), keys), /requires HTTPS ingress/);
  assert.throws(() => verifyConfig(args({ baseUrl: 'ftp://example.test' }), keys), /absolute http\(s\) URL/);
  assert.throws(() => verifyConfig(args({ baseUrl: 'example.test' }), keys), /absolute http\(s\) URL/);
  for (const host of ['localhost', '127.0.0.1', '[::1]']) {
    assert.equal(verifyConfig(args({ baseUrl: `http://${host}:4000` }), keys).base_url, `http://${host}:4000/`);
  }
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
  for (const profile of PROFILES) {
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
