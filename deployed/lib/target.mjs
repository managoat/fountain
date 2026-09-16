// Profile composition shared by the CI entry point and the local verify
// command. Both compose the same run from a caller-supplied target so that a
// local verdict and a CI verdict mean the same thing.

export const PROFILES = ['probe', 'basic', 'execution', 'streaming', 'canary', 'secrets', 'mcp', 'webhooks', 'schedules'];

// `canary` is the only alias: it is basic API coverage plus two real turns.
export function profileList(profile) {
  return profile === 'canary' ? ['basic', 'execution'] : [profile];
}

// Bound exposure even if a caller asks for a longer run. Scheduled execution
// waits for a cron to fire, so it alone gets the longer bound.
export function profileLimits(profile) {
  return { request_ms: 30000, run_ms: profile === 'schedules' ? 900000 : 420000, cleanup_ms: 90000, resources: 12 };
}

// Profiles that assert on delivery rather than on model output spend fewer
// prompts; webhooks needs none at all.
export function profileTurns(profile) {
  if (profile === 'webhooks') return 0;
  return ['secrets', 'schedules'].includes(profile) ? 1 : 2;
}

export function profileExecution(profile, execution) {
  return { ...execution, provision_ms: 120000, turn_ms: 90000, max_turns: profileTurns(profile) };
}

// A run always applies the suite's own profile list, limits and execution
// timings over whatever the caller supplied.
export function composeTarget(config, profile) {
  const composed = { ...config, profiles: profileList(profile), limits: profileLimits(profile) };
  if (composed.execution) composed.execution = profileExecution(profile, composed.execution);
  return composed;
}
