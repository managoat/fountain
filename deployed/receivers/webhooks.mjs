#!/usr/bin/env node
import { createServer as httpServer } from 'node:http';
import { createServer as httpsServer } from 'node:https';
import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const WEBHOOK_VERSION = 'fountain-webhook-receiver/1';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const equal = (a, b) => typeof a === 'string' && Buffer.byteLength(a) === Buffer.byteLength(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));
export function verifySignature(header, raw, secret, now = Date.now()) {
  if (typeof header !== 'string') return false;
  const parts = header.split(',').map(p => p.trim().split('='));
  const times = parts.filter(([k]) => k === 't'), signatures = parts.filter(([k]) => k === 'v1');
  if (times.length !== 1 || signatures.length !== 1 || !/^\d{10}$/.test(times[0][1]) || !/^[0-9a-f]{64}$/.test(signatures[0][1])) return false;
  const timestamp = Number(times[0][1]);
  if (Math.abs(now / 1000 - timestamp) > 300) return false;
  const expected = createHmac('sha256', secret).update(`${timestamp}.`).update(raw).digest('hex');
  return equal(signatures[0][1], expected);
}
function reply(res, status, value) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(value === undefined ? undefined : JSON.stringify(value));
}
async function rawBody(req) {
  let bytes = 0; const chunks = [];
  for await (const chunk of req) { bytes += chunk.length; if (bytes > 16384) throw new Error('Body bound'); chunks.push(chunk); }
  return Buffer.concat(chunks);
}
// A conversation's labels (#1637): ids and facts a program put there itself,
// bounded as `Fountain.Conversations.Labels` bounds them. Never content.
function safeLabels(labels) {
  if (!labels || typeof labels !== 'object' || Array.isArray(labels)) return false;
  const entries = Object.entries(labels);
  return entries.length <= 32 && entries.every(([k, v]) => typeof v === 'string' &&
    Buffer.byteLength(k) >= 1 && Buffer.byteLength(k) <= 64 && Buffer.byteLength(v) <= 256);
}
// The exact key sets are the point, not an inconvenience. Fountain's envelope
// promises "ids, a stage, a status, a duration, the labels. Nothing else,
// ever." Accepting any added field would let content arrive unnoticed, so a
// field the envelope gains is added here deliberately, as `labels` was after
// #1637, rather than tolerated by default.
function safePayload(value, spec) {
  if (!value || Object.keys(value).sort().join() !== 'created_at,data,id,type' || !/^\d{1,20}$/.test(value.id) ||
    value.type !== 'conversation.terminate.done' || typeof value.created_at !== 'string' || value.created_at.length > 32 || !Number.isFinite(Date.parse(value.created_at))) return false;
  const d = value.data;
  return d && Object.keys(d).sort().join() === 'agent_id,conversation_id,duration_ms,labels,parent_conversation_id,stage,state,status,turn_id' &&
    safeLabels(d.labels) &&
    d.conversation_id === spec.conversation_id && d.agent_id === spec.agent_id && d.parent_conversation_id === null && d.turn_id === null &&
    d.stage === 'terminate' && d.state === 'done' && ['pending', 'provisioning', 'idle', 'running', 'terminated', 'failed'].includes(d.status) &&
    (d.duration_ms === null || Number.isSafeInteger(d.duration_ms) && d.duration_ms >= 0);
}
export function webhookHandler({ adminKey, now = Date.now, ttlMs = 900000, maxRuns = 32 } = {}) {
  if (typeof adminKey !== 'string' || adminKey.length < 32 || !Number.isSafeInteger(ttlMs) || ttlMs < 1 || ttlMs > 900000 ||
    !Number.isSafeInteger(maxRuns) || maxRuns < 1 || maxRuns > 32) throw new Error('Webhook receiver needs a strong admin key and bounded retention');
  const runs = new Map(), instanceId = randomUUID();
  return async (req, res) => {
    try {
      for (const [id, run] of runs) if (run.expires_at <= now()) runs.delete(id);
      if (req.headers.origin !== undefined) return reply(res, 403, { error: 'origin_denied' });
      const url = new URL(req.url, 'http://receiver.invalid');
      if (url.search) return reply(res, 400, { error: 'query_denied' });
      if (req.method === 'GET' && url.pathname === '/_suite/identity') return reply(res, 200, { version: WEBHOOK_VERSION, instance_id: instanceId });
      const admin = url.pathname.match(/^\/_suite\/runs\/([^/]+)$/);
      if (admin) {
        if (!equal(req.headers.authorization, `Bearer ${adminKey}`)) return reply(res, 401, { error: 'unauthorized' });
        const id = admin[1];
        if (!uuid.test(id)) return reply(res, 400, { error: 'invalid_run' });
        if (req.method === 'DELETE') { runs.delete(id); return reply(res, 204); }
        if (req.method === 'PUT') {
          const spec = JSON.parse(await rawBody(req));
          if (!spec || Object.keys(spec).sort().join() !== 'agent_id,conversation_id,signing_secret' ||
            !uuid.test(spec.agent_id) || !uuid.test(spec.conversation_id) || !/^whsec_[A-Za-z0-9_-]{43}$/.test(spec.signing_secret)) return reply(res, 422, { error: 'invalid_spec' });
          if (runs.has(id)) return reply(res, 409, { error: 'run_exists' });
          if (runs.size >= maxRuns) return reply(res, 503, { error: 'capacity' });
          const run = { ...spec, expires_at: now() + ttlMs, observations: [], requests: 0, failed_once: false };
          runs.set(id, run);
          return reply(res, 201, { id, version: WEBHOOK_VERSION, instance_id: instanceId, expires_at: run.expires_at });
        }
        const run = runs.get(id);
        if (req.method === 'GET') return run ? reply(res, 200, { id, version: WEBHOOK_VERSION, instance_id: instanceId,
          observations: run.observations, expires_at: run.expires_at }) : reply(res, 404, { error: 'not_found' });
        return reply(res, 405, { error: 'method' });
      }
      const id = url.pathname.match(/^\/hook\/([^/]+)$/)?.[1], run = uuid.test(id) && runs.get(id);
      if (!run) return reply(res, 404, { error: 'not_found' });
      if (req.method !== 'POST') return reply(res, 405, { error: 'method' });
      if (++run.requests > 64) return reply(res, 429, { error: 'request_budget' });
      const raw = await rawBody(req);
      const signed = verifySignature(req.headers['fountain-signature'], raw, run.signing_secret, now());
      let payload;
      try { payload = JSON.parse(raw); } catch {}
      const valid = Boolean(safePayload(payload, run));
      const attempt = Number(req.headers['fountain-delivery-attempt']);
      const headersMatch = valid && req.headers['fountain-event-id'] === payload.id && req.headers['fountain-event-type'] === payload.type &&
        Number.isSafeInteger(attempt) && attempt >= 1 && attempt <= 8;
      const status = !signed ? 401 : !valid || !headersMatch ? 422 : run.failed_once ? 200 : 503;
      if (status === 503) run.failed_once = true;
      const row = { receipt_id: randomUUID(), at: now(), signature_valid: signed, payload_valid: valid, headers_match: Boolean(headersMatch), status,
        ...(signed && valid && headersMatch ? { payload, attempt } : {}) };
      run.observations.push(row);
      return reply(res, status, { receipt_id: row.receipt_id, accepted: status === 200 });
    } catch { if (!res.headersSent) reply(res, 400, { error: 'invalid_request' }); else res.end(); }
  };
}
export function createWebhookReceiver(options) {
  const handler = webhookHandler(options), server = options.tls ? httpsServer(options.tls, handler) : httpServer(handler);
  server.requestTimeout = 5000; server.headersTimeout = 5000; server.keepAliveTimeout = 1000;
  return server;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const port = Number(process.env.PORT || '8080');
    if (!Number.isSafeInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port');
    const tls = process.env.TLS_CERT_FILE && process.env.TLS_KEY_FILE ? { cert: readFileSync(process.env.TLS_CERT_FILE), key: readFileSync(process.env.TLS_KEY_FILE) } : undefined;
    if (!tls && process.env.RECEIVER_TLS_AT_INGRESS !== 'true') throw new Error('TLS required');
    const server = createWebhookReceiver({ adminKey: process.env.FOUNTAIN_WEBHOOK_ADMIN_KEY, tls });
    server.listen(port, '0.0.0.0', () => console.log(`${WEBHOOK_VERSION} listening`));
    const stop = () => { server.close(); server.closeAllConnections(); };
    process.on('SIGINT', stop); process.on('SIGTERM', stop);
  } catch { console.error('Webhook receiver setup failed; configure admin credential, TLS and port'); process.exitCode = 2; }
}
