import Foundation

/// The result of opening a conversation: 201 created, or 200 with
/// `meta.resumed` when a `channel_id` resumed an existing one.
public struct OpenedConversation: Sendable {
  public var conversation: Conversation
  public var resumed: Bool
}

public struct ConversationsResource: Sendable {
  let client: APIClient

  public func list(
    rootsOnly: Bool = false,
    agentID: String? = nil,
    channelID: String? = nil,
    status: [ConversationStatus] = []
  ) async throws -> [Conversation] {
    try await client.data(
      .get, "/api/conversations",
      options: .init(query: [
        "roots_only": rootsOnly ? "true" : nil,
        "agent_id": agentID,
        "channel_id": channelID,
        "status": status.isEmpty ? nil : status.map(\.rawValue).joined(separator: ","),
      ]))
  }

  public func get(_ id: String) async throws -> Conversation {
    try await client.data(.get, "/api/conversations/\(id)")
  }

  public func create(_ request: ConversationCreateRequest) async throws -> OpenedConversation {
    guard request.queue != true else {
      throw ConversationRunInputError(
        message: "create returns a conversation; use the raw API for queued creation")
    }
    let (data, response) = try await client.raw(.post, "/api/conversations", body: request)
    let envelope = try APIClient.decode(Envelope<Conversation>.self, from: data)
    // 200 + meta.resumed means a channel_id matched an existing conversation.
    let resumed = response.statusCode == 200
    return OpenedConversation(conversation: envelope.data, resumed: resumed)
  }

  public func delete(_ id: String) async throws {
    try await client.send(.delete, "/api/conversations/\(id)")
  }

  /// Reapply a conversation's agent, environment and vault on the machine it
  /// is already running. The conversation, its transcript and the files on
  /// disk all stay. An empty request reapplies what is already selected.
  public func reapply(
    _ id: String,
    _ request: ConversationReapplyRequest = ConversationReapplyRequest()
  ) async throws -> Conversation {
    try await client.data(.post, "/api/conversations/\(id)/reapply", body: request)
  }

  /// Queue a follow-up turn. The 200 is not the answer — the words arrive
  /// on the stream. Throws `.conversationBusy` mid-turn; queue and retry
  /// on turn end.
  ///
  /// `clientRequestID` is the caller's own name for this submission. It is
  /// carried to the turn the prompt opens and onto that turn's `started`
  /// event (#1406), so the caller reads back which turn was its own instead
  /// of guessing from turn order. It is not an idempotency key: the same
  /// value sent twice opens two turns.
  public func prompt(
    _ id: String, _ prompt: String, images: [ImageInput]? = nil,
    clientRequestID: String? = nil
  ) async throws {
    struct Body: Encodable {
      var prompt: String
      var images: [ImageInput]?
      var clientRequestID: String?

      enum CodingKeys: String, CodingKey {
        case prompt
        case images
        case clientRequestID = "client_request_id"
      }
    }
    try await client.send(
      .post, "/api/conversations/\(id)/prompts",
      body: Body(prompt: prompt, images: images, clientRequestID: clientRequestID)
    )
  }

  public func interrupt(_ id: String) async throws {
    try await client.send(.post, "/api/conversations/\(id)/interrupt")
  }

  /// Waits on sandbox teardown — allow a generous timeout, and let it
  /// finish even if the UI moved on.
  public func terminate(_ id: String) async throws {
    try await client.send(
      .post, "/api/conversations/\(id)/terminate",
      options: .init(timeout: 120)
    )
  }

  public func markRead(_ id: String) async throws {
    try await client.send(.post, "/api/conversations/\(id)/read")
  }

  public func turns(_ id: String) async throws -> [Turn] {
    try await client.data(.get, "/api/conversations/\(id)/turns")
  }

  public func tree(_ id: String) async throws -> [ConversationTreeNode] {
    try await client.data(.get, "/api/conversations/\(id)/tree")
  }

  /// Answer a permission request with one of the options the agent offered.
  /// A 409 `permission_request_resolved` means someone answered first —
  /// normal, not a failure worth surfacing loudly.
  public func answer(_ id: String, requestID: String, optionID: String) async throws {
    try await client.send(
      .post, "/api/conversations/\(id)/requests/\(encodePathComponent(requestID))",
      body: ["option_id": optionID]
    )
  }

  /// One page of the JSON log feed, oldest first.
  public func events(
    _ id: String,
    after: Int = 0,
    limit: Int = 1000,
    streams: [LogStream] = []
  ) async throws -> Page<[LogEvent], PageMeta> {
    let (data, _) = try await client.raw(
      .get, "/api/conversations/\(id)/events",
      options: .init(query: [
        "after": String(after),
        "limit": String(limit),
        "blocks": "true",
        "streams": streams.isEmpty ? nil : streams.map(\.rawValue).joined(separator: ","),
      ]))
    let response = try APIClient.decode(LogEventListResponse.self, from: data)
    return Page(items: response.data, meta: response.meta)
  }

  /// The whole feed from `after`, paging until `has_more` is false.
  public func history(
    _ id: String,
    after: Int = 0,
    streams: [LogStream] = []
  ) async throws -> [LogEvent] {
    var collected: [LogEvent] = []
    var cursor = after
    while true {
      let page = try await events(id, after: cursor, streams: streams)
      collected.append(contentsOf: page.items)
      guard page.meta?.hasMore == true, let next = page.meta?.nextCursor else { break }
      cursor = next
    }
    return collected
  }

  /// Live SSE tail of one conversation, reconnecting from the last id.
  public func stream(_ id: String, _ request: StreamRequest = StreamRequest())
    -> AsyncThrowingStream<StreamEvent, Error>
  {
    EventStreamLoop.stream(
      client: client, path: "/api/conversations/\(id)/stream", request: request)
  }

  /// Image bytes attached to a turn (position is zero-based).
  public func turnImage(_ id: String, turnID: String, position: Int) async throws -> Data {
    let (data, _) = try await client.raw(
      .get, "/api/conversations/\(id)/turns/\(turnID)/images/\(position)",
      options: .init(accept: "image/*")
    )
    return data
  }
}

/// The all-conversations stream (`/api/events/stream`): every unfinished
/// conversation, plus `conversations` change signals. On any change to a
/// conversation's turn_count/status, re-read history after the last seen id —
/// the stream only follows unfinished conversations and can leave gaps.
public struct EventsResource: Sendable {
  let client: APIClient

  public func stream(_ request: StreamRequest = StreamRequest()) -> AsyncThrowingStream<
    StreamEvent, Error
  > {
    EventStreamLoop.stream(client: client, path: "/api/events/stream", request: request)
  }
}
