import { spawn } from 'node:child_process';
import { Resolver } from 'node:dns/promises';

// The integration profiles assert on what a deployment does *outbound*: a
// secret delivered into a sandbox, an MCP server called, a webhook posted. A
// receiver has to be reachable from the deployment and from its sandbox
// provider, so it needs a public HTTPS origin. Rather than ask an operator to
// host one, a run borrows one: a Cloudflare quick tunnel needs no account and
// no DNS record, and lasts exactly as long as the run.
//
// This is deliberately not how CI does it. There the receivers are hosted at
// stable origins an environment owns. A borrowed origin is right for a
// push-button run and wrong for unattended verification.

export const TUNNEL_HOST = /https:\/\/[a-z0-9][a-z0-9-]*\.trycloudflare\.com/;
const REGISTERED = /Registered tunnel connection/;

// A freshly issued hostname takes several seconds to resolve, and asking the
// system resolver early is worse than not asking: the first NXDOMAIN is
// negatively cached, and on macOS repeated lookups keep refreshing that entry
// rather than expiring it. Measured on 2026-09-16, polling from t=3.7s never
// recovered within 58s, while waiting and then asking once resolved
// immediately.
//
// So readiness is established out of band, against public resolvers directly,
// which does not touch the system resolver's cache. Only once the record
// demonstrably exists does anything here make a normal request, which is the
// first time the system resolver sees the name at all. That replaced a blind
// 25s hold and is both faster and steadier: resolution at ~12s rather than a
// wait to 29s, with no chance of us poisoning our own lookups.
export const PUBLIC_RESOLVERS = ['1.1.1.1', '8.8.8.8'];

const sleep = (ms, signal) => new Promise((resolve, reject) => {
  const timer = setTimeout(resolve, ms);
  signal?.addEventListener('abort', () => { clearTimeout(timer); reject(new Error('Interrupted')); }, { once: true });
});

class Tunnel {
  constructor(child, url) { this.child = child; this.url = url; this.hostname = new URL(url).hostname; }
  async stop() {
    if (this.child.exitCode !== null || this.child.signalCode !== null) return;
    this.child.kill('SIGTERM');
    await new Promise(resolve => {
      const timer = setTimeout(() => { this.child.kill('SIGKILL'); resolve(); }, 5000);
      this.child.once('exit', () => { clearTimeout(timer); resolve(); });
    });
  }
}

// Resolves once cloudflared has both named the hostname and registered an edge
// connection for it. Either one alone is not yet a working origin.
function startOne({ port, signal, spawnFn = spawn, startupMs = 60000 }) {
  return new Promise((resolve, reject) => {
    const child = spawnFn('cloudflared', ['tunnel', '--url', `http://127.0.0.1:${port}`, '--no-autoupdate'],
      { stdio: ['ignore', 'pipe', 'pipe'] });
    let url, registered = false, settled = false;
    const finish = error => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) { child.kill('SIGKILL'); reject(error); } else resolve(new Tunnel(child, url));
    };
    const timer = setTimeout(() => finish(new Error('cloudflared did not publish a tunnel in time')), startupMs);
    // A pipe delivers bytes, not lines: a hostname split after "trycloud", or
    // a registration line split mid-phrase, is invisible to a per-chunk match
    // and the tunnel would sit unrecognised until the startup timer rejected
    // one that had already announced itself. Each stream keeps its own
    // remainder, bounded so a stream that never emits a newline cannot grow
    // without limit.
    const reader = () => {
      let rest = '';
      return chunk => {
        const text = rest + String(chunk);
        const lines = text.split(/\r?\n/);
        rest = lines.pop() ?? '';
        if (rest.length > 64 * 1024) rest = rest.slice(-4096);
        // The trailing remainder is matched too, since cloudflared's banner
        // has no newline until the box is closed, but it is never consumed:
        // an incomplete line stays in `rest` until its newline arrives.
        for (const line of [...lines, rest]) {
          const match = line.match(TUNNEL_HOST);
          if (match && !url) url = match[0];
          if (REGISTERED.test(line)) registered = true;
        }
        if (url && registered) finish();
      };
    };
    child.stdout.on('data', reader());
    child.stderr.on('data', reader());
    child.once('error', () => finish(new Error('cloudflared is not installed or could not start')));
    child.once('exit', code => finish(new Error(`cloudflared exited before publishing a tunnel (code ${code})`)));
    signal?.addEventListener('abort', () => finish(new Error('Interrupted')), { once: true });
  });
}

function publicResolver() {
  const resolver = new Resolver();
  resolver.setServers(PUBLIC_RESOLVERS);
  return hostname => resolver.resolve4(hostname);
}

// One origin per hostname, all forwarding to the same local receiver. The
// secrets profile needs two, and asserts they reach the same instance.
export async function openTunnels({ port, count = 1, signal, spawnFn, log = () => {},
  resolve4 = publicResolver(), probe = fetch, dnsMs = 120000, dnsIntervalMs = 2000, attempts = 12, intervalMs = 5000 }) {
  let tunnels = [];
  try {
    // Started together so they age together. Started in turn, the second
    // hostname is several seconds younger than the first and its edge was
    // still catching up after the first had been waited for.
    const started = await Promise.allSettled(Array.from({ length: count }, () => startOne({ port, signal, spawnFn })));
    tunnels = started.filter(one => one.status === 'fulfilled').map(one => one.value);
    const failed = started.find(one => one.status === 'rejected');
    if (failed) throw failed.reason;
    log(`  tunnel     ${tunnels.map(tunnel => tunnel.hostname).join(', ')}`);
    for (const tunnel of tunnels) {
      await waitForRecord(tunnel, { signal, resolve4, dnsMs, dnsIntervalMs });
      await waitForOrigin(tunnel, { signal, probe, attempts, intervalMs });
    }
    log(`  ready      ${tunnels.length} origin(s) reachable`);
    return { tunnels, urls: tunnels.map(tunnel => tunnel.url), async stop() { for (const tunnel of tunnels) await tunnel.stop(); } };
  } catch (error) {
    for (const tunnel of tunnels) await tunnel.stop();
    throw error;
  }
}

// Asked of public resolvers directly, so a miss costs nothing: it never
// reaches the cache that the run's own requests will use.
async function waitForRecord(tunnel, { signal, resolve4, dnsMs, dnsIntervalMs }) {
  const deadline = Date.now() + dnsMs;
  let last = 'no answer';
  while (Date.now() < deadline) {
    if (signal?.aborted) throw new Error('Interrupted');
    try {
      const addresses = await resolve4(tunnel.hostname);
      if (addresses?.length) return;
      last = 'empty answer';
    } catch (error) { last = error?.code || error?.message || 'lookup failed'; }
    await sleep(dnsIntervalMs, signal);
  }
  throw new Error(`Tunnel ${tunnel.hostname} never got a DNS record (${last})`);
}

// Any HTTP response proves the origin is routable; the receiver's own identity
// is checked by the profile, which is what has to reject a stale instance.
async function waitForOrigin(tunnel, { signal, probe, attempts, intervalMs }) {
  let last = 'no response';
  for (let attempt = 0; attempt < attempts; attempt++) {
    if (signal?.aborted) throw new Error('Interrupted');
    try {
      const response = await probe(`${tunnel.url}/_suite/identity`, { signal: AbortSignal.timeout(8000) });
      if (response.status < 500) return;
      last = `HTTP ${response.status}`;
    } catch (error) { last = error?.cause?.code || error?.name || 'request failed'; }
    if (attempt < attempts - 1) await sleep(intervalMs, signal);
  }
  // Setup, never an assertion: a borrowed origin that never came up says
  // nothing about the deployment under test.
  throw new Error(`Tunnel ${tunnel.hostname} never became reachable (${last})`);
}
