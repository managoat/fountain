import { randomBytes } from 'node:crypto';
import { receiverOrigins } from './receiver.mjs';
import { controlledOrigin } from './controlled-receiver.mjs';
import { openTunnels } from '../tunnel.mjs';
import { createReceiver } from '../receivers/secrets.mjs';
import { createMcpReceiver } from '../receivers/mcp.mjs';
import { createWebhookReceiver } from '../receivers/webhooks.mjs';

// Hosting a receiver for the duration of one run, reachable over borrowed
// public origins. The receiver modules are unchanged and still run standalone
// behind a real ingress; this only saves an operator from standing one up to
// answer "does this deployment deliver secrets, call MCP servers and send
// webhooks".
//
// The admin credential is generated per run and lives only in the child
// environment handed to the runner, so it never reaches the caller's shell,
// the target file or the retained evidence.

// `secrets` needs two hostnames onto one instance: the profile asserts both
// report the same instance id, which is how traffic arriving at the host that
// should have been blocked becomes visible rather than merely absent.
const RECEIVERS = {
  secrets: { create: createReceiver, origins: 2, credential: 'FOUNTAIN_RECEIVER_ADMIN_KEY',
    settings: ([allowed, blocked], options) => ({ allowed_url: allowed, blocked_url: blocked,
      admin_credential: 'FOUNTAIN_RECEIVER_ADMIN_KEY', bootstrap_hosts: options.bootstrapHosts }) },
  mcp: { create: createMcpReceiver, origins: 1, credential: 'FOUNTAIN_MCP_ADMIN_KEY',
    settings: ([receiver]) => ({ receiver_url: receiver, admin_credential: 'FOUNTAIN_MCP_ADMIN_KEY', auth_mode: 'static_bearer' }) },
  webhooks: { create: createWebhookReceiver, origins: 1, credential: 'FOUNTAIN_WEBHOOK_ADMIN_KEY',
    settings: ([receiver]) => ({ receiver_url: receiver, admin_credential: 'FOUNTAIN_WEBHOOK_ADMIN_KEY',
      delivery_ms: 180000, observe_ms: 30000 }) },
};

export const hostsReceiver = profile => Object.hasOwn(RECEIVERS, profile);

// An already-hosted receiver, at origins the caller owns. Its admin credential
// is the caller's too, so it comes from the environment rather than a flag.
export function externalReceiver(profile, { receiverUrl, blockedUrl, bootstrapHosts = ['registry.npmjs.org'] }, env) {
  const spec = RECEIVERS[profile];
  if (!spec) throw new Error(`No receiver is needed for the ${profile} profile`);
  const origins = [receiverUrl, blockedUrl].filter(Boolean);
  if (origins.length !== spec.origins) {
    throw new Error(spec.origins === 2
      ? 'The secrets profile needs --receiver-url and --blocked-url, two hostnames onto the same receiver'
      : `The ${profile} profile takes one --receiver-url`);
  }
  const settings = spec.settings(origins, { bootstrapHosts });
  // The profile's own validator, applied here rather than at load: these
  // settings are written to target.json on the way to the runner, so a URL
  // carrying a password would be persisted before anything refused it. It
  // runs before the credential check, so a URL is refused for what it is
  // rather than for what the environment happens to be missing.
  validateOrigins(profile, settings);
  if (!env[spec.credential]) throw new Error(`Set ${spec.credential} to the hosted receiver's admin credential`);
  return { settings, env: {}, async stop() {} };
}

// Never quote the input back: a refusal that echoes the URL puts the
// credential in the terminal, which is the disclosure being prevented.
function validateOrigins(profile, settings) {
  try {
    if (profile === 'secrets') receiverOrigins(settings);
    else controlledOrigin(settings);
  } catch {
    throw new Error(profile === 'secrets'
      ? 'Receiver URLs must be HTTPS origins on distinct public hostnames, with no credentials, query or fragment'
      : 'The receiver URL must be an HTTPS origin on a public hostname, with no credentials, query or fragment');
  }
}

export async function hostReceiver(profile, { signal, log = () => {}, bootstrapHosts = ['registry.npmjs.org'],
  openTunnelsFn = openTunnels, adminKey = randomBytes(32).toString('hex') } = {}) {
  const spec = RECEIVERS[profile];
  if (!spec) throw new Error(`No receiver is needed for the ${profile} profile`);
  const server = spec.create({ adminKey });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const { port } = server.address();
  log(`  receiver   ${profile} on 127.0.0.1:${port}`);
  let tunnels;
  try {
    tunnels = await openTunnelsFn({ port, count: spec.origins, signal, log });
  } catch (error) {
    await closeServer(server);
    throw error;
  }
  return {
    // A trailing slash keeps these exact origins: the receiver origin
    // validators require a path of exactly "/".
    settings: spec.settings(tunnels.urls.map(url => new URL(url).origin + '/'), { bootstrapHosts }),
    env: { [spec.credential]: adminKey, RECEIVER_TLS_AT_INGRESS: 'true' },
    hosted: true,
    async stop() { await tunnels.stop(); await closeServer(server); },
  };
}

function closeServer(server) {
  return new Promise(resolve => {
    server.closeAllConnections?.();
    server.close(() => resolve());
  });
}
