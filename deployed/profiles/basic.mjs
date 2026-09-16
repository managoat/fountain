import { randomUUID, createHash } from 'node:crypto';
import { probe } from './probe.mjs';
import { verifyAdvertisement } from '../lib/advertisement.mjs';

export const advertisedVersion = value => (typeof value === 'string' ? value : null);

export async function basic(ctx) {
  const { client, fixtures, config, require: need, check } = ctx;
  const other = config.secondaryKey;
  // Establish both identities before creating anything. Reusing the same
  // account with another key would turn an isolation test into a false verdict.
  const distinct = await check('basic/second-tenant', async () => {
    const { body } = await client.request('GET', '/api/auth/me', { key: other, expected: 200 });
    need(body.email_verified === true && body.id !== ctx.report.owner_id, 'Basic profile requires two distinct verified test accounts');
    ctx.report.secondary_owner_id = body.id;
  });
  if (!distinct) return;
  await probe(ctx);
  await check('basic/authentication', async () => {
    for (const key of [null, `ftn_invalid_${randomUUID()}`]) {
      const { body } = await client.request('GET', '/api/auth/me', { key, expected: 401 });
      need(typeof body.error === 'string', 'Authentication denial must carry an error');
    }
  });
  const operations = new Set(['GET /api/auth/me', 'GET /api/catalog', 'GET /health', 'GET /health/ready']);
  for (const [kind, collection, attrs] of [
    ['environment', '/api/environments', {}],
    ['vault', '/api/vaults', {}],
    ['agent', '/api/agents', { runtime: 'claude', model: 'anthropic/claude-sonnet-4-6' }],
  ]) {
    for (const op of [`GET ${collection}`, `POST ${collection}`, `GET ${collection}/{id}`, `PUT ${collection}/{id}`, `DELETE ${collection}/{id}`]) operations.add(op);
    await check(`basic/${kind}/lifecycle-and-isolation`, async () => {
      const value = await fixtures.create(kind, attrs);
      const path = `${collection}/${value.id}`;
      const marker = { suite_revision: randomUUID() };
      const read = await client.request('GET', path, { expected: 200 });
      need(read.body.data.id === value.id && read.body.data.name === value.name, 'Created resource did not round-trip');
      const update = await client.request('PUT', path, { expected: 200, body: { metadata: marker } });
      need(update.body.data.metadata?.suite_revision === marker.suite_revision, 'Resource metadata update was lost');
      const listed = await client.request('GET', collection, { expected: 200, recordBody: false });
      need(listed.body.data.some(item => item.id === value.id), 'Own list omitted created resource');
      const otherList = await client.request('GET', collection, { key: other, expected: 200, recordBody: false });
      need(!otherList.body.data.some(item => item.id === value.id), 'Other tenant list disclosed resource');
      for (const method of ['GET', 'PUT', 'DELETE']) {
        const denied = await client.request(method, path, { key: other, expected: 404,
          body: method === 'PUT' ? { metadata: { suite_revision: 'unauthorized' } } : undefined });
        need(typeof denied.body.error === 'string', 'Cross-tenant denial has no error');
      }
      const preserved = await client.request('GET', path, { expected: 200 });
      need(preserved.body.data.metadata?.suite_revision === marker.suite_revision, 'Denied mutation changed the resource');
      await client.request('GET', `${collection}/${randomUUID()}`, { expected: 404 });
      const invalid = await client.request('PUT', path, { expected: 422, body: { name: '' } });
      need(invalid.body.errors && Object.hasOwn(invalid.body.errors, 'name'), 'Validation response lost name field errors');
      // Name remains stable throughout the test so recovery can prove ownership.
      const unchanged = await client.request('GET', path, { expected: 200 });
      need(unchanged.body.data.name === value.name, 'Invalid mutation changed the fixture name');
      await client.request('DELETE', path, { expected: 204 });
      await client.request('GET', path, { expected: 404 });
      // The final cleanup pass reconciles the already-deleted manifest entry.
    });
  }
  await check('basic/key-lifecycle', async () => {
    const key = await fixtures.create('api_key');
    need(typeof key.key === 'string' && key.key.length > 0, 'New key is missing its one-time plaintext');
    const identity = await client.request('GET', '/api/auth/me', { key: key.key, expected: 200 });
    need(identity.body.id === ctx.report.owner_id, 'Minted key authenticated as another account');
    const listed = await client.request('GET', '/api/auth/api-keys', { expected: 200, recordBody: false });
    need(listed.body.data.some(item => item.id === key.id), 'Minted key is absent from key list');
    need(!JSON.stringify(listed.body).includes(key.key), 'Key listing disclosed plaintext key material');
    await client.request('DELETE', `/api/auth/api-keys/${key.id}`, { key: other, expected: 404 });
    await client.request('DELETE', `/api/auth/api-keys/${key.id}`, { expected: 204 });
    await client.request('GET', '/api/auth/me', { key: key.key, expected: 401 });
    await client.request('GET', '/api/auth/me', { expected: 200 });
  });
  ['GET /api/auth/api-keys', 'POST /api/auth/api-keys', 'DELETE /api/auth/api-keys/{id}'].forEach(op => operations.add(op));
  await check('basic/advertised-contract', async () => {
    const { body } = await client.request('GET', '/api/openapi.json', { expected: 200, validate: false, recordBody: false });
    // The only value of this document that reaches the report. `recordBody`
    // is false, so the body never passed the redactor's response heuristic,
    // and a version is a scalar: anything else is a malformed instance
    // handing us an unregistered value to persist. Project it or drop it.
    ctx.report.advertised_schema = { version: advertisedVersion(body.info?.version),
      sha256: createHash('sha256').update(JSON.stringify(body)).digest('hex'), operations_checked: [...operations] };
    verifyAdvertisement(body, client.contract.document, [...operations]);
  });
}
