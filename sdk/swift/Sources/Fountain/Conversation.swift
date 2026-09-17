import Foundation

public struct EventPage: Equatable, Sendable {
  public let events: [JSONObject]
  public let nextCursor: Int
  public let hasMore: Bool
}

public final class Conversation: @unchecked Sendable {
  public let id: String
  public var url: URL { http.configuration.conversationURL(id) }
  private let http: FountainHTTPClient
  private let cursorState: CursorState

  init(http: FountainHTTPClient, id: String, cursor: Int = 0) {
    self.http = http
    self.id = id
    self.cursorState = CursorState(cursor)
  }

  public func get() async throws -> JSONObject {
    try await http.data("GET", "/api/conversations/\(id)")
  }
  public func status() async throws -> String? { try await get()["status"]?.stringValue }
  public func turns() async throws -> [JSONObject] {
    try await http.list("/api/conversations/\(id)/turns")
  }

  /// Send the next turn.
  ///
  /// `clientRequestID` is the caller's own name for this submission. It is
  /// carried to the turn the prompt opens and onto that turn's `started`
  /// event (#1406), so a caller reads back which turn was its own instead of
  /// guessing from turn order. It is not an idempotency key: the same value
  /// sent twice opens two turns.
  public func send(
    _ prompt: String,
    images: [JSONObject]? = nil,
    clientRequestID: String? = nil,
    timeout: TimeInterval? = nil,
    collectEvents: Bool = false
  ) -> Run {
    let body: JSONObject = {
      var value: JSONObject = ["prompt": .string(prompt)]
      if let images, !images.isEmpty { value["images"] = .array(images.map(JSONValue.object)) }
      if let clientRequestID { value["client_request_id"] = .string(clientRequestID) }
      return value
    }()
    let run = Run(
      http: http,
      plan: RunPlan { [http, id, cursorState] in
        let after = try await Self.discoverCursor(http: http, id: id, state: cursorState)
        let turns = try await http.list("/api/conversations/\(id)/turns")
        let number = (turns.compactMap { $0["turn_number"]?.intValue }.max() ?? 0) + 1
        _ = try await http.request("POST", "/api/conversations/\(id)/prompts", body: .object(body))
        let conversation = try await http.data("GET", "/api/conversations/\(id)")
        return (conversation, number, after)
      }, timeout: timeout, collectEvents: collectEvents)
    Task {
      _ = try? await run.value()
      await cursorState.advance(await run.cursor())
    }
    return run
  }

  public func answer(requestID: String, optionID: String) async throws {
    _ = try await http.request(
      "POST", "/api/conversations/\(id)/requests/\(requestID.pathEncoded)",
      body: .object(["option_id": .string(optionID)]))
  }
  public func markRead() async throws {
    _ = try await http.request("POST", "/api/conversations/\(id)/read")
  }

  public func history(streams: [String]? = nil, after: Int = 0, limit: Int = 1000) async throws
    -> [JSONObject]
  {
    var output: [JSONObject] = []
    var cursor = after
    while true {
      let page = try await http.request(
        "GET", "/api/conversations/\(id)/events",
        query: [
          "after": String(cursor), "limit": String(limit), "blocks": "true",
          "streams": streams?.joined(separator: ","),
        ])
      let events = page["data"]?.arrayValue?.compactMap(\.objectValue) ?? []
      output.append(contentsOf: events)
      guard page["meta"]?["has_more"]?.boolValue == true,
        let next = page["meta"]?["next_cursor"]?.intValue
      else { break }
      cursor = next
    }
    if let last = output.last?["id"]?.intValue { await cursorState.advance(last) }
    return output
  }

  public func tree() async throws -> JSONObject {
    try await http.data("GET", "/api/conversations/\(id)/tree")
  }

  /// Reapply this conversation's agent, environment and vault in place. The
  /// machine, the transcript and the files on disk all stay. Omit a value to
  /// keep it; pass `.null` for the environment or the vault to clear it.
  public func reapply(
    agentID: String? = nil,
    environmentID: JSONValue? = nil,
    vaultID: JSONValue? = nil
  ) async throws -> JSONObject {
    var body: JSONObject = [:]
    if let agentID { body["agent_id"] = .string(agentID) }
    if let environmentID { body["environment_id"] = environmentID }
    if let vaultID { body["vault_id"] = vaultID }
    return try await http.data("POST", "/api/conversations/\(id)/reapply", body: body)
  }

  public func interrupt() async throws {
    _ = try await http.request("POST", "/api/conversations/\(id)/interrupt")
  }
  public func terminate() async throws {
    _ = try await http.request("POST", "/api/conversations/\(id)/terminate")
  }
  public func delete() async throws {
    _ = try await http.request("DELETE", "/api/conversations/\(id)")
  }

  public func events(after: Int = 0, streams: [String]? = nil, wait: Bool = true)
    -> AsyncThrowingStream<JSONObject, Error>
  {
    streamEvents(
      http: http, conversationID: id, after: after, streams: streams?.joined(separator: ","),
      wait: wait)
  }

  public func eventPage(after: Int = 0, limit: Int = 1000) async throws -> EventPage {
    let output = try await http.request(
      "GET", "/api/conversations/\(id)/events",
      query: [
        "after": String(after), "limit": String(limit), "blocks": "true",
      ])
    return EventPage(
      events: output["data"]?.arrayValue?.compactMap(\.objectValue) ?? [],
      nextCursor: output["meta"]?["next_cursor"]?.intValue ?? after,
      hasMore: output["meta"]?["has_more"]?.boolValue ?? false
    )
  }

  public func lastTurnNumber() async throws -> Int {
    try await turns().compactMap { $0["turn_number"]?.intValue }.max() ?? 0
  }

  public func cursor() async -> Int {
    (try? await Self.discoverCursor(http: http, id: id, state: cursorState)) ?? 0
  }

  private static func discoverCursor(http: FountainHTTPClient, id: String, state: CursorState)
    async throws -> Int
  {
    let current = await state.value
    if current > 0 { return current }
    var last = 0
    do {
      for try await event in streamEvents(
        http: http, conversationID: id, streams: "stage", wait: false, maxRetries: 0)
      {
        if let eventID = event["id"]?.intValue { last = max(last, eventID) }
      }
    } catch { return 0 }
    await state.advance(last)
    return last
  }
}

private actor CursorState {
  var value: Int
  init(_ value: Int) { self.value = value }
  func advance(_ cursor: Int) { value = max(value, cursor) }
}
