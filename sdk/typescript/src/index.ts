export { Fountain, type FountainOptions, type RunConfig } from "./client.ts";
export { Run, type RunOptions } from "./run.ts";
export { Conversation, type ReapplyOptions, type SendOptions } from "./conversation.ts";
export { HttpClient, type FetchLike, type RequestOptions } from "./http.ts";
export { Agents, Environments, Vaults } from "./resources.ts";
export { Team, TeamSchedules, type MessageOptions } from "./team.ts";
export {
  resolveConfig,
  conversationUrl,
  DEFAULT_BASE_URL,
  DEFAULT_APP_URL,
  type ConfigOptions,
  type ResolvedConfig,
} from "./config.ts";
export { streamEvents, streamPath, parseSse, type StreamOptions, type SseMessage } from "./sse.ts";
export { TurnFollower } from "./turn.ts";
export {
  FountainError,
  AuthError,
  NotFoundError,
  ValidationError,
  RateLimitError,
  ConversationBusyError,
  NotReadyError,
  ConnectionError,
  TimeoutError,
  ResolutionError,
  type FountainErrorCode,
} from "./errors.ts";
export type * from "./schemas.ts";
export type {
  Agent,
  AgentInput,
  Block,
  ConversationRecord,
  ConversationStatus,
  Environment,
  EnvironmentInput,
  LogEvent,
  NamedResource,
  PermissionOption,
  PermissionRequest,
  Stream,
  TeamEvent,
  Repository,
  Runtime,
  RunEvent,
  RunResult,
  SandboxChange,
  SandboxDiff,
  SandboxEntry,
  SandboxFile,
  SandboxListing,
  SandboxProvider,
  SandboxRecord,
  SandboxStatus,
  Secret,
  SkillInput,
  Turn,
  TurnState,
  Vault,
  VaultInput,
  VaultSecretMetadataPatch,
} from "./types.ts";

import { Fountain } from "./client.ts";
export default Fountain;
