import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The independent Swift SDK version, checked against `sdk/swift/version.json`.
public let fountainSDKVersion = "0.20.0"

public final class Fountain: @unchecked Sendable {
  public let configuration: FountainConfiguration
  /// Authenticated raw HTTP escape hatch for endpoints not yet wrapped.
  public let api: FountainHTTPClient
  public let agents: Agents
  public let environments: Environments
  public let vaults: Vaults
  public let team: Team
  public let connections: Connections
  private let resolver: ResourceResolver

  /// Throws when a base URL supplied by an argument, the environment or the CLI
  /// credentials file is not a valid http(s) URL. It is never replaced with a
  /// different host.
  ///
  /// `session` supplies the configuration this client transports on — protocol
  /// classes, headers, cookie and credential storage, proxies, timeouts — not
  /// the session itself. The client builds its own, because it cancels the
  /// tasks it starts and on Linux that is only safe on a session it made
  /// (`FountainHTTPClient.transportConfiguration(from:)`).
  public init(
    apiKey: String? = nil,
    baseURL: String? = nil,
    profile: String? = nil,
    appURL: String? = nil,
    timeout: TimeInterval = 30,
    session: URLSession = .shared
  ) throws {
    let configuration = try FountainConfig.resolve(
      apiKey: apiKey, baseURL: baseURL, profile: profile, appURL: appURL)
    self.configuration = configuration
    self.api = FountainHTTPClient(configuration: configuration, timeout: timeout, session: session)
    let resolver = ResourceResolver(http: api)
    self.resolver = resolver
    self.agents = Agents(http: api, resolver: resolver, path: "/api/agents", what: "agent")
    self.environments = Environments(http: api, resolver: resolver)
    self.vaults = Vaults(http: api, resolver: resolver)
    self.team = Team(http: api, resolver: resolver)
    self.connections = Connections(http: api)
  }

  public func run(
    _ prompt: String,
    agent: String,
    vault: String? = nil,
    environment: String? = nil,
    title: String? = nil,
    images: [JSONObject]? = nil,
    clientRequestID: String? = nil,
    channelID: String? = nil,
    fresh: Bool = false,
    spriteName: String? = nil,
    sandbox: String? = nil,
    sandboxMode: String? = nil,
    sandboxAPIAccess: String? = nil,
    timeout: TimeInterval? = nil,
    collectEvents: Bool = false
  ) -> Run {
    Run(
      http: api,
      plan: RunPlan { [resolver] in
        guard
          let agentID = try await resolver.resolve(
            path: "/api/agents", what: "agent", nameOrID: agent)["id"]?.stringValue
        else {
          throw FountainError(.resolution, "Resolved agent did not include an id")
        }
        let vaultID = try await resolver.resolveID(
          path: "/api/vaults", what: "vault", nameOrID: vault)
        let environmentID = try await resolver.resolveID(
          path: "/api/environments", what: "environment", nameOrID: environment)
        var body: JSONObject = ["agent_id": .string(agentID)]
        if !prompt.isEmpty { body["prompt"] = .string(prompt) }
        if let vaultID { body["vault_id"] = .string(vaultID) }
        if let environmentID { body["environment_id"] = .string(environmentID) }
        if let title { body["title"] = .string(title) }
        if let images, !images.isEmpty { body["images"] = .array(images.map(JSONValue.object)) }
        if let clientRequestID { body["client_request_id"] = .string(clientRequestID) }
        if let channelID { body["channel_id"] = .string(channelID) }
        if fresh { body["fresh"] = .bool(true) }
        if let spriteName { body["sprite_name"] = .string(spriteName) }
        if let sandbox { body["sandbox_id"] = .string(sandbox) }
        if let sandboxMode { body["sandbox_mode"] = .string(sandboxMode) }
        if let sandboxAPIAccess { body["sandbox_api_access"] = .string(sandboxAPIAccess) }
        return try await self.startConversation(body)
      }, timeout: timeout, collectEvents: collectEvents)
  }

  /// Follow an API-shaped conversation request. Uses wire keys and IDs;
  /// timeout and event collection are local options and never enter the body.
  public func runRequest(
    _ request: JSONObject,
    timeout: TimeInterval? = nil,
    collectEvents: Bool = false
  ) throws -> Run {
    guard let prompt = request["prompt"]?.stringValue,
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw FountainError(.validation, "runRequest requires a nonblank prompt")
    }
    guard request["queue"] == nil || request["queue"] == .null || request["queue"] == .bool(false)
    else {
      throw FountainError(.validation, "runRequest does not support queued creation")
    }
    return Run(
      http: api, plan: RunPlan { try await self.startConversation(request) },
      timeout: timeout, collectEvents: collectEvents)
  }

  private func startConversation(_ request: JSONObject) async throws -> (JSONObject, Int, Int) {
    let response = try await api.request("POST", "/api/conversations", body: .object(request))
    let conversation = response["data"]?.objectValue ?? [:]
    if response["meta"]?["resumed"]?.boolValue == true,
      let id = conversation["id"]?.stringValue
    {
      // Resume only binds the channel. Capture history before submitting
      // the prompt so even a fast follow-up is followed from its beginning.
      let prompt = request["prompt"]?.stringValue
      let after = prompt == nil ? 0 : await Conversation(http: api, id: id).cursor()
      let turns = try await api.list("/api/conversations/\(id)/turns")
      let turnNumber = (turns.compactMap { $0["turn_number"]?.intValue }.max() ?? 0) + 1
      if let prompt {
        // Every create field that belongs *with* the prompt is repeated here:
        // this second request is the one that opens the turn.
        var body: JSONObject = ["prompt": .string(prompt)]
        if let images = request["images"] { body["images"] = images }
        if let clientRequestID = request["client_request_id"] {
          body["client_request_id"] = clientRequestID
        }
        _ = try await api.request("POST", "/api/conversations/\(id)/prompts", body: .object(body))
      }
      return (conversation, turnNumber, after)
    }
    return (conversation, 1, 0)
  }

  public func resume(_ conversationID: String) -> Conversation {
    Conversation(http: api, id: conversationID)
  }
  public func conversations(rootsOnly: Bool = true) async throws -> [JSONObject] {
    try await api.list("/api/conversations", query: ["roots_only": rootsOnly ? "true" : nil])
  }
  public func me() async throws -> JSONObject {
    try await api.request("GET", "/api/auth/me").objectValue ?? [:]
  }
  public func catalog() async throws -> JSONObject { try await api.data("GET", "/api/catalog") }
  public func sandboxes(status: [String]? = nil) async throws -> [JSONObject] {
    try await api.list("/api/sandboxes", query: ["status": status?.joined(separator: ",")])
  }
  public func sandbox(_ id: String) async throws -> JSONObject {
    try await api.data("GET", "/api/sandboxes/\(id)")
  }
  public func resetSandbox(_ id: String) async throws {
    _ = try await api.request("DELETE", "/api/sandboxes/\(id)")
  }
  public func sandboxFiles(_ id: String, path: String? = nil) async throws -> JSONObject {
    try await api.data("GET", "/api/sandboxes/\(id)/files", query: ["path": path])
  }
  public func sandboxFile(_ id: String, path: String, maxBytes: Int? = nil) async throws
    -> JSONObject
  {
    try await api.data(
      "GET", "/api/sandboxes/\(id)/file",
      query: ["path": path, "max_bytes": maxBytes.map(String.init)])
  }
  public func sandboxDiff(
    _ id: String, path: String? = nil, staged: Bool? = nil, ref: String? = nil, maxBytes: Int? = nil
  ) async throws -> JSONObject {
    try await api.data(
      "GET", "/api/sandboxes/\(id)/diff",
      query: [
        "path": path, "staged": staged.map { $0 ? "true" : "false" }, "ref": ref,
        "max_bytes": maxBytes.map(String.init),
      ])
  }
  public func search(_ query: String, limit: Int? = nil) async throws -> [JSONObject] {
    try await api.list("/api/search", query: ["q": query, "limit": limit.map(String.init)])
  }
  public func events(
    streams: [String]? = nil, after: Int = 0, wait: Bool = true, maxRetries: Int = 5
  ) -> AsyncThrowingStream<JSONObject, Error> {
    streamPath(
      http: api, path: "/api/events/stream", after: after,
      streams: streams?.joined(separator: ","), wait: wait, blocks: true, maxRetries: maxRetries
    )
  }
  public func refresh() async { await resolver.clear() }
  public func request(
    _ method: String, _ path: String, query: [String: String?] = [:], body: JSONValue? = nil
  ) async throws -> JSONValue {
    try await api.request(method, path, query: query, body: body)
  }
}
