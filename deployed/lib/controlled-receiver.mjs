import { readFileSync } from 'node:fs';
import { Client } from './http.mjs';
import { atomicJson } from './fixtures.mjs';
import { ensure } from './execution.mjs';

export function controlledOrigin(settings) {
  const url = new URL(settings.receiver_url);
  ensure(url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash && url.pathname === '/' &&
    /^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/i.test(url.hostname) && !url.hostname.endsWith('.internal'),
  'Controlled receiver requires an explicit HTTPS origin on a public hostname');
  return url;
}
export class ControlledReceiverSession {
  constructor({ settings, adminKey, path, runId, redactor, signal, version, trace = () => {} }) {
    ensure(typeof version === 'string' && version.length > 0, 'Expected receiver protocol version');
    this.version = version;
    this.origin = controlledOrigin(settings);
    ensure(typeof adminKey === 'string' && adminKey.length >= 32, 'Missing controlled receiver admin credential');
    this.path = path; this.runId = runId;
    this.manifest = { version: this.version, run_id: runId, base_url: this.origin.origin, state: 'pending' };
    this.client = new Client({ baseUrl: this.origin.origin, key: adminKey, redactor, signal, timeoutMs: 10000, trace });
  }
  async verify() {
    const { body } = await this.client.request('GET', '/_suite/identity', { key: '', expected: 200 });
    ensure(body.version === this.version && /^[0-9a-f-]{36}$/.test(body.instance_id), 'Controlled receiver identity differs');
    this.manifest.instance_id = body.instance_id;
    return body;
  }
  async create(spec) {
    atomicJson(this.path, this.manifest);
    const { body } = await this.client.request('PUT', `/_suite/runs/${this.runId}`, { expected: 201, body: spec });
    this.assertIdentity(body);
    this.manifest.state = 'created'; atomicJson(this.path, this.manifest);
  }
  assertIdentity(body) {
    ensure(body.id === this.runId && body.version === this.version && body.instance_id === this.manifest.instance_id, 'Controlled receiver run identity differs');
  }
  async evidence(signal) {
    const { body } = await this.client.request('GET', `/_suite/runs/${this.runId}`, { expected: 200, signal });
    this.assertIdentity(body);
    ensure(Array.isArray(body.observations), 'Receiver observations missing');
    return body.observations;
  }
  async cleanup(signal) {
    // UUID-scoped deletion is safe after a receiver restart; a reused origin
    // cannot make us delete a different run or accept different evidence.
    await this.client.request('DELETE', `/_suite/runs/${this.runId}`, { expected: 204, signal });
    await this.client.request('GET', `/_suite/runs/${this.runId}`, { expected: 404, signal });
    this.manifest.state = 'cleaned'; atomicJson(this.path, this.manifest);
  }
  loadCleanup() {
    const existing = JSON.parse(readFileSync(this.path));
    ensure(existing.version === this.version && existing.base_url === this.origin.origin && existing.run_id === this.runId &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(existing.run_id) &&
      ['pending', 'created', 'cleaned', 'discarded'].includes(existing.state), 'Receiver cleanup manifest does not match run and target');
    this.manifest = existing;
  }
}
