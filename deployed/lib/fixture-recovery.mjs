// Recovery reconstructs evidence; Fixtures remains the only cleanup executor.
import { Fixtures, atomicJson } from './fixtures.mjs';

const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value);
const kinds = { environment: '/api/environments', vault: '/api/vaults', agent: '/api/agents', api_key: '/api/auth/api-keys', conversation: '/api/conversations' };
const note = value => typeof value === 'string' && value.trim().length >= 12 && value.length <= 2000;
const need = (condition, message) => { if (!condition) throw new Error(message); };
const marker = (kind, row) => kind === 'conversation' ? row.channel_id : row.name;
const exactName = (kind, name, runId) => typeof name === 'string' &&
  new RegExp(`^suite-${runId}-${kind}-(?:0|[1-9][0-9]?)$`).test(name);
const related = (row, resources) => resources.some(r => r.id &&
  (row.agent_id === r.id || row.environment_id === r.id || row.vault_id === r.id ||
    (r.kind === 'environment' && Array.isArray(row.allowed_environment_ids) && row.allowed_environment_ids.includes(r.id)) ||
    (r.kind === 'vault' && Array.isArray(row.allowed_vault_ids) && row.allowed_vault_ids.includes(r.id)) ||
    (r.kind === 'conversation' && row.parent_conversation_id === r.id)));

export async function recoveryIdentity(client, ownerId) {
  need(uuid(ownerId), 'Supply the dedicated suite account UUID');
  const { body } = await client.request('GET', '/api/auth/me', { expected: 200, recordBody: false });
  need(body.id === ownerId && body.email_verified === true, 'Recovery account differs or is not verified');
}

async function list(client, path, signal) {
  const { body } = await client.request('GET', path, { expected: 200, recordBody: false, signal });
  return inventoryRows(body);
}

function inventoryRows(body) {
  need(Array.isArray(body?.data) && body.data.length <= 1000 && body.data.every(row => uuid(row.id)), 'Invalid or oversized recovery inventory');
  // These public collections are unpaged. A future paged response needs an
  // explicit implementation, never an optimistic first-page cleanup verdict.
  need(!body.next && !body.next_cursor && !body.has_more && !body.meta?.next && !body.meta?.has_more, 'Paginated recovery inventory is unsupported');
  return body.data;
}

async function verifyBuzzDependencies(client, resources, recovery, signal) {
  const { status, body } = await client.request('GET', '/api/buzz/agents', { expected: [200, 404], recordBody: false, signal });
  if (status === 404) {
    // The dispatcher gives the same 404 for absent and disabled extensions.
    // Disabled routes do not prove their stored FK references disappeared.
    need(body?.error === 'Not found' && body.reason === 'not_found' && note(recovery.buzz_absence_evidence),
      'Buzz inventory unavailable; record operator-verified absence of stored Buzz dependencies or escalate');
    return;
  }
  for (const row of inventoryRows(body)) {
    need(uuid(row.agent_id) && uuid(row.vault_id) && (row.environment_id === null || uuid(row.environment_id)), 'Invalid Buzz identity dependency evidence');
    need(!related(row, resources), 'Unrecorded Buzz identity depends on recovery fixtures; retain parents and escalate');
  }
}

async function verifyQueueDependencies(client, recovery, signal) {
  // Neither list nor detail exposes source overrides or conversation parents.
  // A different agent cannot prove independence, even for source-only recovery.
  need((await list(client, '/api/sandbox-queue', signal)).length === 0,
    'Unrecorded queued requests have undisclosed dependencies; retain recovery fixtures and escalate until the account queue settles');
  // The list also omits claimed/starting work. Require new account-wide evidence
  // on every pass; the former agent-scoped queue_settlement_evidence is unsafe.
  need(note(recovery.queue_account_settlement_evidence),
    'Record account-wide queue settlement evidence, including source overrides and parent conversations; escalate unknown request outcomes');
}

export async function inventoryFixtures(client, { ownerId, runId }) {
  need(uuid(runId), 'Supply the exact run UUID, not a suite prefix');
  await recoveryIdentity(client, ownerId);
  const resources = [];
  for (const [kind, path] of Object.entries(kinds)) {
    for (const row of await list(client, path)) {
      if (!exactName(kind, marker(kind, row), runId)) continue;
      const r = { kind, name: marker(kind, row), id: row.id };
      if (kind === 'conversation') Object.assign(r, {
        agent_id: row.agent_id, environment_id: row.environment_id,
        vault_id: row.vault_id ?? null, sandbox_id: row.sandbox_id ?? null,
        sandbox_mode: row.sandbox?.mode ?? null,
      });
      resources.push(r);
    }
  }
  resources.sort((a, b) => Number(a.name.split('-').at(-1)) - Number(b.name.split('-').at(-1)));
  return { version: 1, base_url: client.baseUrl, owner_id: ownerId, run_id: runId,
    profiles: [], ownership_evidence: '', writers_stopped: '', intent_inventory: '', buzz_absence_evidence: '', queue_account_settlement_evidence: '', resources };
}

export function validateRecoveryEvidence(evidence, baseUrl) {
  need(evidence?.version === 1 && evidence.base_url === baseUrl && uuid(evidence.owner_id) && uuid(evidence.run_id), 'Recovery target, account or run identity is invalid');
  need(Array.isArray(evidence.profiles) && evidence.profiles.length > 0 &&
    evidence.profiles.every(p => ['basic', 'execution', 'streaming', 'deterministic'].includes(p)),
  'Journal reconstruction supports basic, execution, streaming and deterministic only; escalate other profiles');
  for (const field of ['ownership_evidence', 'writers_stopped', 'intent_inventory']) need(note(evidence[field]), `Record ${field} before reconstructing cleanup`);
  if (evidence.buzz_absence_evidence !== undefined && evidence.buzz_absence_evidence !== '') {
    need(note(evidence.buzz_absence_evidence), 'Invalid Buzz absence evidence');
  }
  need(Array.isArray(evidence.resources) && evidence.resources.length > 0 && evidence.resources.length <= 100, 'Recovery requires one to one hundred exact create intents');
  const names = new Set(), ids = new Set(), slots = new Set();
  for (const r of evidence.resources) {
    need(Object.hasOwn(kinds, r.kind) && exactName(r.kind, r.name, evidence.run_id), 'Invalid exact fixture name or unsupported kind');
    const slot = r.name.split('-').at(-1);
    need(!names.has(r.name) && !slots.has(slot) && (r.id === undefined || uuid(r.id) && !ids.has(r.id)), 'Duplicate or invalid recovery identity');
    names.add(r.name); slots.add(slot); if (r.id) ids.add(r.id);
    if (r.kind === 'conversation') {
      need(uuid(r.agent_id) && uuid(r.environment_id) && (r.vault_id === null || uuid(r.vault_id)) &&
        (r.sandbox_id === null || uuid(r.sandbox_id)) && ['ephemeral', 'persistent'].includes(r.sandbox_mode),
      'Conversation needs explicit parents, vault, sandbox identity (or null) and mode');
    }
  }
}

// Fail before producing an executable manifest if the proposed parents also
// own unrecorded work. This is intentionally a refusal, not an orphan sweeper.
export async function verifyRecoveryDependencies(client, resources, runId, signal, recovery = {}) {
  for (const [kind, path] of Object.entries(kinds)) {
    const rows = await list(client, path, signal);
    for (const row of rows) {
      const record = resources.find(r => r.kind === kind && (r.id === row.id || r.name === marker(kind, row)));
      if (!record) {
        need(kind !== 'agent' || !related(row, resources), 'Unrecorded agent depends on recovery fixtures');
        need(!exactName(kind, marker(kind, row), runId), 'Unrecorded run fixture; complete the intent inventory before cleanup');
        continue;
      }
      need(record.name === marker(kind, row) && (!record.id || record.id === row.id) && record.state !== 'cleaned', 'Fixture ownership changed or a cleaned fixture reappeared');
      // A late create becomes owned only by the already-recorded exact name.
      // Persisted by Fixtures before its first deletion or by reconstruction.
      record.id = row.id; record.state = 'created';
    }
  }
  await verifyBuzzDependencies(client, resources, recovery, signal);
  await verifyQueueDependencies(client, recovery, signal);
  const ids = new Set(resources.map(r => r.id).filter(Boolean));
  const conversations = await list(client, '/api/conversations', signal);
  for (const row of conversations) {
    if (related(row, resources) || exactName('conversation', row.channel_id, runId)) {
      need(ids.has(row.id), 'Unrecorded conversation depends on recovery fixtures; retain parents and escalate');
      need(row.parent_conversation_id == null, 'Child conversations require operator escalation');
    }
  }
  const sandboxes = await list(client, '/api/sandboxes', signal);
  const recordedSandboxes = new Set(resources.filter(r => r.kind === 'conversation').map(r => r.sandbox_id).filter(Boolean));
  const deletedParents = new Set();
  for (const row of sandboxes.filter(row => recordedSandboxes.has(row.id) || related(row, resources))) {
    const records = resources.filter(r => r.kind === 'conversation' && r.sandbox_id === row.id);
    need(records.length > 0, 'Unrecorded sandbox depends on recovery fixtures; retain parents and escalate');
    const terminal = ['terminated', 'failed'].includes(row.status);
    need(terminal || records.some(r => r.state !== 'cleaned'), 'A cleaned conversation still has a live sandbox');
    for (const r of records) {
      need(row.mode === r.sandbox_mode, 'Sandbox ownership or mode differs');
      for (const kind of ['agent', 'environment', 'vault']) {
        const field = `${kind}_id`, expected = r[field] ?? null;
        if ((row[field] ?? null) === expected) continue;
        // Parent deletion nilifies terminal sandbox history. Accept only an
        // explicit null on this exact sandbox, with a fresh 404 for the
        // recorded parent; journal state or collection absence is not proof.
        need(terminal && row[field] === null && resources.some(parent => parent.kind === kind && parent.id === expected), 'Sandbox ownership or mode differs');
        if (!deletedParents.has(expected)) {
          const parent = await client.request('GET', `${kinds[kind]}/${expected}`, { expected: [200, 404], recordBody: false, signal });
          need(parent.status === 404, 'Sandbox parent reference is null but the recorded parent still exists');
          deletedParents.add(expected);
        }
      }
    }
    need(Array.isArray(row.conversations) && row.conversations.every(c => ids.has(c.id)), 'Sandbox has an unrecorded co-tenant');
  }
  for (const r of resources.filter(r => r.kind === 'agent' && r.id && r.state !== 'cleaned')) {
    const parent = await client.request('GET', `/api/agents/${r.id}`, { expected: [200, 404], recordBody: false, signal });
    if (parent.status === 404) continue;
    need(parent.body.data?.name === r.name, 'Agent ownership marker changed');
    need((await list(client, `/api/team/${r.id}/schedules`, signal)).length === 0, 'Agent has a schedule; use schedule recovery and retain parents');
  }
}

export async function reconstructFixtures(client, evidence, manifestPath) {
  validateRecoveryEvidence(evidence, client.baseUrl);
  await recoveryIdentity(client, evidence.owner_id);
  const resources = [];
  for (const r of evidence.resources) {
    const rows = await list(client, kinds[r.kind]);
    const matches = rows.filter(row => marker(r.kind, row) === r.name);
    need(matches.length <= 1, 'Ambiguous exact fixture name; refusing recovery');
    const row = matches[0];
    need(!r.id || !rows.some(value => value.id === r.id && marker(r.kind, value) !== r.name), 'Recorded fixture ID has changed ownership marker');
    need(!row || !r.id || row.id === r.id, 'Fixture ID differs from operator evidence');
    const record = { kind: r.kind, name: r.name, state: row || r.id ? 'created' : 'pending' };
    if (row || r.id) record.id = row?.id ?? r.id;
    if (r.kind === 'conversation') {
      for (const field of ['agent_id', 'environment_id', 'sandbox_mode']) record[field] = r[field];
      record.vault_id = r.vault_id;
      if (r.sandbox_id) record.sandbox_id = r.sandbox_id;
      if (row) {
        // The list is enough to discover an ID, never enough to authorize its
        // sandbox. Read its current detail before rebuilding the journal.
        const { body } = await client.request('GET', `/api/conversations/${row.id}`, { expected: 200, recordBody: false });
        const value = body.data;
        need(value?.id === row.id && value.channel_id === r.name && value.agent_id === r.agent_id &&
          value.environment_id === r.environment_id && (value.vault_id ?? null) === r.vault_id &&
          value.parent_conversation_id == null, 'Conversation ownership differs');
        need(!r.sandbox_id || r.sandbox_id === value.sandbox_id, 'Conversation sandbox identity differs');
        if (value.sandbox_id) {
          need(uuid(value.sandbox_id) && value.sandbox?.id === value.sandbox_id && value.sandbox.mode === r.sandbox_mode,
            'Conversation sandbox mode or identity differs');
          record.sandbox_id = value.sandbox_id;
        }
      }
    }
    resources.push(record);
  }
  // Parents before their dependents, regardless of order in operator evidence.
  resources.sort((a, b) => Number(a.kind === 'conversation') - Number(b.kind === 'conversation') ||
    Number(a.name.split('-').at(-1)) - Number(b.name.split('-').at(-1)));
  for (const r of resources.filter(r => r.kind === 'conversation')) {
    for (const kind of ['agent', 'environment', ...(r.vault_id ? ['vault'] : [])]) {
      need(resources.some(parent => parent.kind === kind && parent.id === r[`${kind}_id`]), 'Conversation parent is missing from the exact intent inventory');
    }
  }
  await verifyRecoveryDependencies(client, resources, evidence.run_id, undefined, evidence);
  const manifest = { version: 1, base_url: client.baseUrl, owner_id: evidence.owner_id, run_id: evidence.run_id, resources,
    recovery: { version: 1, ...Object.fromEntries(['profiles', 'ownership_evidence', 'writers_stopped', 'intent_inventory', 'buzz_absence_evidence', 'queue_account_settlement_evidence'].map(k => [k, evidence[k]])) } };
  atomicJson(manifestPath, manifest);
  // Use the cleanup reader as the final check, including its parent rules.
  Fixtures.load(manifestPath, client, evidence.owner_id);
  return manifest;
}
