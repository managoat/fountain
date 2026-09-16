import { readFileSync } from 'node:fs';
import { Client } from './http.mjs';
import { atomicJson } from './fixtures.mjs';
import { RECEIVER_VERSION } from '../receivers/secrets.mjs';

const ensure = (ok, message) => { if (!ok) throw new Error(message); };
export function receiverOrigins(settings) {
  const urls = ['allowed_url', 'blocked_url'].map(key => {
    const url = new URL(settings[key]);
    ensure(url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash && url.pathname === '/' &&
      /^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/i.test(url.hostname) && !url.hostname.endsWith('.internal'),
    'Receiver URLs must be explicit HTTPS origins on public hostnames');
    return url;
  });
  ensure(urls[0].hostname !== urls[1].hostname, 'Allowed and blocked receiver hostnames must differ');
  return urls;
}

export class ReceiverSession {
  constructor({ settings, adminKey, path, runId, redactor, signal, trace = () => {} }) {
    const [allowed, blocked] = receiverOrigins(settings);
    ensure(typeof adminKey === 'string' && adminKey.length >= 32, 'Missing controlled receiver admin credential');
    this.allowed = allowed; this.blocked = blocked; this.path = path; this.runId = runId;
    this.manifest = { version: 1, run_id: runId, base_url: allowed.origin, state: 'pending' };
    this.client = new Client({ baseUrl: allowed.origin, key: adminKey, redactor, signal, trace: entry => trace({ origin: allowed.origin, ...entry }), timeoutMs: 10000 });
    this.publicClient = new Client({ baseUrl: blocked.origin, redactor, signal, trace: entry => trace({ origin: blocked.origin, ...entry }), timeoutMs: 10000 });
  }
  async verify() {
    const checks = await Promise.allSettled([
      this.client.request('GET', '/_suite/identity', { key: '', expected: 200 }),
      this.publicClient.request('GET', '/_suite/identity', { expected: 200 }),
    ]);
    for (const [index, check] of checks.entries()) if (check.status === 'rejected') throw new Error(`${index === 0 ? 'Allowed' : 'Blocked'} receiver identity check: ${check.reason.message}`);
    const [allowed, blocked] = checks.map(check => check.value);
    ensure(allowed.body.version === RECEIVER_VERSION && blocked.body.version === RECEIVER_VERSION &&
      typeof allowed.body.instance_id === 'string' && allowed.body.instance_id === blocked.body.instance_id,
    'Both HTTPS hosts must reach the same controlled receiver instance');
    this.instanceId = allowed.body.instance_id;
    return { version: RECEIVER_VERSION, instance_id: this.instanceId, allowed_origin: this.allowed.origin, blocked_origin: this.blocked.origin };
  }
  async create(spec) {
    atomicJson(this.path, this.manifest); // Lost replies retain cleanup intent.
    const { body } = await this.client.request('PUT', `/_suite/runs/${this.runId}`, { expected: 201, body: spec });
    ensure(body.id === this.runId && body.instance_id === this.instanceId && body.version === RECEIVER_VERSION, 'Receiver run identity differs');
    this.manifest.state = 'created'; this.manifest.expires_at = body.expires_at; atomicJson(this.path, this.manifest);
  }
  async evidence(signal) {
    const { body } = await this.client.request('GET', `/_suite/runs/${this.runId}`, { expected: 200, signal });
    ensure(body.id === this.runId && body.version === RECEIVER_VERSION && body.instance_id === this.instanceId && Array.isArray(body.observations), 'Receiver evidence identity differs');
    return body.observations;
  }
  async cleanup(signal) {
    await this.client.request('DELETE', `/_suite/runs/${this.runId}`, { expected: 204, signal });
    await this.client.request('GET', `/_suite/runs/${this.runId}`, { expected: 404, signal });
    this.manifest.state = 'cleaned'; atomicJson(this.path, this.manifest);
  }
  loadCleanup() {
    const existing = JSON.parse(readFileSync(this.path));
    ensure(existing.version === 1 && existing.base_url === this.allowed.origin && existing.run_id === this.runId &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(existing.run_id) &&
      ['pending', 'created', 'cleaned', 'discarded'].includes(existing.state), 'Receiver cleanup manifest does not match the configured run and target');
    this.manifest = existing;
  }
}
