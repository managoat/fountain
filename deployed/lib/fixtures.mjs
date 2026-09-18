import { writeFileSync, renameSync, readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { cleanupSchedule, validateScheduleManifest } from './scheduled-fixtures.mjs';
import { cleanupCredential, validateCredentialManifest } from './browser-credentials.mjs';

const collections = { agent: '/api/agents', environment: '/api/environments', vault: '/api/vaults', binding: '/api/secret-bindings', api_key: '/api/auth/api-keys', conversation: '/api/conversations', webhook: '/api/webhooks' };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const marker = (kind, value) => kind === 'webhook' ? value.description : kind === 'binding' ? value.key : kind === 'conversation' ? value.channel_id : value.name;
const prefix = (kind, runId) => kind === 'binding' ? `SUITE_${runId.replaceAll('-', '').toUpperCase()}_BINDING_` : `suite-${runId}-`;

export function atomicJson(path, value) {
  const temp = `${path}.${randomUUID()}.tmp`;
  writeFileSync(temp, JSON.stringify(value, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  renameSync(temp, path);
}

export class Fixtures {
  constructor(path, client, { runId, baseUrl, ownerId, maxResources = 20, existing } = {}) {
    this.path = path;
    this.client = client;
    this.maxResources = maxResources;
    this.manifest = existing ?? { version: 1, run_id: runId, base_url: baseUrl, owner_id: ownerId, resources: [] };
    this.save();
  }
  static load(path, client, ownerId) {
    const existing = JSON.parse(readFileSync(path, 'utf8'));
    if (existing.version !== 1 || existing.base_url !== client.baseUrl || existing.owner_id !== ownerId ||
        !uuid.test(existing.run_id) || !Array.isArray(existing.resources) || existing.resources.length > 100) {
      throw new Error('Cleanup manifest version, target, owner, run ID, or resource count does not match');
    }
    for (const r of existing.resources) {
      if (!collections[r.kind] || typeof r.name !== 'string' || !r.name.startsWith(prefix(r.kind, existing.run_id)) ||
          (r.id !== undefined && !uuid.test(r.id)) || !['pending', 'created', 'cleaned'].includes(r.state)) {
        throw new Error('Invalid cleanup resource; refusing the manifest');
      }
      if (r.kind === 'binding' && (typeof r.host !== 'string' || !r.host.length)) throw new Error('Binding manifest lacks host ownership evidence');
      if (r.kind === 'webhook' && (typeof r.url !== 'string' || !r.url.startsWith('https://'))) throw new Error('Webhook manifest lacks target ownership evidence');
      if (r.kind === 'conversation') {
        if (r.sandbox_mode !== undefined && !['ephemeral', 'persistent'].includes(r.sandbox_mode)) throw new Error('Invalid recorded sandbox mode');
        if (![r.agent_id, r.environment_id].every(id => uuid.test(id)) ||
            (r.sandbox_id !== undefined && !uuid.test(r.sandbox_id)) ||
            !existing.resources.some(item => item.kind === 'agent' && item.id === r.agent_id) ||
            !existing.resources.some(item => item.kind === 'environment' && item.id === r.environment_id)) {
          throw new Error('Conversation manifest must reference recorded agent/environment fixtures');
        }
        if (r.vault_id != null && (!uuid.test(r.vault_id) || !existing.resources.some(item => item.kind === 'vault' && item.id === r.vault_id))) throw new Error('Conversation must reference a recorded vault');
      }
    }
    validateScheduleManifest(existing);
    validateCredentialManifest(existing);
    return new Fixtures(path, client, { existing });
  }
  save() { atomicJson(this.path, this.manifest); }
  remainingCount() {
    const s = this.manifest.schedule;
    return this.manifest.resources.filter(r => r.state !== 'cleaned').length +
      (s ? Number(s.state !== 'cleaned') + s.conversations.filter(c => c.state !== 'cleaned').length : 0) +
      Number(Boolean(this.manifest.browser_credential && this.manifest.browser_credential.state !== 'cleaned'));
  }
  async create(kind, attrs = {}) {
    if (!collections[kind]) throw new Error('Unsupported fixture kind');
    if (this.manifest.resources.length + (this.manifest.schedule ? 2 : 0) + Number(Boolean(this.manifest.browser_credential)) >= this.maxResources) throw new Error('Fixture resource budget exhausted');
    const resource = { kind, name: `suite-${this.manifest.run_id}-${kind}-${this.manifest.resources.length}`, state: 'pending' };
    if (kind === 'webhook') {
      if (typeof attrs.url !== 'string' || !attrs.url.startsWith('https://')) throw new Error('Webhook requires an explicit HTTPS target');
      resource.url = attrs.url;
    }
    if (kind === 'binding') {
      resource.name = `${prefix(kind, this.manifest.run_id)}${this.manifest.resources.length}`;
      if (typeof attrs.host !== 'string' || !attrs.host.length) throw new Error('Binding requires an explicit host');
      resource.host = attrs.host;
    }
    if (kind === 'conversation') {
      for (const parent of ['agent', 'environment']) {
        const id = attrs[`${parent}_id`];
        if (!this.manifest.resources.some(r => r.kind === parent && r.id === id && r.state === 'created')) throw new Error('Conversation must use run-owned agent and environment');
        resource[`${parent}_id`] = id;
      }
      if (attrs.vault_id !== undefined) {
        if (!this.manifest.resources.some(r => r.kind === 'vault' && r.id === attrs.vault_id && r.state === 'created')) throw new Error('Conversation must use a run-owned vault');
        resource.vault_id = attrs.vault_id;
      }
      if (attrs.prompt !== undefined || attrs.sandbox_id !== undefined) throw new Error('Create conversation without inference or an existing sandbox');
      resource.sandbox_mode = attrs.sandbox_mode ?? 'ephemeral';
      if (!['ephemeral', 'persistent'].includes(resource.sandbox_mode)) throw new Error('Invalid sandbox mode');
    }
    this.manifest.resources.push(resource);
    this.save(); // Intent survives a response lost after the server commits.
    const result = await this.client.request('POST', collections[kind], {
      body: kind === 'conversation' ? { ...attrs, title: resource.name, channel_id: resource.name, sandbox_mode: resource.sandbox_mode } : kind === 'binding' ? { ...attrs, key: resource.name } : kind === 'webhook' ? { ...attrs, description: resource.name } : { ...attrs, name: resource.name }, validate: false,
    });
    if (result.status >= 400 && result.status < 500) {
      resource.state = 'cleaned'; this.save();
      throw new Error(`Create ${kind}: received ${result.status}`);
    }
    const value = ['api_key', 'binding'].includes(kind) ? result.body : result.body?.data;
    if (result.status !== 201 || !uuid.test(value?.id)) throw new Error(`Create ${kind}: no successful resource identity; cleanup intent retained`);
    resource.id = value.id;
    if (kind === 'conversation' && value.sandbox_id) resource.sandbox_id = value.sandbox_id;
    resource.state = 'created';
    this.save(); // Record ID before schema assertions can fail.
    this.client.contract?.check('POST', collections[kind], result.status, result.body);
    if (marker(kind, value) !== resource.name || (kind === 'binding' && value.host !== resource.host) || (kind === 'webhook' && value.url !== resource.url)) throw new Error(`Create ${kind}: returned ownership marker differs; cleanup will require ownership evidence`);
    return kind === 'webhook' ? { ...value, secret: result.body.secret } : value;
  }
  reserveTurn(id, maxTurns) {
    const r = this.manifest.resources.find(r => r.kind === 'conversation' && r.id === id && r.state === 'created');
    if (!r) throw new Error('Inference requires a recorded conversation');
    const attempts = this.manifest.inference_attempts ?? 0;
    if (attempts >= maxTurns) throw new Error('Inference turn budget exhausted');
    this.manifest.inference_attempts = attempts + 1;
    this.save(); // Lost prompt replies still consume the budget; never auto-retry.
  }
  async terminateConversation(r, value, signal, { preserveHome = false } = {}) {
    if (value.agent_id !== r.agent_id || value.environment_id !== r.environment_id || value.channel_id !== r.name) throw new Error('Conversation ownership evidence differs');
    if (r.vault_id !== undefined && value.vault_id !== r.vault_id) throw new Error('Conversation vault ownership differs');
    if (value.sandbox && value.sandbox.mode !== (r.sandbox_mode ?? 'ephemeral')) throw new Error('Refusing to clean a sandbox with an unrecorded mode');
    if (value.sandbox_id) {
      if (r.sandbox_id && r.sandbox_id !== value.sandbox_id) throw new Error('Conversation sandbox identity changed');
      r.sandbox_id = value.sandbox_id; this.save();
    }
    while (true) {
      signal?.throwIfAborted();
      const response = await this.client.request('POST', `/api/conversations/${r.id}/terminate`, { expected: [204, 404, 503], validate: false, signal });
      if (response.status !== 503) break;
      await sleep(500, undefined, { signal });
    }
    const conv = await this.client.request('GET', `/api/conversations/${r.id}`, { expected: [200, 404], validate: false, signal });
    if (conv.status === 200 && !['terminated', 'failed'].includes(conv.body.data?.status)) throw new Error('Conversation did not terminate');
    if (r.sandbox_id) {
      await this.cleanSandbox(r, signal, { preserveHome });
    }
  }
  async cleanSandbox(r, signal, { preserveHome = false } = {}) {
    const path = `/api/sandboxes/${r.sandbox_id}`;
    let sandbox = await this.client.request('GET', path, { expected: [200, 404], validate: false, signal });
    if (sandbox.status === 404) {
      if (preserveHome) throw new Error('Persistent home disappeared with its conversation');
      return;
    }
    const value = sandbox.body.data;
    if (value?.agent_id !== r.agent_id) throw new Error('Run-owned sandbox has changed owner');
    if (r.sandbox_mode === 'persistent') {
      if (value.mode !== 'persistent' || value.environment_id !== r.environment_id) throw new Error('Persistent sandbox ownership differs');
      if (preserveHome) {
        if (!['ready', 'suspended'].includes(value.status)) throw new Error('Persistent home did not survive termination');
        return;
      }
      if (!['terminated', 'failed'].includes(value.status)) {
        // The identity and environment were created by this run, before its
        // conversation. Never reset an arbitrary home supplied by a caller.
        await this.client.request('DELETE', path, { expected: [204, 404], validate: false, signal });
        sandbox = await this.client.request('GET', path, { expected: [200, 404], validate: false, signal });
      }
    }
    if (sandbox.status === 200 && (sandbox.body.data?.agent_id !== r.agent_id || !['terminated', 'failed'].includes(sandbox.body.data?.status))) throw new Error('Run-owned sandbox is still live or has changed owner');
  }
  async cleanup(signal) {
    if (this.manifest.recovery) {
      // Recheck reconstructed evidence on every replay, before any mutation.
      // A newly visible create or co-tenant must not lose its parent evidence.
      try {
        const { validateRecoveryEvidence, verifyRecoveryDependencies } = await import('./fixture-recovery.mjs');
        validateRecoveryEvidence({ ...this.manifest, ...this.manifest.recovery,
          resources: this.manifest.resources.map(r => r.kind === 'conversation'
            ? { ...r, vault_id: r.vault_id ?? null, sandbox_id: r.sandbox_id ?? null } : r) }, this.client.baseUrl);
        await verifyRecoveryDependencies(this.client, this.manifest.resources, this.manifest.run_id, signal, this.manifest.recovery);
      } catch (error) { return [{ kind: 'recovery', error: error.message }]; }
    }
    const failures = await cleanupSchedule(this, signal);
    // Stop outbound sources before conversation teardown can emit more events.
    const resources = [...this.manifest.resources].reverse();
    resources.sort((a, b) => Number(b.kind === 'webhook') - Number(a.kind === 'webhook'));
    const isSource = r => ['environment', 'vault'].includes(r.kind);
    // Reconstructed agent intents may lack their submitted source references.
    // Reconcile every agent before sources, including across combined profiles.
    if (this.manifest.recovery) resources.sort((a, b) => Number(isSource(a)) - Number(isSource(b)));
    for (const r of resources) {
      if (r.state === 'cleaned') continue;
      try {
        const source = this.manifest.schedule;
        if (source && source.state !== 'cleaned' && [source.agent_id, source.environment_id].includes(r.id)) throw new Error('Retaining parent fixture until schedule cleanup succeeds');
        if (r.kind !== 'conversation' && this.manifest.resources.some(child => child.kind === 'conversation' && child.state !== 'cleaned' && (r.kind === 'binding' || [child.agent_id, child.environment_id, child.vault_id].includes(r.id)))) throw new Error('Retaining parent fixture until conversation cleanup succeeds');
        if (this.manifest.recovery && isSource(r) && this.manifest.resources.some(agent => agent.kind === 'agent' && agent.state !== 'cleaned')) throw new Error('Retaining source fixture until all recovered agents are cleaned');
        signal?.throwIfAborted();
        const collection = collections[r.kind];
        let value;
        if (!r.id || ['api_key', 'binding'].includes(r.kind)) {
          const listPath = r.kind === 'conversation' ? `${collection}?agent_id=${r.agent_id}` : collection;
          const response = await this.client.request('GET', listPath, { expected: 200, validate: false, recordBody: false, signal });
          if (!Array.isArray(response.body?.data)) throw new Error('Cannot read cleanup ownership evidence');
          const matches = response.body.data.filter(item => r.id ? item.id === r.id : marker(r.kind, item) === r.name);
          if (matches.length > 1) throw new Error('Ambiguous cleanup intent');
          value = matches[0];
          if (!value && !r.id) throw new Error('Unresolved create intent; retry cleanup after the server settles');
        } else {
          const response = await this.client.request('GET', `${collection}/${r.id}`, { expected: [200, 404], validate: false, signal });
          value = response.status === 404 ? undefined : response.body?.data;
          if (response.status === 200 && !value) throw new Error('Missing cleanup ownership evidence');
        }
        if (value) {
          if (marker(r.kind, value) !== r.name || !uuid.test(value.id) || (r.kind === 'binding' && value.host !== r.host) || (r.kind === 'webhook' && value.url !== r.url)) throw new Error('Cleanup ownership evidence does not match');
          r.id = value.id; this.save();
          if (r.kind === 'webhook') {
            // Even a failed/lost disable reply must not prevent deletion. The
            // subsequent DELETE and read-back establish that delivery stopped.
            await this.client.request('PATCH', `${collection}/${r.id}`, { body: { status: 'disabled' }, expected: [200, 404], validate: false, signal }).catch(() => {});
          }
          if (r.kind === 'conversation') await this.terminateConversation(r, value, signal);
          await this.client.request('DELETE', `${collection}/${r.id}`, { expected: [204, 404], validate: false, signal });
          if (r.kind === 'webhook') await this.client.request('GET', `${collection}/${r.id}`, { expected: 404, validate: false, signal });
        }
        if (r.kind === 'conversation' && !value && r.sandbox_id) {
          await this.cleanSandbox(r, signal);
        }
        r.state = 'cleaned'; this.save();
      } catch (error) { failures.push({ kind: r.kind, id: r.id, error: error.message }); }
    }
    failures.push(...await cleanupCredential(this, signal));
    return failures;
  }
}
