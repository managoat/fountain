import { ensure } from './execution.mjs';
import { validateAppLock, appUrl } from './browser-app-lock.mjs';

const variable = /^[A-Z][A-Z0-9_]*$/;
export function validateBrowser(config, env) {
  const b = config.browser;
  ensure(new URL(config.base_url).pathname === '/', 'Browser console target must be the instance origin without a path prefix');
  ensure(config.profiles.length === 1 && !config.execution && !config.fixture, 'Run the browser console profile independently');
  ensure(b && Object.keys(b).every(k => ['email', 'password', 'agent', 'credential_provider', 'credential_setup', 'step_ms', 'conversations'].includes(k)), 'Expected explicit browser configuration');
  for (const name of ['email', 'password']) {
    ensure(variable.test(b[name]) && typeof env[b[name]] === 'string' && env[b[name]].length > 0, `Browser ${name} must name a populated environment variable`);
  }
  ensure(!env.DEBUG && !env.PWDEBUG && !env.PW_TRACE, 'Disable browser debug/native trace environment variables before entering credentials');
  const a = b.agent;
  ensure(a && Object.keys(a).every(k => ['runtime', 'model', 'sandbox_provider'].includes(k)) &&
    ['claude', 'codex', 'gemini'].includes(a.runtime) &&
    typeof a.model === 'string' && /^[a-z0-9_-]+\/[a-z0-9._-]+$/.test(a.model) &&
    ['sprites', 'e2b', 'runner'].includes(a.sandbox_provider), 'Pin the browser agent runtime, model and sandbox provider');
  ensure(['anthropic_api_key', 'claude_code_oauth_token', 'openai_api_key', 'gemini_api_key'].includes(b.credential_provider), 'Select a credential setup provider');
  if (b.credential_setup !== undefined) {
    const setup = b.credential_setup;
    ensure(setup && Object.keys(setup).sort().join(',') === 'exclusive_account,mode,value' &&
      setup.mode === 'save_and_clear' && setup.exclusive_account === true, 'Credential save/clear requires explicit exclusive-account reservation');
    ensure(variable.test(setup.value) && typeof env[setup.value] === 'string' && env[setup.value].trim().length > 0,
      'Credential value must name a populated environment variable');
    ensure(config.limits.resources >= (b.conversations ? 5 : 3), 'Credential setup needs an additional resource slot');
  }
  b.step_ms ??= 30000;
  ensure(Number.isSafeInteger(b.step_ms) && b.step_ms >= 1000 && b.step_ms <= 60000, 'Browser step_ms must be 1000-60000');
  ensure(b.conversations === null || (b.conversations && typeof b.conversations === 'object'), 'Declare conversations:null or an explicit pinned app journey');
  if (b.conversations) {
    const app = b.conversations;
    ensure(Object.keys(app).every(k => ['lock', 'auth', 'oauth', 'max_turns', 'provision_ms', 'turn_ms'].includes(k)), 'Unknown Conversations app setting');
    validateAppLock(app.lock);
    ensure(appUrl(app.lock.url).origin !== new URL(config.base_url).origin, 'Conversations app must use a separate origin to verify CORS');
    ensure(app.auth === 'ui_created_api_key' && app.oauth === 'deny', 'This adapter supports UI-created API key sign-in and OAuth denial; successful OAuth grants are not verified');
    ensure(app.max_turns === 2, 'Browser artifact journey requires an explicit two-prompt budget');
    for (const key of ['provision_ms', 'turn_ms']) {
      app[key] ??= key === 'provision_ms' ? 120000 : 90000;
      ensure(Number.isSafeInteger(app[key]) && app[key] >= 1000 && app[key] <= 300000, `Browser ${key} must be 1000-300000`);
    }
    ensure(config.limits.resources >= 4 && config.limits.run_ms >= app.provision_ms + 2 * app.turn_ms + 6 * b.step_ms,
      'App journey needs four resources and time for provision, two turns and sign-in');
  }
  ensure(config.limits.run_ms <= 600000 && config.limits.resources >= 2, 'Browser console requires a ten-minute bound and two-resource budget');
}
