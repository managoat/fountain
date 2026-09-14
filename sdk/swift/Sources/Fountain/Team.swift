import Foundation

public final class Team: @unchecked Sendable {
  private let http: FountainHTTPClient
  private let resolver: ResourceResolver
  public let schedules: TeamSchedules

  init(http: FountainHTTPClient, resolver: ResourceResolver) {
    self.http = http
    self.resolver = resolver
    self.schedules = TeamSchedules(http: http, resolver: resolver)
  }

  public func list() async throws -> [JSONObject] { try await http.list("/api/team") }
  public func get(_ agent: String) async throws -> JSONObject {
    try await http.data("GET", "/api/team/\(try await agentID(agent))")
  }
  public func add(_ agent: String, options: JSONObject = [:]) async throws -> JSONObject {
    var body = options
    body["agent_id"] = .string(try await agentID(agent))
    return try await http.data("POST", "/api/team", body: body)
  }
  public func remove(_ agent: String) async throws {
    _ = try await http.request("DELETE", "/api/team/\(try await agentID(agent))")
  }
  public func rename(_ agent: String, name: String?) async throws -> JSONObject {
    try await http.data(
      "PATCH", "/api/team/\(try await agentID(agent))",
      body: ["name": name.map(JSONValue.string) ?? .null])
  }

  public func message(
    _ agent: String, _ prompt: String, images: [JSONObject]? = nil,
    timeout: TimeInterval? = nil, collectEvents: Bool = false
  ) -> Run {
    Run(
      http: http,
      plan: RunPlan { [http, resolver] in
        guard
          let agentID = try await resolver.resolve(
            path: "/api/agents", what: "agent", nameOrID: agent)["id"]?.stringValue
        else {
          throw FountainError(.resolution, "Resolved agent did not include an id")
        }
        let before = try? await http.data("GET", "/api/team/\(agentID)")
        let existing = before?["conversation"]?["id"]?.stringValue
        var after = 0
        var turnNumber = 1
        if let existing {
          let handle = Conversation(http: http, id: existing)
          after = await handle.cursor()
          turnNumber = (try await handle.lastTurnNumber()) + 1
        }
        var body: JSONObject = ["prompt": .string(prompt)]
        if let images, !images.isEmpty { body["images"] = .array(images.map(JSONValue.object)) }
        let sent = try await http.request(
          "POST", "/api/team/\(agentID)/messages", body: .object(body))
        guard let conversationID = sent["conversation_id"]?.stringValue ?? existing else {
          throw FountainError(.api, "Team message response did not include a conversation id")
        }
        if conversationID != existing {
          after = 0
          turnNumber = 1
        }
        return (
          try await http.data("GET", "/api/conversations/\(conversationID)"), turnNumber, after
        )
      }, timeout: timeout, collectEvents: collectEvents)
  }

  public func conversation(_ agent: String) async throws -> Conversation {
    guard let id = try await get(agent)["conversation"]?["id"]?.stringValue else {
      throw FountainError(.api, "\(agent) has no conversation yet — send it a message first")
    }
    return Conversation(http: http, id: id)
  }
  public func history(_ agent: String) async throws -> [JSONObject] {
    try await http.list("/api/team/\(try await agentID(agent))/conversations")
  }
  public func freshConversation(_ agent: String) async throws -> JSONObject {
    try await http.data("POST", "/api/team/\(try await agentID(agent))/conversations")
  }
  public func stream(
    streams: [String]? = nil, after: Int = 0, wait: Bool = true, maxRetries: Int = 5
  ) -> AsyncThrowingStream<JSONObject, Error> {
    streamPath(
      http: http, path: "/api/team/stream", after: after,
      streams: streams?.joined(separator: ","), wait: wait, blocks: true, maxRetries: maxRetries
    )
  }
  private func agentID(_ value: String) async throws -> String {
    guard
      let id = try await resolver.resolve(path: "/api/agents", what: "agent", nameOrID: value)[
        "id"]?.stringValue
    else {
      throw FountainError(.resolution, "Resolved agent did not include an id")
    }
    return id
  }
}

public final class TeamSchedules: @unchecked Sendable {
  private let http: FountainHTTPClient
  private let resolver: ResourceResolver
  init(http: FountainHTTPClient, resolver: ResourceResolver) {
    self.http = http
    self.resolver = resolver
  }
  public func list(agent: String? = nil) async throws -> [JSONObject] {
    if let agent { return try await http.list("/api/team/\(try await agentID(agent))/schedules") }
    return try await http.list("/api/team/schedules")
  }
  public func get(_ agent: String, id: String) async throws -> JSONObject {
    try await http.data("GET", try await path(agent, id))
  }
  public func create(_ agent: String, input: JSONObject) async throws -> JSONObject {
    try await http.data("POST", try await path(agent), body: input)
  }
  public func update(_ agent: String, id: String, patch: JSONObject) async throws -> JSONObject {
    try await http.data("PATCH", try await path(agent, id), body: patch)
  }
  public func delete(_ agent: String, id: String) async throws {
    _ = try await http.request("DELETE", try await path(agent, id))
  }
  public func run(_ agent: String, id: String) async throws -> JSONValue {
    try await http.request("POST", try await path(agent, id) + "/run")
  }
  private func path(_ agent: String, _ id: String? = nil) async throws -> String {
    let base = "/api/team/\(try await agentID(agent))/schedules"
    return id.map { "\(base)/\($0)" } ?? base
  }
  private func agentID(_ value: String) async throws -> String {
    guard
      let id = try await resolver.resolve(path: "/api/agents", what: "agent", nameOrID: value)[
        "id"]?.stringValue
    else {
      throw FountainError(.resolution, "Resolved agent did not include an id")
    }
    return id
  }
}
