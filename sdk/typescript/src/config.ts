export const DEFAULT_BASE_URL = "https://managoat.com";

/** Where a human reads a transcript. Managoat's own UI is a console (see CLAUDE.md). */
export const DEFAULT_APP_URL = "https://fountain-conversations.demo.managoat.com/";

export interface ResolvedConfig {
  baseUrl: string;
  apiKey: string;
  appUrl: string;
  /** Set when running inside a Managoat sandbox; stamps spawned conversations as children. */
  parentConversationId: string | undefined;
}

export interface ConfigOptions {
  /** Bearer token. Falls back to the environment, then `~/.managoat/credentials`. */
  apiKey?: string;
  /** Your Managoat deployment. Defaults to the hosted one. */
  baseUrl?: string;
  /** Credentials-file profile. Defaults to `$MANAGOAT_PROFILE` or `default`. */
  profile?: string;
  /** Base of the conversations app, for `run.url`. `""` falls back to the API URL. */
  appUrl?: string;
}

function unquote(value: string): string {
  const v = (value ?? "").trim();
  if (v.length >= 2 && v[0] === v[v.length - 1] && (v[0] === '"' || v[0] === "'")) {
    return v.slice(1, -1).trim();
  }
  return v;
}

/**
 * How to read `~/.managoat/credentials`, when there is a filesystem.
 *
 * The eleven apps built on Managoat so far are browser apps, and a bare
 * `import "node:fs"` at the top of this module breaks their bundles. So the
 * file reader is injected: `@managoat/sdk` resolves to a Node entry that
 * installs one, and to this browser-safe module everywhere else. Nothing here
 * touches a Node built-in.
 */
export type CredentialsReader = (profile: string) => Record<string, string>;

let credentialsReader: CredentialsReader | null = null;

/** Install a credentials-file reader. Called by the Node entry point. */
export function setCredentialsReader(reader: CredentialsReader | null): void {
  credentialsReader = reader;
}

/** Parse the INI-ish file `managoat auth login` writes. Exported for the Node entry. */
export function parseCredentials(raw: string, profile: string): Record<string, string> {
  const out: Record<string, string> = {};
  let section = "";
  for (const line of raw.split("\n")) {
    const text = line.trim();
    if (!text || text.startsWith("#") || text.startsWith(";")) continue;
    if (text.startsWith("[") && text.endsWith("]")) {
      section = text.slice(1, -1).trim();
      continue;
    }
    if (section !== profile) continue;
    const eq = text.indexOf("=");
    if (eq === -1) continue;
    out[text.slice(0, eq).trim()] = unquote(text.slice(eq + 1));
  }
  return out;
}

/** Absent, unreadable, or no reader installed is not an error — it contributes nothing. */
function readCredentials(profile: string): Record<string, string> {
  try {
    return credentialsReader?.(profile) ?? {};
  } catch {
    return {};
  }
}

/**
 * A `MANAGOAT_*` variable, or its `FOUNTAIN_*` name when it is unset: the
 * names before ADR 0082 renamed the project, which shells and sandboxes still
 * export. A later major stops reading the old names.
 */
export const env = (name: string): string => {
  // `process` is absent in a browser and undefined-typed in a worker.
  const vars = (globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env;
  const value = (vars?.[name] ?? "").trim();
  if (value || !name.startsWith("MANAGOAT_")) return value;
  return (vars?.[`FOUNTAIN_${name.slice("MANAGOAT_".length)}`] ?? "").trim();
};

/**
 * Resolve credentials the way the `managoat` CLI does, so a script inherits
 * whatever already works in the terminal:
 *
 *   apiKey:  option → MANAGOAT_API_KEY → MANAGOAT_TOKEN → ~/.managoat/credentials
 *   baseUrl: option → MANAGOAT_BASE_URL → ~/.managoat/credentials → hosted
 *
 * `MANAGOAT_TOKEN` is what a Managoat sandbox exports for the agent inside it,
 * so an agent that reaches for this SDK delegates with the conversation-scoped
 * token it already has — and the conversations it starts are recorded as its
 * children.
 */
export function resolveConfig(options: ConfigOptions = {}): ResolvedConfig {
  const profile = (options.profile ?? "").trim() || env("MANAGOAT_PROFILE") || "default";
  let creds: Record<string, string> | undefined;
  const credentials = (): Record<string, string> => (creds ??= readCredentials(profile));

  let apiKey = (options.apiKey ?? "").trim() || env("MANAGOAT_API_KEY") || env("MANAGOAT_TOKEN");
  if (!apiKey) apiKey = credentials().api_key ?? "";

  let baseUrl = (options.baseUrl ?? "").trim() || env("MANAGOAT_BASE_URL");
  if (!baseUrl) baseUrl = credentials().base_url || DEFAULT_BASE_URL;

  const appUrl = options.appUrl !== undefined ? options.appUrl.trim() : env("MANAGOAT_APP_URL") || DEFAULT_APP_URL;

  return {
    baseUrl: baseUrl.replace(/\/+$/, ""),
    apiKey,
    appUrl: appUrl.replace(/\/+$/, ""),
    parentConversationId: env("MANAGOAT_CONVERSATION_ID") || undefined,
  };
}

/** The URL a human opens to watch this conversation. */
export function conversationUrl(conversationId: string, config: ResolvedConfig): string {
  if (!config.appUrl) return `${config.baseUrl}/api/conversations/${conversationId}`;
  return `${config.appUrl}/#/c/${conversationId}`;
}
