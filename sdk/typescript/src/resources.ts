import type { HttpClient } from "./http.ts";
import type { Resolver } from "./resolve.ts";
import type {
  Agent,
  AgentInput,
  AgentPatch,
  Environment,
  EnvironmentInput,
  EnvironmentPatch,
  Secret,
  Vault,
  VaultInput,
  VaultPatch,
  VaultSecret,
  VaultSecretMetadataPatch,
} from "./types.ts";

/**
 * Payloads here use the API's own key names (`environment_id`, `mcp_servers`,
 * `allowed_vault_ids`) rather than camelCase. That is a choice, not an
 * oversight: an agent definition is the same object in the REST API, in a
 * `fountain.yml` manifest and here, so one definition reads identically in all
 * three and the API reference doubles as the SDK reference. Options that
 * control the SDK's own behaviour — `timeoutMs`, `signal` — are camelCase,
 * because those are not data.
 */

/**
 * List, read, define, change and delete one kind of thing.
 *
 * `Patch` is its own parameter rather than `Partial<Input>`: the API's update
 * schemas are not simply every create field made optional, and the generated
 * ones say so exactly.
 */
class Collection<T extends { id: string }, Input, Patch> {
  protected readonly http: HttpClient;
  protected readonly resolver: Resolver;
  protected readonly path: string;
  protected readonly what: string;

  constructor(http: HttpClient, resolver: Resolver, path: string, what: string) {
    this.http = http;
    this.resolver = resolver;
    this.path = path;
    this.what = what;
  }

  /** Everything on the account. */
  async list(search?: string): Promise<T[]> {
    return this.http.list<T>(this.path, { query: { search } });
  }

  /** One of them, by name or id. */
  async get(nameOrId: string): Promise<T> {
    const { id } = await this.resolver.resolve(this.path, this.what, nameOrId);
    return this.http.data<T>("GET", `${this.path}/${id}`);
  }

  /** Define a new one. */
  async create(input: Input): Promise<T> {
    const created = await this.http.data<T>("POST", this.path, { body: input });
    // A new name has to be findable by the next `run({ agent: "…" })`.
    this.resolver.forget(this.path);
    return created;
  }

  /** Change one. Only the fields you pass are touched. */
  async update(nameOrId: string, patch: Patch): Promise<T> {
    const { id } = await this.resolver.resolve(this.path, this.what, nameOrId);
    const updated = await this.http.data<T>("PATCH", `${this.path}/${id}`, { body: patch });
    // The patch may have renamed it.
    this.resolver.forget(this.path);
    return updated;
  }

  /** Delete one. */
  async delete(nameOrId: string): Promise<void> {
    const { id } = await this.resolver.resolve(this.path, this.what, nameOrId);
    await this.http.request("DELETE", `${this.path}/${id}`);
    this.resolver.forget(this.path);
  }
}

/**
 * Secrets on an environment or a vault.
 *
 * Values are write-only: `list` returns keys, never what they are worth. That
 * is the whole point — the SDK can put a credential into a sandbox and can
 * never read it back out.
 */
class Secrets {
  protected readonly http: HttpClient;
  private readonly resolver: Resolver;
  private readonly parentPath: string;
  private readonly what: string;

  constructor(http: HttpClient, resolver: Resolver, parentPath: string, what: string) {
    this.http = http;
    this.resolver = resolver;
    this.parentPath = parentPath;
    this.what = what;
  }

  /** The keys stored here. Never the values. */
  async list(parent: string): Promise<Secret[]> {
    return this.http.list<Secret>(`${await this.parentId(parent)}/secrets`);
  }

  /** Store a secret, or replace one with the same key. */
  async set(parent: string, key: string, value: string): Promise<Secret> {
    return this.http.data<Secret>("POST", `${await this.parentId(parent)}/secrets`, {
      body: { key, value },
    });
  }

  /** Store several at once. */
  async setAll(parent: string, secrets: Record<string, string>): Promise<Secret[]> {
    const base = await this.parentId(parent);
    const out: Secret[] = [];
    // Serially: these are audited writes, and a partial failure should say
    // which key it stopped on rather than leave a scattered half-write.
    for (const [key, value] of Object.entries(secrets)) {
      out.push(
        await this.http.data<Secret>("POST", `${base}/secrets`, { body: { key, value } }),
      );
    }
    return out;
  }

  /** Remove one, by key. */
  async delete(parent: string, key: string): Promise<void> {
    await this.http.request("DELETE", `${await this.parentId(parent)}/secrets/${encodeURIComponent(key)}`);
  }

  protected async parentId(nameOrId: string): Promise<string> {
    const { id } = await this.resolver.resolve(this.parentPath, this.what, nameOrId);
    return `${this.parentPath}/${id}`;
  }
}

/** Vault metadata can change without reading or replacing its secret value. */
class VaultSecrets extends Secrets {
  async update(parent: string, key: string, patch: VaultSecretMetadataPatch): Promise<VaultSecret> {
    return this.http.data<VaultSecret>(
      "PATCH", `${await this.parentId(parent)}/secrets/${encodeURIComponent(key)}`, { body: patch },
    );
  }
}

/** The agents on this account. */
export class Agents extends Collection<Agent, AgentInput, AgentPatch> {
  constructor(http: HttpClient, resolver: Resolver) {
    super(http, resolver, "/api/agents", "agent");
  }
}

/** The environments on this account, and their secrets. */
export class Environments extends Collection<Environment, EnvironmentInput, EnvironmentPatch> {
  readonly secrets: Secrets;

  constructor(http: HttpClient, resolver: Resolver) {
    super(http, resolver, "/api/environments", "environment");
    this.secrets = new Secrets(http, resolver, this.path, this.what);
  }
}

/** The vaults on this account, and their secrets. */
export class Vaults extends Collection<Vault, VaultInput, VaultPatch> {
  readonly secrets: VaultSecrets;

  constructor(http: HttpClient, resolver: Resolver) {
    super(http, resolver, "/api/vaults", "vault");
    this.secrets = new VaultSecrets(http, resolver, this.path, this.what);
  }
}
