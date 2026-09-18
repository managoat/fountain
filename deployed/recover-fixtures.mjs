#!/usr/bin/env node
import { mkdirSync, readFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { Client, Redactor } from './lib/http.mjs';
import { atomicJson } from './lib/fixtures.mjs';
import { inventoryFixtures, reconstructFixtures } from './lib/fixture-recovery.mjs';
import { resolveCredentials, targetOrigin } from './verify.mjs';

export const help = `Reconstruct a deployed-suite cleanup journal (read-only API calls)

  node deployed/recover-fixtures.mjs inventory --base-url URL --owner-id UUID --run-id UUID --out NEW_DIR
  node deployed/recover-fixtures.mjs reconstruct --base-url URL --evidence reviewed.json --out NEW_DIR

Inventory writes a candidate evidence.json, not permission to delete. Corroborate
the run, stop its writers, and account for ALL submitted create intents before
filling its three evidence notes and profiles. Add missing intents even when
nothing is visible. Reconstruction never treats an unknown create as absent.

Credentials: FOUNTAIN_SUITE_KEY, or the exact origin's fountain-deployed-suite
macOS keychain entry. Output includes cleanup-target.json; replay cleanup.json
with deployed/cli.mjs after reviewing it. See deployed/runner-loss-recovery.md.
`;

export async function recoverMain(argv, env = process.env) {
  const { values, positionals } = parseArgs({ args: argv, allowPositionals: true, options: {
    'base-url': { type: 'string' }, 'owner-id': { type: 'string' }, 'run-id': { type: 'string' },
    evidence: { type: 'string' }, out: { type: 'string' }, help: { type: 'boolean' },
  } });
  if (values.help) { console.log(help); return 0; }
  const [command] = positionals;
  if (positionals.length !== 1 || !['inventory', 'reconstruct'].includes(command) || !values['base-url'] || !values.out ||
    (command === 'inventory' ? !values['owner-id'] || !values['run-id'] || values.evidence : !values.evidence || values['owner-id'] || values['run-id'])) throw new Error(help);
  const origin = targetOrigin(values['base-url']).origin;
  const credentials = resolveCredentials(origin, env).env;
  if (!credentials.FOUNTAIN_SUITE_KEY) throw new Error('Dedicated FOUNTAIN_SUITE_KEY is unavailable for this origin');
  const out = resolve(values.out);
  mkdirSync(out, { mode: 0o700 });
  const redactor = new Redactor([credentials.FOUNTAIN_SUITE_KEY]);
  const client = new Client({ baseUrl: origin, key: credentials.FOUNTAIN_SUITE_KEY, redactor, trace: () => {},
    timeoutMs: 30000, signal: AbortSignal.timeout(120000) });
  try {
    if (command === 'inventory') {
      const evidence = await inventoryFixtures(client, { ownerId: values['owner-id'], runId: values['run-id'] });
      atomicJson(join(out, 'evidence.json'), evidence);
      console.log(`Found ${evidence.resources.length} candidates. Review ${join(out, 'evidence.json')}; this does not prove all requests settled.`);
    } else {
      const evidence = JSON.parse(readFileSync(resolve(values.evidence), 'utf8'));
      const manifest = await reconstructFixtures(client, evidence, join(out, 'cleanup.json'));
      atomicJson(join(out, 'evidence.json'), evidence);
      atomicJson(join(out, 'cleanup-target.json'), { base_url: origin, credentials: { primary: 'FOUNTAIN_SUITE_KEY' },
        profiles: ['probe'], limits: { request_ms: 30000, run_ms: 120000, cleanup_ms: 90000, resources: 100 } });
      console.log(`Reconstructed ${manifest.resources.length} intents (${manifest.resources.filter(r => r.state === 'pending').length} unresolved). No resources mutated. Review ${join(out, 'cleanup.json')}.`);
    }
    return 0;
  } catch (error) { throw new Error(redactor.text(error.message)); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.exitCode = await recoverMain(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 2; }
}
