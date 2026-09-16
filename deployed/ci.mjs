#!/usr/bin/env node
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from './lib/runner.mjs';
import { composeTarget, PROFILES } from './lib/target.mjs';
import { runMatrix, validateMatrix } from './matrix.mjs';

const matrixSubset = profile => ({ 'matrix-canary': 'canary', 'matrix-scheduled': 'scheduled', 'matrix-full': 'full' })[profile];

// Only controlled configuration messages may reach CI stderr. Parser errors
// can quote input values; unexpected errors can contain credentials or paths.
class SetupError extends Error {}
function settingObject(env, name) {
  let value;
  try { value = JSON.parse(env[name] || '{}'); }
  catch { throw new SetupError(`${name} must contain valid JSON`); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new SetupError(`${name} must be a JSON object`);
  return value;
}

export function ciConfig(env) {
  if (!['staging', 'production'].includes(env.SUITE_TARGET)) throw new SetupError('Target is not approved');
  if (env.SUITE_ENABLED !== 'true') throw new SetupError('Target environment is not enabled');
  if (!PROFILES.includes(env.SUITE_PROFILE) && !matrixSubset(env.SUITE_PROFILE)) throw new SetupError('Profile is not approved');
  const target = settingObject(env, 'SUITE_TARGET_JSON');
  let url;
  try { url = new URL(target.base_url); }
  catch { throw new SetupError('SUITE_TARGET_JSON must contain a valid base_url'); }
  if (url.protocol !== 'https:') throw new SetupError('CI targets require HTTPS ingress');
  target.credentials = { primary: 'FOUNTAIN_SUITE_KEY', secondary: 'FOUNTAIN_SUITE_OTHER_KEY' };
  // A matrix run drives its own cells from the probe profile.
  const config = composeTarget(target, matrixSubset(env.SUITE_PROFILE) ? 'probe' : env.SUITE_PROFILE);
  if (env.SUITE_MODE === 'rollout') {
    if (!config.deployment) throw new SetupError('Rollout requires an environment-owned deployment adapter');
    config.deployment.expected_digest = env.SUITE_EXPECTED_DIGEST;
  } else if (env.SUITE_MODE === 'public') {
    if (env.SUITE_EXPECTED_DIGEST) throw new SetupError('Expected digest requires rollout mode');
    delete config.deployment;
  } else throw new SetupError('Unknown verification mode');
  return config;
}

export async function ciMain(env = process.env) {
  const controller = new AbortController();
  const cancel = () => controller.abort(new Error('Interrupted'));
  process.on('SIGINT', cancel);
  process.on('SIGTERM', cancel);
  try {
    const config = ciConfig(env);
    const subset = matrixSubset(env.SUITE_PROFILE);
    const matrix = subset ? settingObject(env, 'SUITE_MATRIX_JSON') : undefined;
    if (matrix) {
      try { validateMatrix(matrix, subset); }
      catch { throw new SetupError('SUITE_MATRIX_JSON must describe a valid bounded matrix'); }
    }
    const root = resolve(env.RUNNER_TEMP || '.', `deployed-${env.GITHUB_RUN_ID || 'local'}-${env.GITHUB_RUN_ATTEMPT || '1'}`);
    mkdirSync(root, { mode: 0o700 });
    const configPath = resolve(root, 'target.json');
    writeFileSync(configPath, JSON.stringify(config), { mode: 0o600 });
    if (matrix) {
      const matrixPath = resolve(root, 'matrix.json');
      writeFileSync(matrixPath, JSON.stringify(matrix), { mode: 0o600 });
      return await runMatrix({ configPath, matrixPath, subset, out: resolve(root, 'results'), signal: controller.signal, env });
    }
    return await run({ configPath, out: resolve(root, 'results'), signal: controller.signal, env });
  } finally {
    process.off('SIGINT', cancel);
    process.off('SIGTERM', cancel);
  }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.exitCode = await ciMain(); }
  catch (error) {
    console.error(error instanceof SetupError ? `CI setup failed: ${error.message}` :
      'CI setup failed; check approved target configuration and required environment settings');
    process.exitCode = 2;
  }
}
