import Foundation

/// The Fountain API, one namespace per resource. Construct one per
/// (deployment, key) pair; it is a value type and cheap to copy.
///
/// ```swift
/// let fountain = FountainClient(config: .init(baseURL: url, apiKey: key))
/// let me = try await fountain.auth.me()          // cheapest key check
/// let agents = try await fountain.agents.list()
/// for try await event in fountain.conversations.stream(id).logEvents { ... }
/// ```
public struct FountainClient: Sendable {
  public let api: APIClient

  public init(config: FountainConfig, transport: any HTTPTransport = URLSessionTransport()) {
    self.api = APIClient(config: config, transport: transport)
  }

  init(api: APIClient) {
    self.api = api
  }

  public var config: FountainConfig { api.config }

  public var agents: AgentsResource { AgentsResource(client: api) }
  public var environments: EnvironmentsResource { EnvironmentsResource(client: api) }
  public var vaults: VaultsResource { VaultsResource(client: api) }
  public var conversations: ConversationsResource { ConversationsResource(client: api) }
  public var events: EventsResource { EventsResource(client: api) }
  public var connections: ConnectionsResource { ConnectionsResource(client: api) }
  public var team: TeamResource { TeamResource(client: api) }
  public var sandboxes: SandboxesResource { SandboxesResource(client: api) }
  public var runners: RunnersResource { RunnersResource(client: api) }
  public var auth: AuthResource { AuthResource(client: api) }
  public var audit: AuditResource { AuditResource(client: api) }
  public var search: SearchResource { SearchResource(client: api) }
  /// Admin-only; every call 403s unless `auth.me` says `role == admin`.
  public var admin: AdminResource { AdminResource(client: api) }

  /// `GET /api/catalog` — runtimes, model suggestions, sandbox providers,
  /// and where the conversation/team apps live.
  public func catalog() async throws -> Catalog {
    try await api.data(.get, "/api/catalog")
  }

  /// Declarative bulk apply. One manifest reconciles `Environment`, `Vault`,
  /// `Agent`, `Teammate`, `Schedule` and `Webhook` documents, in that order.
  public func apply(resources: [JSONValue]) async throws -> [ApplyResult] {
    struct Response: Decodable {
      var results: [ApplyResult]
    }
    let response: Response = try await api.data(.post, "/api/apply", body: ["resources": resources])
    return response.results
  }

  /// Escape hatch for anything not wrapped yet: returns the raw bytes of
  /// a 2xx response.
  @discardableResult
  public func request(
    _ method: HTTPMethod,
    _ path: String,
    body: (some Encodable & Sendable)? = nil as NoBody?,
    query: [String: String?] = [:]
  ) async throws -> Data {
    let (data, _) = try await api.raw(method, path, body: body, options: .init(query: query))
    return data
  }

  /// Deep link a human to a transcript, via the deployment's conversations
  /// app when one exists.
  public func conversationURL(_ id: String, apps: Catalog.Apps?) -> URL {
    if let app = apps?.conversations, !app.isEmpty, let url = URL(string: "\(app)/#/c/\(id)") {
      return url
    }
    return config.baseURL.appendingPathComponent("conversations/\(id)")
  }
}
