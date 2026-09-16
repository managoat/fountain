import { randomUUID } from 'node:crypto';
import { appendFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { phaseSignal, ensure, performTurn, watchUntil, history } from '../lib/execution.mjs';
import { setTimeout as sleep } from 'node:timers/promises';
import { ReceiverSession } from '../lib/receiver.mjs';
import { SecretEvidence } from '../lib/secret-evidence.mjs';
import { fingerprint } from '../receivers/secrets.mjs';

export function verifyEchoEvidence(events, receiptId) {
  const strings = (value, depth = 0) => {
    if (depth > 6) return [];
    if (typeof value === 'string') {
      try { const parsed = JSON.parse(value); if (parsed && typeof parsed === 'object') return [value, ...strings(parsed, depth + 1)]; } catch {}
      return [value];
    }
    return value && typeof value === 'object' ? Object.values(value).flatMap(v => strings(v, depth + 1)) : [];
  };
  const text = strings(events).join('\n');
  ensure(text.includes(receiptId) && /"bound_echo"\s*:\s*"\[REDACTED\]"/.test(text) &&
    /"plain_echo"\s*:\s*"\[REDACTED\]"/.test(text), 'Durable receiver response lacks its receipt and both redacted echoes');
}

export function secretScript({ allowed, blocked, runId, nonce, boundKey, plainKey }) {
  // Only non-secret names/URLs appear in the accepted prompt. Actual values
  // must arrive via the environment/vault merge and broker header injection.
  return `python3 - <<'FOUNTAIN_SUITE_PY'
import json, os, subprocess
bound = os.environ[${JSON.stringify(boundKey)}]
plain = os.environ[${JSON.stringify(plainKey)}]
if bound != ${JSON.stringify(`__${boundKey.toLowerCase()}__`)}:
    raise RuntimeError('Bound secret was not replaced by a placeholder')
if not plain.startswith('suite_secret_'):
    raise RuntimeError('Unbound synthetic secret is absent')
payload = json.dumps({'nonce': ${JSON.stringify(nonce)}, 'placeholder': bound, 'plain': plain})
result = subprocess.run(['curl', '--silent', '--show-error', '--fail-with-body', '--max-time', '20', '-H', 'Content-Type: application/json', '--data-binary', '@-', ${JSON.stringify(`${allowed}/capture/${runId}/allowed/${nonce}`)}], input=payload, text=True, capture_output=True, timeout=25)
if result.returncode != 0:
    raise RuntimeError('Controlled receiver request failed (curl exit %s)' % result.returncode)
receipt = json.loads(result.stdout)
if receipt.get('nonce') != ${JSON.stringify(nonce)}:
    raise RuntimeError('Receiver nonce differs')
print('fixture-plain-echo=' + plain, flush=True)
print('fixture-receiver-echo=' + result.stdout, flush=True)
print('fixture-placeholder=' + bound, flush=True)
denied = subprocess.run(['curl', '--silent', '--show-error', '--max-time', '20', '-X', 'POST', '--data-binary', '{}', '-o', '/dev/null', '--write-out', '%{http_connect}', ${JSON.stringify(`${blocked}/capture/${runId}/blocked/${nonce}`)}], text=True, capture_output=True, timeout=25)
# The proxy's CONNECT answer is the signal; curl's exit code for a refused tunnel
# is not. Older curl reported it as 56 (receive error), newer curl as 7
# (couldn't connect) — the sandbox image's curl returns 7 for exactly this 403.
if denied.returncode not in (7, 56) or denied.stdout != '403':
    raise RuntimeError('Blocked receiver did not get the expected CONNECT 403')
print('fixture-secret-done:' + ${JSON.stringify(nonce)}, flush=True)
FOUNTAIN_SUITE_PY`;
}

export async function secrets(ctx) {
  const { client, config, report, fixtures, check, redactor } = ctx;
  const settings = config.secrets;
  report.secrets = { receiver: null, observations: [], egress: [], inspection: null };
  report.execution = { runtime: config.execution.runtime, model: config.execution.model,
    sandbox_provider: config.execution.sandbox_provider, sandbox_mode: 'ephemeral', turns: [] };
  const values = Array.from({ length: 4 }, () => `suite_secret_${randomUUID()}`);
  values.forEach(value => redactor.add(value));
  const [envBound, vaultBound, envPlain, vaultPlain] = values;
  const evidence = new SecretEvidence(values);
  client.assertPublicSafe = (value, source) => evidence.inspect(value, source);
  // A disclosure must fail the verdict, while cleanup still gets to inspect
  // run ownership and delete the leaking fixture. Continue recording all leaks.
  ctx.beforeCleanup.push(() => { evidence.throwOnLeak = false; });
  ctx.afterCleanup.push({ name: 'secrets/non-disclosure', run: async () => {
    report.secrets.inspection = { ...evidence.inspected, leaks: evidence.leaks };
    report.secrets.artifacts = evidence.scanArtifacts(ctx.out, redactor);
    ensure(evidence.leaks.length === 0, 'Public responses disclosed synthetic secrets before harness redaction');
  } });
  const receiver = new ReceiverSession({ settings, adminKey: ctx.env[settings.admin_credential], path: resolve(ctx.out, 'receiver.json'),
    runId: report.run_id, redactor, signal: ctx.signal,
    trace: entry => appendFileSync(resolve(ctx.out, 'receiver-http.jsonl'), JSON.stringify(redactor.value(entry)) + '\n', { mode: 0o600 }) });
  let environment, vault, binding, conversation;
  const nonce = randomUUID();
  if (!await check('secrets/setup', async () => {
    const { body } = await client.request('GET', '/api/auth/me', { key: config.secondaryKey, expected: 200 });
    ensure(body.id !== report.owner_id && body.email_verified, 'Secrets profile requires a distinct verified second tenant');
    await client.request('GET', '/api/secret-bindings', { expected: 200 });
    await client.request('GET', '/api/secret-bindings', { key: config.secondaryKey, expected: 200 });
    report.secrets.receiver = await receiver.verify();
  })) { report.status = 'setup_failed'; report.secrets.failure_category = 'broker_or_receiver_setup'; return; }
  if (!await check('secrets/fixtures', async () => {
    environment = await fixtures.create('environment', { networking_type: 'limited', networking_config: { allowed_hosts: [receiver.allowed.host, ...settings.bootstrap_hosts] } });
    vault = await fixtures.create('vault');
    binding = await fixtures.create('binding', { host: receiver.allowed.host, auth_type: 'api_key', header: 'X-Fountain-Fixture', prefix: '', enabled: true });
    const plainKey = `${binding.key}_PLAIN`;
    for (const [path, rows] of [
      [`/api/environments/${environment.id}/secrets`, [[binding.key, envBound], [plainKey, envPlain]]],
      [`/api/vaults/${vault.id}/secrets`, [[binding.key, vaultBound], [plainKey, vaultPlain]]],
    ]) {
      for (const [key, value] of rows) await client.request('POST', path, { expected: 201, body: { key, value } });
      const { body } = await client.request('GET', path, { expected: 200 });
      ensure(body.data.length === 2 && body.data.every(r => !Object.hasOwn(r, 'value')), 'Secret listing returned values or unexpected fixture entries');
      await client.request('GET', path, { key: config.secondaryKey, expected: 404 });
      await client.request('POST', path, { key: config.secondaryKey, expected: 404, body: { key: plainKey, value: `suite_secret_${randomUUID()}` } });
      await client.request('DELETE', `${path}/${plainKey}`, { key: config.secondaryKey, expected: 404 });
    }
    const otherBindings = await client.request('GET', '/api/secret-bindings', { key: config.secondaryKey, expected: 200 });
    ensure(!otherBindings.body.data.some(b => b.id === binding.id), 'Second tenant can list the fixture binding');
    await client.request('PATCH', `/api/secret-bindings/${binding.id}`, { key: config.secondaryKey, expected: 404, body: { enabled: false } });
    await client.request('DELETE', `/api/secret-bindings/${binding.id}`, { key: config.secondaryKey, expected: 404 });
    ctx.afterCleanup.push({ name: 'secrets/receiver-cleanup', run: async () => {
      if (receiver.manifest.state === 'created') {
        try { report.secrets.observations = await receiver.evidence(AbortSignal.timeout(10000)); }
        catch (error) { report.secrets.receiver_evidence_error = redactor.text(error.message); }
      }
      await receiver.cleanup(AbortSignal.timeout(config.limits.cleanup_ms));
    } });
    await receiver.create({ nonce, bound_sha256: fingerprint(vaultBound), plain_sha256: fingerprint(vaultPlain), placeholder: `__${binding.key.toLowerCase()}__` });
    const agent = await fixtures.create('agent', { runtime: config.execution.runtime, model: config.execution.model,
      environment_id: environment.id, sandbox_provider: config.execution.sandbox_provider, sandbox_mode: 'ephemeral',
      allowed_vault_ids: [vault.id], system: 'Run only the supplied bounded synthetic credential test script, once. Do not inspect other credentials or use other network destinations.', permission_policy: { default: 'auto_allow' } });
    conversation = await fixtures.create('conversation', { agent_id: agent.id, environment_id: environment.id, vault_id: vault.id });
    Object.assign(report.execution, { conversation_id: conversation.id, sandbox_id: conversation.sandbox_id });
  })) return;
  let provision;
  if (!await check('secrets/provision', async () => {
    provision = await watchUntil(client, conversation.id, phaseSignal(ctx.signal, config.execution.provision_ms), e => e.kind === 'stage' && e.stage === 'provision' && e.state === 'done');
    const { body } = await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200 });
    conversation = body.data;
    ensure(conversation.sandbox?.status === 'ready' && conversation.sandbox.mode === 'ephemeral' && conversation.sandbox.provider === config.execution.sandbox_provider &&
      conversation.environment_id === environment.id && conversation.vault_id === vault.id, 'Secret sandbox identity or mode differs');
    const egress = await client.request('GET', `/api/conversations/${conversation.id}/egress`, { expected: 200 });
    ensure(egress.body.brokered === true, 'Conversation did not enable real brokered egress');
    report.execution.sandbox_id = conversation.sandbox_id;
  })) { report.secrets.failure_category = 'provision_or_broker_setup'; return; }
  if (!await check('secrets/sandbox-delivery-and-output', async () => {
    const script = secretScript({ allowed: receiver.allowed.origin, blocked: receiver.blocked.origin, runId: report.run_id,
      nonce, boundKey: binding.key, plainKey: `${binding.key}_PLAIN` });
    const turn = await performTurn(ctx, conversation, `Run this exact Python/shell tool script once. Do not fabricate any output, repeat the command, inspect other secrets, or make other requests.\n\n${script}`, 1, provision.cursor);
    const text = turn.stored.filter(e => e.turn_id === turn.turn.id).flatMap(e => e.blocks ?? []).filter(b => b.kind === 'text').map(b => b.body ?? '').join('\n');
    // Echo evidence often lives in tool_result blocks/raw events, so inspect
    // the full durable event shape, not just the model's final text.
    const persisted = JSON.stringify(turn.stored);
    // One message per missing marker: a single combined message made the
    // failing one findable only by searching the traces by hand.
    //
    // The placeholder is not asserted here. Fountain registers every sandbox
    // environment value for redaction, and the placeholder is one, so durable
    // output shows `fixture-placeholder=[REDACTED]` and a plain form cannot be
    // required. Substitution is still proven twice: the script raises before
    // it prints its completion marker if the variable held anything but the
    // placeholder, and the receiver records `placeholder_matches` below.
    for (const [marker, missing] of [
      [`fixture-secret-done:${nonce}`, 'the script did not complete; its checks failed before the last line'],
      ['fixture-plain-echo=[REDACTED]', 'the unbound secret was not echoed, or was echoed without redaction'],
      ['fixture-receiver-echo=', "the receiver's reply was not echoed"],
    ]) ensure(persisted.includes(marker), `Durable output lacks evidence: ${missing}`);
    report.secrets.model_text_present = Boolean(text);
  })) return;
  await check('secrets/receiver-and-egress-evidence', async () => {
    const signal = phaseSignal(ctx.signal, 20000);
    let rows;
    while (true) {
      signal.throwIfAborted();
      const { body } = await client.request('GET', `/api/conversations/${conversation.id}/egress?limit=500`, { expected: 200, signal });
      ensure(body.brokered === true, 'Broker evidence disappeared');
      rows = body.data;
      const host = row => row.host?.split(':')[0];
      // Not by path: since #2132 the broker stores every egress path as
      // `/[REDACTED]`, because a path can carry a token, so a path match can
      // never succeed. The row is still this run's: the log is this run's own
      // conversation, the allowed hostname is this run's receiver, and the
      // script makes one POST to it. The nonce itself is proven by the
      // receiver's `nonce_matches` observation checked just below.
      const allowed = rows.filter(row => host(row) === receiver.allowed.hostname && row.method === 'POST');
      const blocked = rows.filter(row => host(row) === receiver.blocked.hostname && row.status === 403 && row.method === 'CONNECT');
      if (allowed.length && blocked.length) {
        ensure(allowed.length === 1 && allowed[0].status === 200 && allowed[0].credential_keys.includes(binding.key) && typeof allowed[0].service === 'string', 'Egress log did not record the expected bound credential request');
        ensure(blocked.every(row => row.credential_keys.length === 0), 'Denied host recorded a credential attachment');
        report.secrets.egress = [...allowed, ...blocked];
        break;
      }
      await sleep(250, undefined, { signal });
    }
    const observations = await receiver.evidence(signal);
    ensure(observations.length === 1 && observations[0].phase === 'allowed' && ['nonce_matches', 'bound_matches', 'plain_matches', 'placeholder_matches'].every(k => observations[0][k] === true), 'Controlled receiver did not observe exactly the intended secret/placeholder delivery, or blocked traffic arrived');
    report.secrets.observations = observations;
    await client.request('GET', `/api/conversations/${conversation.id}/egress`, { key: config.secondaryKey, expected: 404 });
    const persisted = await history(client, conversation.id, signal);
    verifyEchoEvidence(persisted.events, observations[0].id);
    await client.request('GET', `/api/conversations/${conversation.id}/turns`, { expected: 200 });
    const { body } = await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200 });
    report.execution.usage_total = body.data.usage_total;
  });
}
