import Foundation

public struct TeamResource: Sendable {
  let client: APIClient

  public func list() async throws -> [Teammate] {
    try await client.data(.get, "/api/team")
  }

  public func get(_ agentID: String) async throws -> Teammate {
    try await client.data(.get, "/api/team/\(agentID)")
  }

  /// Hire an agent. 200 when already on the team, 201 when new — both
  /// return the teammate.
  public func add(
    _ agentID: String,
    name: String? = nil,
    environmentID: String? = nil,
    vaultID: String? = nil
  ) async throws -> Teammate {
    struct Body: Encodable {
      var agentID: String
      var name: String?
      var environmentID: String?
      var vaultID: String?

      enum CodingKeys: String, CodingKey {
        case name
        case agentID = "agent_id"
        case environmentID = "environment_id"
        case vaultID = "vault_id"
      }
    }
    return try await client.data(
      .post, "/api/team",
      body: Body(agentID: agentID, name: name, environmentID: environmentID, vaultID: vaultID)
    )
  }

  /// `nil`/blank restores the agent's own name.
  public func rename(_ agentID: String, name: String?) async throws -> Teammate {
    try await client.data(.patch, "/api/team/\(agentID)", body: ["name": name])
  }

  public func remove(_ agentID: String) async throws {
    try await client.send(.delete, "/api/team/\(agentID)", options: .init(timeout: 120))
  }

  /// Queue a message (202). The reply arrives on the team stream. Throws
  /// `.conversationBusy` mid-turn (queue and flush on turn end) and
  /// `.notReady` while the computer is provisioning.
  @discardableResult
  public func message(_ agentID: String, _ prompt: String, images: [ImageInput]? = nil) async throws
    -> String?
  {
    struct Body: Encodable {
      var prompt: String
      var images: [ImageInput]?
    }
    struct Reply: Decodable {
      var conversationID: String?
      enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
      }
    }
    // Unenveloped response.
    let reply: Reply = try await client.request(
      .post, "/api/team/\(agentID)/messages",
      body: Body(prompt: prompt, images: images)
    )
    return reply.conversationID
  }

  /// Thread history, newest first; the current thread is flagged.
  public func conversations(_ agentID: String) async throws -> [Conversation] {
    try await client.data(.get, "/api/team/\(agentID)/conversations")
  }

  /// Retire the thread, keep the computer. For a new computer, terminate
  /// the current conversation first, then call this.
  public func freshConversation(_ agentID: String) async throws -> Conversation {
    try await client.data(.post, "/api/team/\(agentID)/conversations")
  }

  /// One stream for the whole roster; events carry `conversation_id` and
  /// `agent_id`. `team`/`schedule` signals mean re-list.
  public func stream(_ request: StreamRequest = StreamRequest()) -> AsyncThrowingStream<
    StreamEvent, Error
  > {
    EventStreamLoop.stream(client: client, path: "/api/team/stream", request: request)
  }

  // MARK: schedules

  /// Every schedule of the caller (all agents), soonest first.
  public func allSchedules() async throws -> [TeamSchedule] {
    try await client.data(.get, "/api/team/schedules")
  }

  public func schedules(_ agentID: String) async throws -> [TeamSchedule] {
    try await client.data(.get, "/api/team/\(agentID)/schedules")
  }

  public func createSchedule(_ agentID: String, _ input: TeamScheduleInput) async throws
    -> TeamSchedule
  {
    try await client.data(.post, "/api/team/\(agentID)/schedules", body: input)
  }

  public func updateSchedule(_ agentID: String, _ id: String, _ patch: TeamScheduleInput)
    async throws -> TeamSchedule
  {
    try await client.data(.patch, "/api/team/\(agentID)/schedules/\(id)", body: patch)
  }

  public func deleteSchedule(_ agentID: String, _ id: String) async throws {
    try await client.send(.delete, "/api/team/\(agentID)/schedules/\(id)")
  }

  /// Fire a schedule now (202); returns the conversation id it queued into.
  @discardableResult
  public func runSchedule(_ agentID: String, _ id: String) async throws -> String? {
    struct Reply: Decodable {
      var conversationID: String?
      enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
      }
    }
    let reply: Reply = try await client.request(.post, "/api/team/\(agentID)/schedules/\(id)/run")
    return reply.conversationID
  }
}
