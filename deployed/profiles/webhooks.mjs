import { appendFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { isDeepStrictEqual } from 'node:util';
import { ensure, phaseSignal, watchUntil } from '../lib/execution.mjs';
import { ControlledReceiverSession } from '../lib/controlled-receiver.mjs';
import { SecretEvidence } from '../lib/secret-evidence.mjs';
import { WEBHOOK_VERSION } from '../receivers/webhooks.mjs';

export function verifyWebhookDeliveries(observations, deliveries, event, conversation) {
  ensure(observations.length >= 2, 'Receiver has not observed a transient failure and retry');
  const failed = observations.filter(o => o.status === 503);
  ensure(failed.length === 1 && observations.some(o => o.status === 200 && o.attempt > failed[0].attempt), 'No automatic later delivery attempt followed the controlled 503');
  ensure(new Set(deliveries.map(d => d.id)).size === deliveries.length, 'Public delivery record IDs are not unique');
  for (const row of observations) {
    ensure(row.signature_valid && row.payload_valid && row.headers_match && [503, 200].includes(row.status), 'Receiver rejected a signature, payload or delivery header');
    const expected = { id: String(event.id), type: 'conversation.terminate.done', created_at: event.ts, data: {
      conversation_id: conversation.id, agent_id: conversation.agent_id, parent_conversation_id: null,
      status: row.payload.data.status, stage: event.stage, state: event.state, turn_id: event.turn_id, duration_ms: event.duration_ms,
      // The conversation's own labels, as the public API serves them: the
      // webhook must carry exactly those, since #1637 put them in the envelope.
      labels: conversation.labels ?? {} } };
    ensure(isDeepStrictEqual(row.payload, expected), 'Signed webhook payload differs from the public conversation event');
    ensure(deliveries.some(d => {
      let body; try { body = JSON.parse(d.response_body); } catch { return false; }
      return d.event_id === String(event.id) && d.event_type === expected.type && d.attempt === row.attempt &&
        d.status_code === row.status && body.receipt_id === row.receipt_id;
    }), 'Receiver receipt has no matching public delivery attempt');
  }
  for (const d of deliveries) ensure(observations.some(o => o.payload?.id === d.event_id && o.attempt === d.attempt && o.status === d.status_code &&
    d.response_body?.includes(o.receipt_id)), 'Public delivery attempt has no matching receiver evidence');
  const groups = Object.groupBy(deliveries, d => `${d.event_id}/${d.attempt}`);
  return { event_id: String(event.id), delivery_ids: deliveries.map(d => d.id), attempts: deliveries.map(d => d.attempt),
    repeated_event_deliveries: deliveries.length - 1, repeated_attempt_records: Object.values(groups).reduce((n, rows) => n + rows.length - 1, 0),
    semantics: 'at_least_once_unordered', receiver_receipts: observations.map(o => o.receipt_id) };
}

export function webhookEvidenceSettled(observations, deliveries) {
  // The receiver answers before Fountain commits the public attempt record.
  // A snapshot between those writes is incomplete evidence, not lost delivery.
  return observations.every(o => deliveries.some(d => d.response_body?.includes(o.receipt_id))) &&
    deliveries.every(d => observations.some(o => d.response_body?.includes(o.receipt_id)));
}

export async function webhooks(ctx) {
  const { client, config, report, fixtures, redactor, check } = ctx;
  report.webhooks = { required: { endpoint_api: 'required', signed_delivery: 'required', automatic_retry: 'required' }, observations: [], deliveries: [] };
  const receiver = new ControlledReceiverSession({ settings: config.webhooks, adminKey: ctx.env[config.webhooks.admin_credential],
    version: WEBHOOK_VERSION, path: resolve(ctx.out, 'webhook-receiver.json'), runId: report.run_id, redactor, signal: ctx.signal,
    trace: entry => appendFileSync(resolve(ctx.out, 'webhook-http.jsonl'), JSON.stringify(redactor.value(entry)) + '\n', { mode: 0o600 }) });
  const evidence = new SecretEvidence([]);
  client.assertPublicSafe = (body, source) => evidence.inspect(body, source);
  ctx.beforeCleanup.push(() => { evidence.throwOnLeak = false; });
  ctx.afterCleanup.push({ name: 'webhooks/non-disclosure', run: async () => {
    report.webhooks.inspection = { ...evidence.inspected, leaks: evidence.leaks };
    report.webhooks.artifacts = evidence.scanArtifacts(ctx.out, redactor);
    ensure(evidence.leaks.length === 0, 'Public responses disclosed the webhook signing secret after creation');
  } });
  if (!await check('webhooks/setup', async () => {
    const { body } = await client.request('GET', '/api/auth/me', { key: config.secondaryKey, expected: 200 });
    ensure(body.id !== report.owner_id && body.email_verified, 'Webhooks require a distinct verified second tenant');
    await client.request('GET', '/api/webhooks', { expected: 200 });
    report.webhooks.required.endpoint_api = 'passed';
    report.webhooks.receiver = await receiver.verify();
  })) { report.status = 'setup_failed'; report.webhooks.failure_category = 'endpoint_or_receiver_setup'; return; }
  let conversation, endpoint, event;
  ctx.beforeCleanup.push(async () => {
    if (receiver.manifest.state !== 'created') return;
    try {
      const signal = AbortSignal.timeout(15000);
      const observations = await receiver.evidence(signal);
      const { body } = await client.request('GET', `/api/webhooks/${endpoint.id}/deliveries?limit=200`, { expected: 200, signal });
      report.webhooks.cleanup_snapshot = { observations, deliveries: body.data, recorded_at: new Date().toISOString() };
    } catch (error) { report.webhooks.final_evidence_error = redactor.text(error.message); }
  });
  if (!await check('webhooks/conversation', async () => {
    const environment = await fixtures.create('environment');
    const agent = await fixtures.create('agent', { environment_id: environment.id, runtime: config.execution.runtime, model: config.execution.model,
      sandbox_provider: config.execution.sandbox_provider, sandbox_mode: 'ephemeral' });
    conversation = await fixtures.create('conversation', { agent_id: agent.id, environment_id: environment.id });
    await watchUntil(client, conversation.id, phaseSignal(ctx.signal, config.execution.provision_ms), e => e.kind === 'stage' && e.stage === 'provision' && e.state === 'done');
    const { body } = await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200 });
    conversation = body.data;
    ensure(conversation.sandbox?.status === 'ready' && conversation.sandbox.mode === 'ephemeral' && conversation.sandbox.provider === config.execution.sandbox_provider,
      'Webhook event source sandbox identity differs');
    report.webhooks.conversation_id = conversation.id;
  })) { report.webhooks.failure_category = 'provision'; return; }
  if (!await check('webhooks/registration', async () => {
    endpoint = await fixtures.create('webhook', { url: `${receiver.origin.origin}/hook/${report.run_id}`, event_types: ['conversation.terminate.done'] });
    ensure(/^whsec_[A-Za-z0-9_-]{43}$/.test(endpoint.secret), 'Webhook signing secret missing from create response');
    redactor.add(endpoint.secret); evidence.values.push(endpoint.secret);
    report.webhooks.endpoint_id = endpoint.id;
    ctx.afterCleanup.push({ name: 'webhooks/receiver-cleanup', run: async () => {
      await receiver.cleanup(AbortSignal.timeout(config.limits.cleanup_ms));
    } });
    await receiver.create({ signing_secret: endpoint.secret, conversation_id: conversation.id, agent_id: conversation.agent_id });
    await client.request('GET', `/api/webhooks/${endpoint.id}`, { expected: 200 });
    for (const method of ['GET', 'PATCH', 'DELETE']) await client.request(method, `/api/webhooks/${endpoint.id}`, {
      key: config.secondaryKey, expected: 404, ...(method === 'PATCH' ? { body: { status: 'disabled' } } : {}) });
    await client.request('GET', `/api/webhooks/${endpoint.id}/deliveries`, { key: config.secondaryKey, expected: 404 });
  })) { report.webhooks.failure_category = 'registration'; return; }
  if (!await check('webhooks/event', async () => {
    const before = await client.request('GET', `/api/conversations/${conversation.id}/events?limit=1`, { expected: 200 });
    const cursor = before.body.data[0]?.id ?? 0;
    await client.request('POST', `/api/conversations/${conversation.id}/terminate`, { expected: 204 });
    const observed = await watchUntil(client, conversation.id, phaseSignal(ctx.signal, 30000), e => e.kind === 'stage' && e.stage === 'terminate' && e.state === 'done', { after: cursor });
    const streamed = observed.events.at(-1).event;
    // Compare the webhook against the durable event, not the stream frame.
    // The conversation stream leaves `duration_ms` out by contract
    // (`StreamLogEvent`: sent on `/api/events/stream` only), so a frame read
    // there has no such field, and a strict comparison saw `undefined` where
    // the webhook correctly sends `null`. History serves the whole event.
    const { body: durable } = await client.request('GET',
      `/api/conversations/${conversation.id}/events?after=${cursor}&limit=100`, { expected: 200 });
    event = durable.data.find(e => e.id === streamed.id);
    ensure(event, 'The terminate event was streamed but is absent from durable history');
    ensure(event.stage === streamed.stage && event.state === streamed.state && event.ts === streamed.ts,
      'The durable terminate event differs from the streamed one');
    report.webhooks.event = event;
    const turns = await client.request('GET', `/api/conversations/${conversation.id}/turns`, { expected: 200 });
    ensure(turns.body.data.length === 0, 'Webhook profile unexpectedly performed inference');
  })) { report.webhooks.failure_category = 'conversation_event'; return; }
  const readEvidence = async signal => {
    report.webhooks.observations = await receiver.evidence(signal);
    const { body } = await client.request('GET', `/api/webhooks/${endpoint.id}/deliveries?limit=200`, { expected: 200, signal });
    report.webhooks.deliveries = body.data;
    ensure(body.data.length < 200, 'Webhook delivery evidence exceeded the public listing bound');
  };
  if (!await check('webhooks/automatic-retry', async () => {
    const signal = phaseSignal(ctx.signal, config.webhooks.delivery_ms);
    while (true) {
      signal.throwIfAborted();
      await readEvidence(signal);
      ensure(report.webhooks.observations.every(o => o.signature_valid && o.payload_valid && o.headers_match), 'Receiver rejected a delivered signature or event');
      if (report.webhooks.deliveries.some(d => d.status_code === 200 && d.attempt > 1) && webhookEvidenceSettled(report.webhooks.observations, report.webhooks.deliveries)) break;
      await sleep(1000, undefined, { signal });
    }
    report.webhooks.analysis = verifyWebhookDeliveries(report.webhooks.observations, report.webhooks.deliveries, event, conversation);
    report.webhooks.required.signed_delivery = 'passed'; report.webhooks.required.automatic_retry = 'passed';
  })) { report.webhooks.failure_category = 'background_dispatch_or_retry'; return; }
  await check('webhooks/duplicate-observation', async () => {
    const started = Date.now();
    while (Date.now() - started < config.webhooks.observe_ms) {
      await sleep(Math.min(1000, config.webhooks.observe_ms - (Date.now() - started)), undefined, { signal: ctx.signal });
      await readEvidence(ctx.signal);
    }
    const settle = phaseSignal(ctx.signal, 10000);
    while (!webhookEvidenceSettled(report.webhooks.observations, report.webhooks.deliveries)) {
      await sleep(250, undefined, { signal: settle }); await readEvidence(settle);
    }
    report.webhooks.analysis = verifyWebhookDeliveries(report.webhooks.observations, report.webhooks.deliveries, event, conversation);
    report.webhooks.observation_window = { started_at: new Date(started).toISOString(), ended_at: new Date().toISOString(), minimum_ms: config.webhooks.observe_ms };
  });
}
