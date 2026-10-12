import { isDeepStrictEqual } from 'node:util';
import { randomUUID } from 'node:crypto';
import { appendFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { ensure, phaseSignal, performTurn, watchUntil } from '../lib/execution.mjs';
import { McpReceiverSession } from '../lib/mcp-receiver.mjs';
import { SecretEvidence } from '../lib/secret-evidence.mjs';
import { fingerprint } from '../receivers/secrets.mjs';

export const MCP_AUTH_GAP = 'https://github.com/managoat/fountain/issues/1405';
export function mcpCoverage(runtime) {
  return ['claude', 'codex', 'gemini'].map(name => ({ runtime: name,
    static_bearer: name === runtime ? 'required_this_run' : 'not_run',
    conversation_auth: { status: 'gap', issue: MCP_AUTH_GAP,
      reason: 'Runtime-neutral conversation authentication and rotation are not covered by this static credential profile' } }));
}

export function verifyMcpTurn(turn, observations, { nonce, runId, deny }) {
  const calls = observations.filter(o => o.method === 'tools/call' && o.nonce === nonce);
  ensure(calls.length === (deny ? 2 : 1), 'MCP receiver did not observe exactly the expected tool calls');
  for (const [tool, outcome] of [['suite_nonce', 'accepted'], ...(deny ? [['suite_denied', 'denied']] : [])]) {
    const matching = calls.filter(o => o.tool === tool && o.outcome === outcome && o.principal === runId);
    ensure(matching.length === 1, 'MCP tool nonce, permitted fixture principal or denial differs');
    const row = matching[0];
    const discovery = observations.findIndex(o => o.method === 'tools/list' && o.session_id === row.session_id && o.principal === runId);
    ensure(discovery >= 0 && discovery < observations.indexOf(row), 'MCP call lacks independently observed preceding discovery');
    for (const [label, events] of [['durable', turn.stored], ['live', turn.events.map(f => f.event)]]) {
      const blocks = events.filter(e => e.turn_id === turn.turn.id).flatMap(e => e.blocks ?? []);
      const uses = blocks.filter(b => b.kind === 'tool_use' && typeof b.name === 'string' && b.name.endsWith(tool));
      ensure(uses.some(use => blocks.some(result => result.kind === 'tool_result' && result.tool_id === use.id &&
        JSON.stringify(result.body).includes(row.receipt_id) && JSON.stringify(result.body).includes(nonce) &&
        (outcome !== 'denied' || result.error === true))), `MCP ${label} tool result lacks the paired independent ${tool} receipt`);
    }
  }
  return calls;
}

export async function mcp(ctx) {
  const { config, report, client, fixtures, redactor, check } = ctx;
  report.mcp = { auth_mode: 'static_bearer', identity_kind: 'synthetic_per_run_principal', coverage: mcpCoverage(config.execution.runtime), observations: [] };
  report.execution = { runtime: config.execution.runtime, model: config.execution.model, sandbox_provider: config.execution.sandbox_provider,
    sandbox_mode: 'ephemeral', turns: [] };
  const token = `suite_mcp_${randomUUID()}`, nonces = [randomUUID(), randomUUID()];
  redactor.add(token);
  const evidence = new SecretEvidence([token]);
  client.assertPublicSafe = (body, source) => evidence.inspect(body, source);
  ctx.beforeCleanup.push(() => { evidence.throwOnLeak = false; });
  ctx.afterCleanup.push({ name: 'mcp/non-disclosure', run: async () => {
    report.mcp.inspection = { ...evidence.inspected, leaks: evidence.leaks };
    report.mcp.artifacts = evidence.scanArtifacts(ctx.out, redactor);
    ensure(evidence.leaks.length === 0, 'Public responses disclosed the MCP fixture credential');
  } });
  const receiver = new McpReceiverSession({ settings: config.mcp, adminKey: ctx.env[config.mcp.admin_credential], path: resolve(ctx.out, 'mcp-receiver.json'),
    runId: report.run_id, redactor, signal: ctx.signal,
    trace: entry => appendFileSync(resolve(ctx.out, 'mcp-http.jsonl'), JSON.stringify(redactor.value(entry)) + '\n', { mode: 0o600 }) });
  if (!await check('mcp/setup', async () => {
    const { body } = await client.request('GET', '/api/auth/me', { key: config.secondaryKey, expected: 200 });
    ensure(body.id !== report.owner_id && body.email_verified, 'MCP profile requires a distinct verified second tenant');
    report.mcp.receiver = await receiver.verify();
  })) { report.status = 'setup_failed'; report.mcp.failure_category = 'identity_or_receiver_setup'; return; }
  ctx.afterCleanup.push({ name: 'mcp/receiver-cleanup', run: async () => {
    await receiver.cleanup(AbortSignal.timeout(config.limits.cleanup_ms));
  } });
  ctx.afterCleanup.push({ name: 'mcp/receiver-final-evidence', run: async () => {
    if (receiver.manifest.state === 'created') {
      report.mcp.observations = await receiver.evidence(AbortSignal.timeout(10000));
      if (report.mcp.coverage.some(row => row.static_bearer === 'passed')) verifyFinalCalls(report.mcp.observations);
    }
  } });
  let environment, agent, conversation;
  if (!await check('mcp/public-configuration', async () => {
    await receiver.create({ credential_sha256: fingerprint(token), nonces });
    // A denied setup probe never performs discovery or a successful tool call.
    // All accepted MCP protocol evidence must originate from the runtime.
    await receiver.client.request('POST', `/mcp/${report.run_id}`, { key: `suite_mcp_${randomUUID()}`, expected: 401,
      body: { jsonrpc: '2.0', id: 1, method: 'tools/list' } });
    environment = await fixtures.create('environment');
    const key = `SUITE_MCP_${report.run_id.replaceAll('-', '').toUpperCase()}`;
    await client.request('POST', `/api/environments/${environment.id}/secrets`, { body: { key, value: token }, expected: 201 });
    const declared = { suite: { type: 'http', url: `${receiver.origin.origin}/mcp/${report.run_id}`, headers: { Authorization: `Bearer \${${key}}` } } };
    agent = await fixtures.create('agent', { runtime: config.execution.runtime, model: config.execution.model, environment_id: environment.id,
      sandbox_provider: config.execution.sandbox_provider, sandbox_mode: 'ephemeral', mcp_servers: declared,
      system: 'Use only the configured suite MCP tools for this bounded test. Never inspect credentials, use shell or HTTP clients, or fabricate receipts.', permission_policy: { default: 'auto_allow' } });
    const stored = await client.request('GET', `/api/agents/${agent.id}`, { expected: 200 });
    ensure(isDeepStrictEqual(stored.body.data.mcp_servers, declared), 'Stored public MCP configuration differs');
    await client.request('GET', `/api/agents/${agent.id}`, { key: config.secondaryKey, expected: 404 });
    await client.request('GET', `/api/environments/${environment.id}/secrets`, { key: config.secondaryKey, expected: 404 });
    conversation = await fixtures.create('conversation', { agent_id: agent.id, environment_id: environment.id });
    report.execution.conversation_id = conversation.id;
  })) { report.mcp.failure_category = 'configuration'; return; }
  let provision;
  if (!await check('mcp/provision', async () => {
    provision = await watchUntil(client, conversation.id, phaseSignal(ctx.signal, config.execution.provision_ms), e => e.kind === 'stage' && e.stage === 'provision' && e.state === 'done');
    const { body } = await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200 });
    conversation = body.data;
    ensure(conversation.sandbox?.status === 'ready' && conversation.sandbox.mode === 'ephemeral' && conversation.sandbox.provider === config.execution.sandbox_provider &&
      conversation.agent_id === agent.id && conversation.environment_id === environment.id, 'MCP conversation sandbox identity differs');
    report.execution.sandbox_id = conversation.sandbox_id;
  })) { report.mcp.failure_category = 'provision_or_network'; return; }
  let cursor = provision.cursor;
  for (let index = 0; index < 2; index++) {
    if (!await check(`mcp/turn-${index + 1}`, async () => {
      const nonce = nonces[index];
      const prompt = `Call the configured suite_nonce MCP tool exactly once with nonce ${nonce}. ${index === 0 ? `Then call suite_denied exactly once with that same nonce; its denial is expected.` : 'This is the follow-up turn; do not call suite_denied again.'} Return the actual receipt(s). Use the MCP tools directly; do not use shell, scripts, HTTP clients, or other tools.`;
      const turn = await performTurn(ctx, conversation, prompt, index + 1, cursor);
      cursor = turn.cursor;
      const observations = await receiver.evidence(ctx.signal);
      verifyMcpTurn(turn, observations, { nonce, runId: report.run_id, deny: index === 0 });
      report.mcp.observations = observations;
    })) {
      // Preserve the receiver's independent view to separate a connection/auth
      // failure from an executed call whose output never reached Fountain.
      try {
        const rows = await receiver.evidence(AbortSignal.timeout(10000)); report.mcp.observations = rows;
        report.mcp.failure_category = rows.some(r => r.method === 'tools/call') ? 'tool_or_event_contract' :
          rows.some(r => r.method === 'initialize') ? 'discovery_or_runtime' : 'auth_or_network';
      } catch { report.mcp.failure_category = 'receiver_network'; }
      return;
    }
  }
  await check('mcp/final-evidence', async () => {
    const rows = await receiver.evidence(ctx.signal);
    verifyFinalCalls(rows);
    report.mcp.observations = rows;
    const { body } = await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200 });
    report.execution.usage_total = body.data.usage_total;
    report.mcp.coverage.find(row => row.runtime === config.execution.runtime).static_bearer = 'passed';
  });
}

function verifyFinalCalls(rows) {
  ensure(rows.filter(r => r.method === 'tools/call').length === 3 && rows.filter(r => r.outcome === 'unauthorized').length === 1,
    'MCP receiver observed unexpected calls or rejected runtime authentication');
}
