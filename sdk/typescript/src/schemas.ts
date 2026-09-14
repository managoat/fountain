/**
 * The API's own types, straight from its OpenAPI document.
 *
 * `src/generated/openapi.ts` is produced by `npm run generate` from the same
 * spec the server serves at `GET /api/openapi.json`, and CI regenerates it and
 * fails on a diff. So these are not a description of the API that someone has
 * to remember to update — they are the API, and a field added to a schema in
 * Elixir shows up here on the next build.
 *
 * The hand-written layer above this one exists for the things a spec cannot
 * express: what a *turn* is (many log events folded into one answer), that a
 * run can be awaited or streamed, and which of 85 paths are worth a verb.
 */
import type { components } from "./generated/openapi.ts";

type S = components["schemas"];

/** `T` with `K` made optional — for fields the API defaults and the generator does not. */
type Optional<T, K extends keyof T> = Omit<T, K> & Partial<Pick<T, K>>;

// ── the four primitives ──────────────────────────────────────────────────────

/** A named, re-runnable agent config — runtime, model, skills, environment. */
export type Agent = S["Agent"];
/** Everything that decides how a run behaves, before the prompt. */
export type AgentInput = S["AgentRequest"];
/** A partial agent definition, for `update`. */
export type AgentPatch = S["AgentUpdate"];

/** The sandbox shape an agent runs in: packages, repos, env vars, networking. */
export type Environment = S["Environment"];
export type EnvironmentInput = S["EnvironmentRequest"];
export type EnvironmentPatch = S["EnvironmentUpdate"];

/** A free-floating bag of env-var overrides, chosen per conversation. */
export type Vault = S["Vault"];
export type VaultInput = S["VaultRequest"];
export type VaultPatch = S["VaultUpdate"];

/** One run of an agent inside a sandbox. */
export type ConversationRecord = S["Conversation"];
/** A machine, with the conversations on it. */
export type SandboxRecord = S["SandboxDetail"];
/** One directory on a sandbox, directories first (ADR 0039). */
export type SandboxListing = S["SandboxListing"];
/** One entry of a `SandboxListing`. */
export type SandboxEntry = S["SandboxEntry"];
/** One file on a sandbox, redacted; `content` is text or base64 per `encoding`. */
export type SandboxFile = S["SandboxFile"];
/** `git diff` of a repository on a sandbox, redacted. */
export type SandboxDiff = S["SandboxDiff"];
/** `git status` of a repository on a sandbox, one entry per changed path. */
export type SandboxStatus = S["SandboxStatus"];
/** One changed path of a `SandboxStatus`. */
export type SandboxChange = S["SandboxChange"];
/** One prompt and everything the agent did in response. */
export type Turn = S["Turn"];
/** One row of a conversation's log feed. */
export type LogEvent = S["LogEvent"];
/** A server-parsed piece of an agent's output (`?blocks=true`). */
export type Block = S["Block"];

// ── secrets ──────────────────────────────────────────────────────────────────

/** A stored secret. Values are write-only — the API never returns them. */
export type Secret = S["Secret"];
export type VaultSecret = S["VaultSecret"];
export type VaultSecretMetadataPatch = S["VaultSecretMetadataRequest"];

// ── the team ─────────────────────────────────────────────────────────────────

/** An agent that has been put on the team, with its standing conversation. */
export type Teammate = S["Teammate"];
export type TeamAddInput = S["TeamAddRequest"];
/** A cron that runs a teammate with a prompt. */
export type Schedule = S["TeamSchedule"];
/**
 * Creating one. `enabled` and `one_off` are optional on the wire — the server
 * defaults them to `true` and `false` — but the generator marks a property
 * that carries a default as required, so they are relaxed back here.
 */
export type ScheduleInput = Optional<S["TeamScheduleCreateRequest"], "enabled" | "one_off">;
export type SchedulePatch = S["TeamScheduleUpdateRequest"];

// ── everything else the SDK surfaces ─────────────────────────────────────────

/** The form vocabulary: runtimes, models, providers a client can offer. */
export type Catalog = S["CatalogResponse"]["data"];
/** One hit from full-text search across the caller's conversations. */
export type SearchHit = S["SearchHit"];
/** A node in a conversation's spawn tree. */
export type ConversationTreeNode = S["ConversationTreeNode"];
export type Runner = S["Runner"];
/** A provider account the tenant signed in to once; Fountain holds the credential (#1178). */
export type Connection = S["Connection"];
/**
 * Where a connection's tokens come from (#1186): the platform provider
 * (Google, id `google`), the tenant's own OAuth app at a service (`oauth2`),
 * or a remote MCP server whose authorization Fountain discovered (`mcp`).
 */
export type ConnectionProvider = S["ConnectionProvider"];
/** Defining one. `kind: "mcp"` needs only `mcp_url`; the rest comes from discovery. */
export type ConnectionProviderInput = S["ConnectionProviderRequest"];
export type ConnectionProviderPatch = Partial<ConnectionProviderInput>;
export type Repository = S["Repository"];
export type ImageInput = S["ImageInput"];
export type AuthMe = S["AuthMeResponse"];

/** Every path and operation, for callers reaching past the wrapped verbs. */
export type { paths, components, operations } from "./generated/openapi.ts";
