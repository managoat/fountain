import { spawn } from 'node:child_process';

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

// A freshly issued hostname does not resolve for roughly twenty seconds, and
// asking early is worse than not asking: the first NXDOMAIN is negatively
// cached, and on macOS repeated lookups keep refreshing that entry rather than
// expiring it. Measured on 2026-09-16: probing from t=3.7s never recovered
// within 58s, while holding 25s before the first lookup resolved on the first
// try, twice. So the hold is not a guess at propagation time — it exists to
// keep us from poisoning our own resolver.
export const FIRST_LOOKUP_HOLD_MS = 25000;

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
    const read = chunk => {
      const text = String(chunk);
      const match = text.match(TUNNEL_HOST);
      if (match && !url) url = match[0];
      if (REGISTERED.test(text)) registered = true;
      if (url && registered) finish();
    };
    child.stdout.on('data', read);
    child.stderr.on('data', read);
    child.once('error', () => finish(new Error('cloudflared is not installed or could not start')));
    child.once('exit', code => finish(new Error(`cloudflared exited before publishing a tunnel (code ${code})`)));
    signal?.addEventListener('abort', () => finish(new Error('Interrupted')), { once: true });
  });
}

// One origin per hostname, all forwarding to the same local receiver. The
// secrets profile needs two, and asserts they reach the same instance.
export async function openTunnels({ port, count = 1, signal, spawnFn, log = () => {},
  holdMs = FIRST_LOOKUP_HOLD_MS, probe = fetch, attempts = 8, intervalMs = 8000 }) {
  const tunnels = [];
  try {
    for (let index = 0; index < count; index++) tunnels.push(await startOne({ port, signal, spawnFn }));
    log(`  tunnel     ${tunnels.map(tunnel => tunnel.hostname).join(', ')}`);
    log(`  waiting    ${holdMs / 1000}s before the first DNS lookup, then probing`);
    await sleep(holdMs, signal);
    for (const tunnel of tunnels) await waitForOrigin(tunnel, { signal, probe, attempts, intervalMs });
    return { tunnels, urls: tunnels.map(tunnel => tunnel.url), async stop() { for (const tunnel of tunnels) await tunnel.stop(); } };
  } catch (error) {
    for (const tunnel of tunnels) await tunnel.stop();
    throw error;
  }
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
