#!/usr/bin/env node
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { run } from './lib/runner.mjs';
import { composeTarget, PROFILES } from './lib/target.mjs';

// One command for the operator question "does this deployment work": a URL and
// a profile, no hand-authored target file. It composes the same run as
// ci.mjs through lib/target.mjs, so a local verdict and a CI verdict mean the
// same thing. Anything an environment owns rather than a caller — a deployment
// adapter, a matrix, a rollout digest — stays in ci.mjs.

export const KEYCHAIN_SERVICE = 'fountain-deployed-suite';
export const CREDENTIALS = ['FOUNTAIN_SUITE_KEY', 'FOUNTAIN_SUITE_OTHER_KEY'];

// A stored key belongs to one deployment. The account name carries the exact
// origin it was stored for, and there is no unbound fallback, so pointing this
// command at localhost or at someone else's host finds nothing rather than
// sending a production key to it. An exported variable always wins, which is
// how CI and a non-macOS machine supply credentials.
export function resolveCredentials(origin, env, { service = KEYCHAIN_SERVICE, lookup = keychainLookup } = {}) {
  const resolved = { ...env };
  const from = [];
  for (const name of CREDENTIALS) {
    if (resolved[name]) continue;
    const value = lookup(service, `${origin}|${name}`);
    if (value) { resolved[name] = value; from.push(name); }
  }
  return { env: resolved, fromKeychain: from };
}

function keychainLookup(service, account) {
  if (process.platform !== 'darwin') return undefined;
  try {
    return execFileSync('security', ['find-generic-password', '-s', service, '-a', account, '-w'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || undefined;
  } catch { return undefined; }
}

// The profiles this command can fully configure. The rest need receiver
// origins, schedule windows or fixture settings that no flag here supplies, so
// advertising them would only produce targets that fail setup: they are
// configured in a target file and run through cli.mjs.
export const VERIFY_PROFILES = PROFILES.filter(name => !['secrets', 'mcp', 'webhooks', 'schedules'].includes(name));

export const help = `Verify a deployed Fountain (Node 24+)

  node deployed/verify.mjs <base-url> [--profile streaming] [--out DIR]

  --profile    ${VERIFY_PROFILES.join(', ')} (default: streaming)
  --runtime    required runtime (default: claude)
  --model      model for execution profiles (default: anthropic/claude-haiku-4-5)
  --sandbox    required sandbox provider (default: sprites)
  --out        output directory (default: a new directory under $TMPDIR)
  --contract   expected wire contract file, relative to the output directory
  --keychain   macOS keychain service to read keys from (default: ${KEYCHAIN_SERVICE})

The secrets, mcp, webhooks and schedules profiles need configuration no flag
here supplies. Write a target file and run deployed/cli.mjs for those.

Credentials come from FOUNTAIN_SUITE_KEY and FOUNTAIN_SUITE_OTHER_KEY. On
macOS, a key not already exported is read from the keychain under an account
naming this exact target, so a key stored for one deployment is never sent to
another. Provision the accounts as deployed/README.md describes.
Exit codes: 0 passed, 1 assertion/runtime failure, 2 setup, 3 cleanup, 130 interrupted.
`;

// probe asserts on identity and advertised capability alone; every other
// profile provisions a sandbox and needs a second account to prove isolation.
const needsSecondary = profile => profile !== 'probe';
const needsExecution = profile => !['probe', 'basic'].includes(profile);

// Refuses a target before anything prints or writes it. `configFrom` applies
// the same rule, but only once a target file exists: a URL carrying a password
// in its userinfo would have been echoed to the terminal and persisted to
// target.json on the way to that refusal.
export function targetOrigin(baseUrl) {
  let url;
  try { url = new URL(baseUrl); }
  catch { throw new Error('Target must be an absolute http(s) URL'); }
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Target must be an absolute http(s) URL');
  if (url.username || url.password || url.search || url.hash) {
    // Never quote the input back: that is how it would reach a terminal or a
    // scrollback buffer.
    throw new Error('Target must not carry credentials, a query or a fragment');
  }
  if (url.pathname !== '/') throw new Error('Target must be an origin, with no path');
  // Plaintext is for a sandbox on this machine; a remote target must be
  // encrypted or its API key crosses the network in the clear.
  const loopback = ['localhost', '127.0.0.1', '[::1]', '::1'].includes(url.hostname);
  if (url.protocol === 'http:' && !loopback) throw new Error('A remote target requires HTTPS ingress');
  return url;
}

export function verifyConfig(args, env) {
  if (!VERIFY_PROFILES.includes(args.profile)) {
    const elsewhere = PROFILES.includes(args.profile)
      ? `The ${args.profile} profile needs configuration this command cannot supply; write a target file and use deployed/cli.mjs`
      : `Unknown profile: choose one of ${VERIFY_PROFILES.join(', ')}`;
    throw new Error(elsewhere);
  }
  const url = targetOrigin(args.baseUrl);
  if (!env.FOUNTAIN_SUITE_KEY) throw new Error('Set FOUNTAIN_SUITE_KEY to the primary test account key');
  if (needsSecondary(args.profile) && !env.FOUNTAIN_SUITE_OTHER_KEY) {
    throw new Error(`The ${args.profile} profile proves tenant isolation; set FOUNTAIN_SUITE_OTHER_KEY to a different account's key`);
  }
  const target = {
    base_url: url.href,
    credentials: needsSecondary(args.profile)
      ? { primary: 'FOUNTAIN_SUITE_KEY', secondary: 'FOUNTAIN_SUITE_OTHER_KEY' }
      : { primary: 'FOUNTAIN_SUITE_KEY' },
    required_capabilities: {
      runtimes: [args.runtime],
      sandbox_providers: needsExecution(args.profile) ? [args.sandbox] : [],
    },
  };
  if (args.contract) target.contract = args.contract;
  if (needsExecution(args.profile)) {
    target.execution = { runtime: args.runtime, model: args.model, sandbox_provider: args.sandbox };
  }
  return composeTarget(target, args.profile);
}

export function summarize(report, log = console.log) {
  if (!report) { log('  no result.json was written; read the log above'); return; }
  const checks = Array.isArray(report.checks) ? report.checks : [];
  const counted = status => checks.filter(check => check.status === status);
  const failed = counted('failed');
  const skipped = counted('skipped');
  log('');
  log(`  status     ${report.status ?? 'unknown'}`);
  log(`  checks     ${counted('passed').length} passed, ${failed.length} failed` + (skipped.length ? `, ${skipped.length} skipped` : ''));
  // A clean public verdict with resources left behind is still a failure to
  // report: the manifest has to be replayed before the account is reusable.
  if (report.cleanup) log(`  cleanup    ${report.cleanup.remaining} resource(s) remaining`);
  if (report.revision) log(`  revision   ${report.revision.verified ? 'verified' : `unverified (${report.revision.reason})`}`);
  for (const check of failed) log(`  failed     ${check.name}${check.error ? `: ${check.error}` : ''}`);
  for (const check of skipped) log(`  skipped    ${check.name}${check.reason ? `: ${check.reason}` : ''}`);
}

export async function verifyMain(argv, env = process.env) {
  const { values, positionals } = parseArgs({ args: argv, allowPositionals: true, options: {
    profile: { type: 'string', default: 'streaming' },
    runtime: { type: 'string', default: 'claude' },
    model: { type: 'string', default: 'anthropic/claude-haiku-4-5' },
    sandbox: { type: 'string', default: 'sprites' },
    contract: { type: 'string' },
    out: { type: 'string' },
    keychain: { type: 'string', default: KEYCHAIN_SERVICE },
    help: { type: 'boolean', short: 'h' },
  } });
  if (values.help) { console.log(help); return 0; }
  if (positionals.length !== 1) throw new Error(help);
  // Validate the target before resolving a credential for it, so a refused
  // target never selects a key, and before anything is printed or written.
  const origin = targetOrigin(positionals[0]).origin;
  const resolved = resolveCredentials(origin, env, { service: values.keychain });
  env = resolved.env;
  const config = verifyConfig({ ...values, baseUrl: positionals[0] }, env);
  if (resolved.fromKeychain.length) console.log(`  keys       keychain ${values.keychain} for ${origin}`);
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  const out = resolve(values.out || resolve(env.TMPDIR || '/tmp', `fountain-verify-${stamp}`));
  // Each run owns a new directory, so one verdict never overwrites another's
  // evidence or cleanup manifest.
  mkdirSync(out, { mode: 0o700, recursive: false });
  const configPath = resolve(out, 'target.json');
  writeFileSync(configPath, JSON.stringify(config, null, 2), { mode: 0o600 });
  console.log(`  target     ${config.base_url}`);
  console.log(`  profiles   ${config.profiles.join(', ')}`);
  if (config.execution) console.log(`  execution  ${config.execution.runtime} / ${config.execution.model} / ${config.execution.sandbox_provider}`);
  console.log(`  out        ${out}`);
  const controller = new AbortController();
  const cancel = () => controller.abort(new Error('Interrupted'));
  process.on('SIGINT', cancel);
  process.on('SIGTERM', cancel);
  try {
    const code = await run({ configPath, out: resolve(out, 'results'), signal: controller.signal, env });
    summarize(readReport(resolve(out, 'results')));
    console.log(`  evidence   ${resolve(out, 'results')}`);
    return code;
  } finally {
    process.off('SIGINT', cancel);
    process.off('SIGTERM', cancel);
  }
}

function readReport(results) {
  try { return JSON.parse(readFileSync(resolve(results, 'result.json'), 'utf8')); }
  catch { return undefined; }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.exitCode = await verifyMain(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 2; }
}
