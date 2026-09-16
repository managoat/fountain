import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Redactor } from '../lib/http.mjs';
import { writeReport } from '../lib/runner.mjs';

// The shape a failed secrets run writes: findings under a key the credential
// heuristic matches, holding short incidental strings.
const failedSecretsReport = () => ({
  status: 'failed',
  checks: [
    { name: 'setup/identity', status: 'passed', duration_ms: 12 },
    { name: 'secrets/sandbox-delivery-and-output', status: 'failed', duration_ms: 34,
      error: 'Synthetic secret disclosed in public sse response at /api/conversations/abc/stream' },
    { name: 'capability/sandbox_providers/e2b', status: 'skipped', duration_ms: 0, reason: 'Not configured' },
  ],
  secrets: {
    inspection: { inspected: { http: 12, sse: 3 },
      leaks: [{ path: '/api/conversations/abc/stream?blocks=true', transport: 'sse' }] },
    egress: [{ credential_keys: ['SUITE_BINDING'], status: 200 }],
  },
});

test('report evidence survives redaction instead of becoming one [REDACTED]', () => {
  const safe = new Redactor().strings(failedSecretsReport());
  assert.equal(typeof safe.secrets, 'object', 'the findings that explain a failure must reach the report');
  assert.deepEqual(safe.secrets.inspection.leaks, [{ path: '/api/conversations/abc/stream?blocks=true', transport: 'sse' }]);
  assert.deepEqual(safe.secrets.inspection.inspected, { http: 12, sse: 3 });
});

// The defect: 'sse' from a leak record became a global redaction token, so
// every later "passed" was rewritten to "pa[REDACTED]d".
test('a finding never becomes a redaction token that corrupts the rest', () => {
  const redactor = new Redactor();
  const safe = redactor.strings(failedSecretsReport());
  assert.deepEqual(safe.checks.map(check => check.status), ['passed', 'failed', 'skipped'],
    'check statuses must stay valid enum values');
  assert.match(safe.checks[1].error, /public sse response at \/api\/conversations\/abc\/stream/,
    'the diagnostic must stay readable');
  assert.equal(redactor.text('passed'), 'passed');
});

test('registered secrets are still removed from every string in the report', () => {
  const redactor = new Redactor(['suite_secret_9f2c']);
  redactor.add('ftn_live_key_value');
  const safe = redactor.strings({
    checks: [{ name: 'turn', status: 'failed', error: 'echoed suite_secret_9f2c back' }],
    secrets: { observations: [{ note: 'bound ftn_live_key_value arrived' }] },
    nested: [[{ deep: 'suite_secret_9f2c' }]],
  });
  assert.equal(safe.checks[0].error, 'echoed [REDACTED] back');
  assert.equal(safe.secrets.observations[0].note, 'bound [REDACTED] arrived');
  assert.equal(safe.nested[0][0].deep, '[REDACTED]');
});

test('the key-name heuristic still guards data an instance sent us', () => {
  const redactor = new Redactor();
  const traced = redactor.value({ headers: { authorization: 'Bearer ftn_secret' }, data: { api_key: 'abc123xyz' } });
  assert.equal(traced.headers.authorization, '[REDACTED]');
  assert.equal(traced.data.api_key, '[REDACTED]');
  // Having learned it from the response, it is removed from prose elsewhere.
  assert.equal(redactor.text('the value abc123xyz leaked'), 'the value [REDACTED] leaked');
});

// A run persists the report repeatedly through the same redactor — once per
// check via `persist`, again on cleanup and again at the end. That is what
// made the defect bite: the first pass learned a token from the findings, and
// every later pass applied it to everything else.
test('repeated persists of the same report stay identical', () => {
  const out = mkdtempSync(join(tmpdir(), 'fountain-report-'));
  try {
    const redactor = new Redactor(), report = failedSecretsReport();
    const first = writeReport(out, report, redactor);
    const second = writeReport(out, report, redactor);
    assert.deepEqual(second, first, 'persisting twice must not rewrite the report');
    assert.deepEqual(second.checks.map(check => check.status), ['passed', 'failed', 'skipped'],
      'check statuses must stay valid enum values across persists');

    const xml = readFileSync(join(out, 'junit.xml'), 'utf8');
    assert.match(xml, /tests="3"/);
    assert.match(xml, /failures="1"/);
    assert.match(xml, /skipped="1"/);
    const result = JSON.parse(readFileSync(join(out, 'result.json'), 'utf8'));
    assert.deepEqual(result.checks.map(check => check.status), ['passed', 'failed', 'skipped']);
    assert.equal(typeof result.secrets, 'object');
  } finally { rmSync(out, { recursive: true, force: true }); }
});
