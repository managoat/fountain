import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { openTunnels, TUNNEL_HOST, PUBLIC_RESOLVERS } from '../tunnel.mjs';
import { externalReceiver, hostsReceiver } from '../lib/local-receiver.mjs';

// A fake cloudflared: emits whatever lines the case wants, and records the
// signals it received so teardown can be asserted.
function fakeCloudflared(script) {
  const started = [];
  const spawnFn = (command, args) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.exitCode = null; child.signalCode = null;
    child.kill = signal => { child.signalCode = signal; queueMicrotask(() => child.emit('exit', 0)); };
    const index = started.length;
    started.push({ command, args, child });
    queueMicrotask(() => script(child, index));
    return child;
  };
  return { spawnFn, started };
}

const publish = host => child => {
  child.stderr.emit('data', `INF |  Your quick Tunnel has been created!  https://${host}.trycloudflare.com  |\n`);
  child.stderr.emit('data', 'INF Registered tunnel connection connIndex=0\n');
};

const options = { dnsIntervalMs: 0, intervalMs: 0, resolve4: async () => ['104.16.0.1'],
  probe: async () => ({ status: 200 }) };

test('the hostname pattern matches what cloudflared prints and nothing wider', () => {
  assert.equal('https://movements-tracy-hartford-rolled.trycloudflare.com'.match(TUNNEL_HOST)[0],
    'https://movements-tracy-hartford-rolled.trycloudflare.com');
  assert.equal(TUNNEL_HOST.test('https://evil.example.com'), false);
});

// A named tunnel is not yet a routable one. Resolving on the hostname alone
// would start the hold before the edge could serve it.
test('a tunnel is published only once an edge connection is registered', async () => {
  let announce;
  const { spawnFn } = fakeCloudflared(child => {
    child.stderr.emit('data', 'INF https://named-but-unregistered.trycloudflare.com\n');
    announce = () => child.stderr.emit('data', 'INF Registered tunnel connection connIndex=0\n');
  });
  let settled = false;
  const opening = openTunnels({ port: 4321, spawnFn, ...options }).then(value => { settled = true; return value; });
  await new Promise(resolve => setTimeout(resolve, 25));
  assert.equal(settled, false, 'a hostname without a registered connection is not a usable origin');
  announce();
  const opened = await opening;
  assert.deepEqual(opened.urls, ['https://named-but-unregistered.trycloudflare.com']);
  await opened.stop();
});

test('two origins are opened onto the same local receiver port', async () => {
  const { spawnFn, started } = fakeCloudflared((child, index) => publish(`origin-${index}`)(child));
  const opened = await openTunnels({ port: 4321, count: 2, spawnFn, ...options });
  assert.deepEqual(opened.urls, ['https://origin-0.trycloudflare.com', 'https://origin-1.trycloudflare.com']);
  for (const { args } of started) assert.ok(args.includes('http://127.0.0.1:4321'), 'both forward to the same receiver');
  await opened.stop();
  for (const { child } of started) assert.equal(child.signalCode, 'SIGTERM');
});

test('an origin that never answers fails setup and takes its tunnels down', async () => {
  const { spawnFn, started } = fakeCloudflared((child, index) => publish(`origin-${index}`)(child));
  await assert.rejects(
    openTunnels({ port: 4321, count: 2, spawnFn, dnsIntervalMs: 0, intervalMs: 0, attempts: 2,
      resolve4: async () => ['104.16.0.1'],
      probe: async () => { const error = new Error('lookup failed'); error.cause = { code: 'ENOTFOUND' }; throw error; } }),
    /never became reachable \(ENOTFOUND\)/);
  assert.equal(started.length, 2);
  for (const { child } of started) assert.equal(child.signalCode, 'SIGTERM', 'a failed probe must not leave a public origin open');
});

test('a second tunnel failing to start stops the first', async () => {
  const { spawnFn, started } = fakeCloudflared((child, index) => {
    if (index === 0) publish('origin-0')(child);
    else child.emit('exit', 1);
  });
  await assert.rejects(openTunnels({ port: 4321, count: 2, spawnFn, ...options }), /exited before publishing/);
  assert.equal(started[0].child.signalCode, 'SIGTERM');
});

test('a missing cloudflared is reported as setup, not as a deployment failure', async () => {
  const spawnFn = () => { const child = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
    child.exitCode = null; child.signalCode = null; child.kill = () => {};
    queueMicrotask(() => child.emit('error', new Error('ENOENT'))); return child; };
  await assert.rejects(openTunnels({ port: 4321, spawnFn, ...options }), /cloudflared is not installed/);
});

// Asking the system resolver before the record exists poisons its negative
// cache, so readiness is established against public resolvers first and the
// origin is not requested until the name demonstrably resolves.
test('an origin is not requested until its DNS record exists', async () => {
  const { spawnFn } = fakeCloudflared(child => publish('pending')(child));
  let resolved = false, probedBeforeRecord = false;
  await openTunnels({ port: 4321, spawnFn, dnsIntervalMs: 1, intervalMs: 0,
    resolve4: async () => { if (!resolved) { resolved = true; const e = new Error('nope'); e.code = 'ENOTFOUND'; throw e; } return ['104.16.0.1']; },
    probe: async () => { if (!resolved) probedBeforeRecord = true; return { status: 200 }; } });
  assert.equal(probedBeforeRecord, false);
});

test('a hostname that never gets a record fails setup with that reason', async () => {
  const { spawnFn, started } = fakeCloudflared(child => publish('absent')(child));
  await assert.rejects(openTunnels({ port: 4321, spawnFn, dnsMs: 5, dnsIntervalMs: 1,
    resolve4: async () => { const e = new Error('nope'); e.code = 'ENOTFOUND'; throw e; },
    probe: async () => { throw new Error('must not be requested'); } }),
  /never got a DNS record \(ENOTFOUND\)/);
  assert.equal(started[0].child.signalCode, 'SIGTERM');
});

test('readiness is asked of public resolvers, not the system one', () => {
  assert.deepEqual(PUBLIC_RESOLVERS, ['1.1.1.1', '8.8.8.8']);
});


// A pipe delivers bytes, not lines. cloudflared's banner and its registration
// line can arrive split anywhere, and a per-chunk match would leave a tunnel
// that had already announced itself unrecognised until the startup timer.
for (const [name, chunks] of [
  ['a hostname split mid-word', ['INF |  https://split-host-name.trycloud', 'flare.com  |\n', 'INF Registered tunnel connection connIndex=0\n']],
  ['a registration line split mid-phrase', ['INF |  https://split-host-name.trycloudflare.com  |\nINF Registered tunnel ', 'connection connIndex=0\n']],
  ['everything in one byte-stream with no trailing newline', ['INF https://split-host-name.trycloudflare.com\nINF Registered tunnel connection']],
]) {
  test(`readiness survives ${name}`, async () => {
    const { spawnFn } = fakeCloudflared(child => { for (const chunk of chunks) child.stderr.emit('data', Buffer.from(chunk)); });
    const opened = await openTunnels({ port: 4321, spawnFn, ...options });
    assert.deepEqual(opened.urls, ['https://split-host-name.trycloudflare.com']);
    await opened.stop();
  });
}

test('a stream that never sends a newline cannot grow without bound', async () => {
  const { spawnFn } = fakeCloudflared(child => {
    child.stderr.emit('data', 'x'.repeat(200_000));
    child.stderr.emit('data', 'INF https://late-host.trycloudflare.com\nINF Registered tunnel connection\n');
  });
  const opened = await openTunnels({ port: 4321, spawnFn, ...options });
  assert.deepEqual(opened.urls, ['https://late-host.trycloudflare.com']);
  await opened.stop();
});

test('an external receiver URL carrying a credential is refused without echoing it', () => {
  const secret = 'fake_receiver_password_probe';
  const env = { FOUNTAIN_RECEIVER_ADMIN_KEY: 'x'.repeat(64), FOUNTAIN_MCP_ADMIN_KEY: 'x'.repeat(64) };
  const refused = (fn) => assert.throws(fn, error => {
    assert.ok(!error.message.includes(secret), 'the refusal must not quote the URL back');
    return /must be (?:an )?HTTPS origin/.test(error.message);
  });
  refused(() => externalReceiver('mcp', { receiverUrl: `https://operator:${secret}@receiver.example.com/` }, env));
  refused(() => externalReceiver('mcp', { receiverUrl: `https://receiver.example.com/?t=${secret}` }, env));
  refused(() => externalReceiver('mcp', { receiverUrl: `https://receiver.example.com/#${secret}` }, env));
  refused(() => externalReceiver('secrets', { receiverUrl: `https://a:${secret}@one.example.com/`, blockedUrl: 'https://two.example.com/' }, env));
  refused(() => externalReceiver('secrets', { receiverUrl: 'https://one.example.com/', blockedUrl: `https://two.example.com/?t=${secret}` }, env));
  // The same hostname twice would make a leak indistinguishable from a denial.
  refused(() => externalReceiver('secrets', { receiverUrl: 'https://one.example.com/', blockedUrl: 'https://one.example.com/' }, env));
});

test('only the outbound profiles need a receiver', () => {
  assert.deepEqual(['probe', 'basic', 'execution', 'streaming', 'canary', 'secrets', 'mcp', 'webhooks', 'schedules']
    .filter(hostsReceiver), ['secrets', 'mcp', 'webhooks']);
});

test('a hosted secrets receiver needs two origins and its admin credential', () => {
  const env = { FOUNTAIN_RECEIVER_ADMIN_KEY: 'x'.repeat(64) };
  assert.throws(() => externalReceiver('secrets', { receiverUrl: 'https://one.example.com/' }, env),
    /needs --receiver-url and --blocked-url/);
  assert.throws(() => externalReceiver('secrets', { receiverUrl: 'https://one.example.com/', blockedUrl: 'https://two.example.com/' }, {}),
    /FOUNTAIN_RECEIVER_ADMIN_KEY/);
  const { settings } = externalReceiver('secrets',
    { receiverUrl: 'https://one.example.com/', blockedUrl: 'https://two.example.com/' }, env);
  assert.equal(settings.allowed_url, 'https://one.example.com/');
  assert.equal(settings.blocked_url, 'https://two.example.com/');
  assert.equal(settings.admin_credential, 'FOUNTAIN_RECEIVER_ADMIN_KEY');
});

test('the single-origin profiles reject a second origin', () => {
  const env = { FOUNTAIN_MCP_ADMIN_KEY: 'x'.repeat(64) };
  assert.throws(() => externalReceiver('mcp', { receiverUrl: 'https://one.example.com/', blockedUrl: 'https://two.example.com/' }, env),
    /takes one --receiver-url/);
  assert.equal(externalReceiver('mcp', { receiverUrl: 'https://one.example.com/' }, env).settings.auth_mode, 'static_bearer');
});
