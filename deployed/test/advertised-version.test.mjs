import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, writeFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { run } from '../lib/runner.mjs';
import { advertisedVersion } from '../profiles/basic.mjs';

// `/api/openapi.json` is fetched with `recordBody: false`, so its body never
// passes the redactor's response heuristic. `info.version` is the one value of
// it that reaches the report, so a malformed instance could otherwise hand the
// report an unregistered value to persist.
const planted = 'sk_fake_unregistered_provider_secret_bfa18b3c';
const catalog = { data: {
  runtimes: ['claude'], models: { claude: ['anthropic/claude-sonnet-4-6'] },
  sandbox_providers: { enabled: [], default: 'sprites' }, package_managers: [],
  apps: { conversations: null, team: null },
  first_request: { curl: '', typescript: '', prompt: '', placeholders: [] },
} };
const send = (res, status, body) => {
  res.writeHead(status, { 'content-type': 'application/json', 'x-request-id': 'test-request' });
  res.end(body === undefined ? undefined : JSON.stringify(body));
};

async function runBasic(t, version) {
  const dir = mkdtempSync(join(tmpdir(), 'fountain-advertised-'));
  const primary = randomUUID(), secondary = randomUUID();
  const server = createServer((req, res) => {
    const key = (req.headers.authorization || '').replace('Bearer ', '');
    if (req.url === '/api/openapi.json') return send(res, 200, { openapi: '3.0.0', info: { version } });
    if (req.url === '/api/auth/me') {
      return send(res, 200, { id: key === primary ? 'aaaaaaaa-1111-4111-8111-111111111111' : 'bbbbbbbb-2222-4222-8222-222222222222',
        email: `${key === primary ? 'one' : 'two'}@example.test`, email_verified: true, role: 'user' });
    }
    if (req.url === '/api/catalog') return send(res, 200, catalog);
    if (req.url === '/health') return send(res, 200, { status: 'ok' });
    if (req.url === '/health/ready') return send(res, 200, { status: 'ok', checks: { database: 'ok' } });
    send(res, 404, { error: 'not_found' });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    rmSync(dir, { recursive: true, force: true });
  });
  const configPath = join(dir, 'target.json');
  writeFileSync(configPath, JSON.stringify({ base_url: `http://127.0.0.1:${server.address().port}`,
    credentials: { primary: 'SUITE_TEST_KEY', secondary: 'SUITE_OTHER_KEY' }, profiles: ['basic'] }));
  const out = join(dir, 'results');
  const code = await run({ configPath, out, env: { SUITE_TEST_KEY: primary, SUITE_OTHER_KEY: secondary }, log() {} });
  return { code, out, report: JSON.parse(readFileSync(join(out, 'result.json'), 'utf8')) };
}

test('a structured advertised version never reaches the retained artifacts', async t => {
  const { out, report } = await runBasic(t, { api_key: planted });
  assert.equal(report.advertised_schema.version, null,
    'only a version scalar belongs in the report; a structured value is dropped');
  for (const name of readdirSync(out)) {
    assert.ok(!readFileSync(join(out, name), 'utf8').includes(planted),
      `${name} retained an unregistered response value`);
  }
});

test('a normal advertised version is still recorded', async t => {
  const { report } = await runBasic(t, '1.4.2');
  assert.equal(report.advertised_schema.version, '1.4.2');
});

test('only a string is a version', () => {
  assert.equal(advertisedVersion('0.19.0'), '0.19.0');
  for (const value of [{ api_key: planted }, [planted], 42, true, null, undefined]) {
    assert.equal(advertisedVersion(value), null);
  }
});
