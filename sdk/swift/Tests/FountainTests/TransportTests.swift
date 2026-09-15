import Foundation
import Testing

@testable import Fountain

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest, MockURLProtocol) -> Void)?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { Self.handler?(request, self) }
  override func stopLoading() {}
  func respond(
    status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"],
    data: Data = Data(), finish: Bool = true
  ) {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
    if finish { client?.urlProtocolDidFinishLoading(self) }
  }
  func send(_ text: String, finish: Bool = false) {
    client?.urlProtocol(self, didLoad: Data(text.utf8))
    if finish { client?.urlProtocolDidFinishLoading(self) }
  }
}

/// One session for every mocked test, not one per test: `MockURLProtocol.handler`
/// is global and the suite is serialized, so a session each would buy nothing.
/// The client copies this configuration rather than using the session, which is
/// how `MockURLProtocol` reaches the streams as well as the plain requests.
private let sharedMockSession: URLSession = {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: configuration)
}()

private func mockSession() -> URLSession { sharedMockSession }

private func json(_ value: JSONValue) -> Data { try! JSONEncoder().encode(value) }

@Suite(.serialized) struct TransportTests {
  @Test(arguments: [false, true])
  func launchPreservesEachPublicBoundary(legacy: Bool) async throws {
    let body: JSONObject =
      legacy
      ? ["agent_id": "11111111-1111-1111-1111-111111111111", "title": ""]
      : [
        "agent_id": .string("raw-agent-id"), "prompt": .string("hello"),
        "future_field": .object(["zero": .number(0), "empty": .array([])]),
        "vault_id": .null, "fresh": .bool(false), "title": .string(""),
      ]
    MockURLProtocol.handler = { request, protocolInstance in
      #expect(request.httpMethod == "POST")
      #expect(request.url?.path == "/api/conversations")
      // Deliberately stop at the create response: only the boundary is under test.
      let data: Data
      if let body = request.httpBody {
        data = body
      } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          bytes.append(contentsOf: buffer.prefix(count))
        }
        data = bytes
      } else {
        data = Data()
      }
      #expect((try? JSONDecoder().decode(JSONObject.self, from: data)) == body)
      protocolInstance.respond(status: 422, data: json(["error": "fixture_stop"] as JSONValue))
    }
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    let run =
      legacy
      ? fountain.run(
        "", agent: "11111111-1111-1111-1111-111111111111", title: "", images: [], fresh: false,
        timeout: 5, collectEvents: true)
      : try fountain.runRequest(body, timeout: 5, collectEvents: true)
    await #expect(throws: FountainError.self) { try await run.value() }
  }

  @Test(arguments: [false, true], [false, true])
  func runRequestFollowsNewChannelTurnOne(fresh: Bool, legacy: Bool) async throws {
    let router = ChannelRunRouter(resumed: false)
    MockURLProtocol.handler = router.handle
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    let run =
      legacy
      ? fountain.run(
        "hello", agent: "11111111-1111-1111-1111-111111111111", channelID: "chat", fresh: fresh,
        timeout: 1)
      : try fountain.runRequest(
        [
          "agent_id": "a1", "prompt": "hello", "channel_id": "chat", "fresh": .bool(fresh),
        ], timeout: 1)
    let result = try await run.value()
    #expect(result.turnNumber == 1)
    #expect(result.text == "answer 1")
    #expect(router.promptCount == 0)
  }

  @Test(arguments: [false, true])
  func runRequestDispatchesResumedPromptAndImagesOnce(legacy: Bool) async throws {
    let router = ChannelRunRouter(resumed: true)
    MockURLProtocol.handler = router.handle
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    let images: JSONValue = [["data": "aGVsbG8=", "media_type": "image/png"]]
    let run =
      legacy
      ? fountain.run(
        "next", agent: "11111111-1111-1111-1111-111111111111",
        images: [["data": "aGVsbG8=", "media_type": "image/png"]], channelID: "chat", timeout: 1,
        collectEvents: true)
      : try fountain.runRequest(
        [
          "agent_id": "a1", "prompt": "next", "channel_id": "chat", "images": images,
        ], timeout: 1, collectEvents: true)
    let result = try await run.value()
    #expect(result.conversationID == "c1")
    #expect(result.turnNumber == 2)
    #expect(result.text == "answer 2")
    #expect(router.promptCount == 1)
    #expect(router.promptBody == ["prompt": "next", "images": images])
  }

  @Test(arguments: [false, true])
  func runRequestSurfacesResumedPromptRejection(legacy: Bool) async throws {
    let router = ChannelRunRouter(resumed: true, rejectPrompt: true)
    MockURLProtocol.handler = router.handle
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    let run =
      legacy
      ? fountain.run(
        "next", agent: "11111111-1111-1111-1111-111111111111", channelID: "chat", timeout: 1)
      : try fountain.runRequest(
        [
          "agent_id": "a1", "prompt": "next", "channel_id": "chat",
        ], timeout: 1)
    do {
      _ = try await run.value()
      Issue.record("A rejected prompt must fail the run")
    } catch let error as FountainError {
      #expect(error.code == "conversation_busy")
    }
    #expect(router.promptCount == 1)
  }

  @Test func runRequestRejectsInvalidInputsBeforeHTTP() throws {
    MockURLProtocol.handler = { _, instance in
      Issue.record("Invalid run input reached HTTP")
      instance.respond(status: 500)
    }
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    for prompt in [JSONValue.null, .string(""), .string(" \n")] {
      #expect(throws: FountainError.self) {
        try fountain.runRequest(["agent_id": .string("a1"), "prompt": prompt])
      }
    }
    for queue in [JSONValue.bool(true), .number(0), .string("false")] {
      #expect(throws: FountainError.self) {
        try fountain.runRequest([
          "agent_id": .string("a1"), "prompt": .string("hello"), "queue": queue,
        ])
      }
    }
  }

  @Test func httpClientBuildsAuthenticatedRequestAndTypedError() async throws {
    MockURLProtocol.handler = { request, protocolInstance in
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
      #expect(
        request.value(forHTTPHeaderField: "User-Agent")
          == "fountain-sdk-swift/\(fountainSDKVersion)")
      #expect(request.url?.absoluteString == "https://api.example.test/api/audit?limit=5")
      protocolInstance.respond(
        status: 429, headers: ["retry-after": "1.5"],
        data: json(["error": "rate_limited"] as JSONValue))
    }
    let config = FountainConfiguration(
      baseURL: URL(string: "https://api.example.test")!, apiKey: "secret", appURL: nil)
    let client = FountainHTTPClient(configuration: config, session: mockSession())
    do {
      _ = try await client.request("GET", "/api/audit", query: ["limit": "5"])
      Issue.record("Expected a typed API error")
    } catch let error as FountainError {
      #expect(error.kind == .rateLimit)
      #expect(error.retryAfter == 1.5)
      #expect(error.retryable)
    }
  }

  @Test func providerDiscoverBuildsUnescapedDiscoverPath() async throws {
    MockURLProtocol.handler = { request, protocolInstance in
      #expect(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath
          == "/api/connection-providers/provider%20one/discover")
      protocolInstance.respond(data: json(["ok": true] as JSONValue))
    }
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    let result = try await fountain.connections.providers.discover("provider one")
    #expect(result["ok"]?.boolValue == true)
  }

  @Test func globalSSEUsesLastEventIDAndNoAfterOrWaitDefaults() async throws {
    MockURLProtocol.handler = { request, protocolInstance in
      #expect(request.url?.path == "/api/events/stream")
      #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == "41")
      #expect(request.url?.query?.contains("after=") != true)
      #expect(request.url?.query?.contains("wait=") != true)
      protocolInstance.respond(
        headers: ["Content-Type": "text/event-stream"],
        data: Data("id: 42\nevent: output\ndata: {\"kind\":\"output\"}\n\n".utf8)
      )
    }
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    var ids: [Int] = []
    for try await event in fountain.events(after: 41, maxRetries: 0) {
      ids.append(event["id"]?.intValue ?? 0)
      break
    }
    #expect(ids == [42])
  }

  private final class PermissionRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: MockURLProtocol?
    private(set) var answerPath: String?

    func handle(_ request: URLRequest, _ protocolInstance: MockURLProtocol) {
      switch (request.httpMethod, request.url!.path) {
      case ("GET", "/api/agents"):
        protocolInstance.respond(
          data: json(["data": [["id": "agent-1", "name": "reviewer"]]] as JSONValue))
      case ("POST", "/api/conversations"):
        protocolInstance.respond(
          data: json(["data": ["id": "conversation-1", "status": "running"]] as JSONValue))
      case ("GET", "/api/conversations/conversation-1/stream"):
        protocolInstance.respond(headers: ["Content-Type": "text/event-stream"], finish: false)
        protocolInstance.send(Self.started + Self.permission)
        lock.lock()
        stream = protocolInstance
        lock.unlock()
      case ("POST", let path) where path.contains("/requests/"):
        lock.lock()
        answerPath =
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath
        let stream = self.stream
        lock.unlock()
        protocolInstance.respond()
        stream?.send(Self.terminal, finish: true)
      case ("GET", "/api/conversations/conversation-1"):
        protocolInstance.respond(
          data: json(["data": ["id": "conversation-1", "status": "idle"]] as JSONValue))
      default:
        protocolInstance.respond(status: 404, data: json(["error": "not_found"] as JSONValue))
      }
    }

    private static let started =
      "id: 1\nevent: stage\ndata: {\"kind\":\"stage\",\"stage\":\"turn\",\"state\":\"started\",\"data\":{\"turn_number\":1,\"turn_id\":\"turn-1\"}}\n\n"
    private static let permission =
      "id: 2\nevent: output\ndata: {\"kind\":\"output\",\"stream\":\"acp\",\"turn_id\":\"turn-1\",\"blocks\":[{\"kind\":\"permission_request\",\"request_id\":\"req/1\",\"name\":\"shell\",\"options\":[{\"option_id\":\"allow\",\"kind\":\"allow_once\"}]}]}\n\n"
    private static let terminal =
      "id: 3\nevent: stage\ndata: {\"kind\":\"stage\",\"stage\":\"turn\",\"state\":\"done\",\"data\":{\"turn_number\":1,\"turn_id\":\"turn-1\"}}\n\n"
  }

  @Test func runCanAnswerBeforeCompletionAndReplaysInOrderToEverySubscriber() async throws {
    let router = PermissionRouter()
    MockURLProtocol.handler = { request, protocolInstance in
      router.handle(request, protocolInstance)
    }
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    let run = fountain.run("review", agent: "reviewer")
    var concurrentSubscriber: Task<[String], Error>?
    for try await event in run.events {
      if case .permission(let request, _) = event {
        concurrentSubscriber = Task { try await eventLabels(run.events) }
        try await run.answer(requestID: request.requestID, optionID: "allow")
      }
    }
    let result = try await run.value()
    #expect(result.state == .done)
    #expect(router.answerPath == "/api/conversations/conversation-1/requests/req%2F1")

    let first = try await eventLabels(run.events)
    let second = try await eventLabels(run.events)
    let concurrent = try await concurrentSubscriber?.value
    #expect(concurrent == first)
    #expect(first == second)
    #expect(first.first == "conversation")
    #expect(first.last == "turn-end")
    #expect(await run.cursor() == 3)
  }

  @Test func conversationAdvancesCursorAcrossFollowUps() async throws {
    let router = CursorRouter()
    MockURLProtocol.handler = { request, protocolInstance in
      router.handle(request, protocolInstance)
    }
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    let conversation = fountain.resume("conversation-1")
    _ = try await conversation.send("first").value()
    try await Task.sleep(nanoseconds: 10_000_000)
    _ = try await conversation.send("second").value()
    #expect(router.runCursors == [5, 10])
  }

  @Test func successfulEmptySSEConnectionsResetRetryBudget() async throws {
    // Counted by path, not by call, for the reason
    // `anEventStreamOpensNothingUntilItIsIterated` counts by cursor: a stream
    // an earlier test left retrying reaches this handler too, and an extra
    // connection it made would move the run that carries the event. Only this
    // test asks for this path.
    let path = "/api/events/retry-budget"
    let counter = LockedCounter()
    MockURLProtocol.handler = { request, protocolInstance in
      guard request.url?.path == path else {
        protocolInstance.respond(headers: ["Content-Type": "text/event-stream"])
        return
      }
      let count = counter.increment()
      let body = count == 7 ? "id: 7\nevent: output\ndata: {\"kind\":\"output\"}\n\n" : ""
      protocolInstance.respond(
        headers: ["Content-Type": "text/event-stream"], data: Data(body.utf8))
    }
    let config = FountainConfiguration(
      baseURL: URL(string: "https://api.example.test")!, apiKey: "secret", appURL: nil)
    let http = FountainHTTPClient(configuration: config, session: mockSession())
    var ids: [Int] = []
    for try await event in streamPath(http: http, path: path, maxRetries: 5, retryDelay: 0) {
      ids.append(event["id"]?.intValue ?? 0)
      break
    }
    #expect(counter.value == 7)
    #expect(ids == [7])
  }

  @Test func streamRequestsUseATimeoutLinuxCanConvertToAnInteger() throws {
    // FoundationNetworking derives an integer timeout from this value, and
    // `.greatestFiniteMagnitude` is out of Int range, so converting it traps.
    let config = FountainConfiguration(
      baseURL: URL(string: "https://api.example.test")!, apiKey: "secret", appURL: nil)
    // No session: this only builds a request, and a client that neither
    // requests nor streams opens no session at all.
    let http = FountainHTTPClient(configuration: config)
    let request = try http.streamRequest("/api/events/stream", query: [:], lastEventID: 0)
    #expect(request.timeoutInterval.isFinite)
    #expect(request.timeoutInterval <= TimeInterval(Int32.max))
    #expect(Int(exactly: request.timeoutInterval.rounded()) != nil)
    // Still far longer than the gap a heartbeating feed leaves between packets.
    #expect(request.timeoutInterval > 3600)
  }

  @Test func anEventStreamOpensNothingUntilItIsIterated() async throws {
    // Counted by cursor, not by call: a stream an earlier test left retrying
    // reaches this handler too, and only this one asks from 987_654.
    let cursor = 987_654
    let counter = LockedCounter()
    MockURLProtocol.handler = { request, protocolInstance in
      if request.value(forHTTPHeaderField: "Last-Event-ID") == String(cursor) {
        _ = counter.increment()
      }
      protocolInstance.respond(
        headers: ["Content-Type": "text/event-stream"],
        data: Data("id: \(cursor + 1)\nevent: output\ndata: {\"kind\":\"output\"}\n\n".utf8))
    }
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    let stream = fountain.events(after: cursor, maxRetries: 0)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(counter.value == 0)
    for try await _ in stream { break }
    #expect(counter.value == 1)
  }

  @Test func configTokenFallbackAndParentHeader() async throws {
    let config = try FountainConfig.resolve(
      environment: [
        "FOUNTAIN_TOKEN": "fallback-token",
        "FOUNTAIN_BASE_URL": "https://api.example.test",
        "FOUNTAIN_CONVERSATION_ID": "parent-1",
      ], credentialsText: "")
    #expect(config.apiKey == "fallback-token")
    MockURLProtocol.handler = { request, protocolInstance in
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fallback-token")
      #expect(
        request.value(forHTTPHeaderField: "X-Fountain-Parent-Conversation-Id") == "parent-1")
      protocolInstance.respond()
    }
    _ = try await FountainHTTPClient(configuration: config, session: mockSession()).request(
      "GET", "/api/ping")
  }

  @Test func sandboxReadRoutesMatchTheAPI() async throws {
    let recorder = RequestRecorder()
    MockURLProtocol.handler = { request, protocolInstance in
      recorder.append(request)
      protocolInstance.respond(data: json(["data": [:]] as JSONValue))
    }
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    _ = try await fountain.sandboxFiles("sandbox-1", path: "src")
    _ = try await fountain.sandboxFile("sandbox-1", path: "src/main.swift", maxBytes: 4096)
    _ = try await fountain.sandboxDiff(
      "sandbox-1", path: "repo", staged: true, ref: "main", maxBytes: 8192)
    #expect(
      recorder.paths == [
        "/api/sandboxes/sandbox-1/files?path=src",
        "/api/sandboxes/sandbox-1/file?max_bytes=4096&path=src/main.swift",
        "/api/sandboxes/sandbox-1/diff?max_bytes=8192&path=repo&ref=main&staged=true",
      ])
  }

  @Test func resourceCacheInvalidationAndSecretEncoding() async throws {
    let router = ResourceRouter()
    MockURLProtocol.handler = { request, protocolInstance in
      router.handle(request, protocolInstance)
    }
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    _ = try await fountain.agents.get("reviewer")
    _ = try await fountain.agents.get("reviewer")
    _ = try await fountain.agents.create(["name": "second"])
    _ = try await fountain.agents.get("reviewer")
    try await fountain.environments.secrets.delete("development", key: "A/B")
    #expect(router.agentListCount == 2)
    #expect(router.secretDeletePath == "/api/environments/environment-1/secrets/A%2FB")
  }

  @Test func teamScheduleAndMessageRoutes() async throws {
    let router = TeamRouter()
    MockURLProtocol.handler = { request, protocolInstance in
      router.handle(request, protocolInstance)
    }
    let fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    _ = try await fountain.team.schedules.create("reviewer", input: ["cron": "0 9 * * *"])
    _ = try await fountain.team.schedules.run("reviewer", id: "schedule-1")
    let result = try await fountain.team.message("reviewer", "status").value()
    #expect(result.state == .done)
    #expect(router.paths.contains("POST /api/team/agent-1/schedules"))
    #expect(router.paths.contains("POST /api/team/agent-1/schedules/schedule-1/run"))
    #expect(router.paths.contains("POST /api/team/agent-1/messages"))
  }

  @Test func failedTurnReturnsResultAndTimeoutCarriesPartialText() async throws {
    let failed = RunOutcomeRouter(mode: .failed)
    MockURLProtocol.handler = { request, protocolInstance in
      failed.handle(request, protocolInstance)
    }
    var fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    #expect(try await fountain.run("fail", agent: "reviewer").value().state == .failed)

    let hanging = RunOutcomeRouter(mode: .hanging)
    MockURLProtocol.handler = { request, protocolInstance in
      hanging.handle(request, protocolInstance)
    }
    fountain = try Fountain(
      apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
    do {
      _ = try await fountain.run("wait", agent: "reviewer", timeout: 0.02).value()
      Issue.record("Expected SDK timeout")
    } catch let error as FountainError {
      #expect(error.kind == .timeout)
      #expect(error.conversationID == "conversation-1")
      #expect(error.partialText == "working")
    }
  }

  @Test func runPreservesExplicitSandboxAPIAccessAndOmitsTheDefault() async throws {
    for access: String? in [nil, "none", "owner"] {
      let router = RunOutcomeRouter(mode: .failed)
      MockURLProtocol.handler = { request, protocolInstance in
        if request.httpMethod == "POST", request.url?.path == "/api/conversations" {
          var data = request.httpBody ?? Data()
          if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
              let count = stream.read(&buffer, maxLength: buffer.count)
              if count <= 0 { break }
              data.append(buffer, count: count)
            }
          }
          let body = try? JSONDecoder().decode(JSONObject.self, from: data)
          #expect(body != nil)
          #expect(body?["sandbox_api_access"]?.stringValue == access)
          if access == nil { #expect(body?["sandbox_api_access"] == nil) }
        }
        router.handle(request, protocolInstance)
      }
      let fountain = try Fountain(
        apiKey: "secret", baseURL: "https://api.example.test", session: mockSession())
      _ = try await fountain.run("fail", agent: "reviewer", sandboxAPIAccess: access).value()
    }
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }
}

private final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [URLRequest] = []
  func append(_ request: URLRequest) {
    lock.lock()
    requests.append(request)
    lock.unlock()
  }
  var paths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return requests.compactMap { request in
      guard let url = request.url else { return nil }
      return url.path + (url.query.map { "?\($0)" } ?? "")
    }
  }
}

private final class ResourceRouter: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var agentListCount = 0
  private(set) var secretDeletePath: String?
  func handle(_ request: URLRequest, _ protocolInstance: MockURLProtocol) {
    let path = request.url!.path
    if request.httpMethod == "GET", path == "/api/agents" {
      lock.lock()
      agentListCount += 1
      lock.unlock()
      protocolInstance.respond(
        data: json(["data": [["id": "agent-1", "name": "reviewer"]]] as JSONValue))
    } else if request.httpMethod == "GET", path == "/api/agents/agent-1" {
      protocolInstance.respond(
        data: json(["data": ["id": "agent-1", "name": "reviewer"]] as JSONValue))
    } else if request.httpMethod == "POST", path == "/api/agents" {
      protocolInstance.respond(
        data: json(["data": ["id": "agent-2", "name": "second"]] as JSONValue))
    } else if request.httpMethod == "GET", path == "/api/environments" {
      protocolInstance.respond(
        data: json(["data": [["id": "environment-1", "name": "development"]]] as JSONValue))
    } else if request.httpMethod == "DELETE", path.hasPrefix("/api/environments/") {
      lock.lock()
      secretDeletePath =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath
      lock.unlock()
      protocolInstance.respond()
    } else {
      protocolInstance.respond(status: 404)
    }
  }
}

private final class TeamRouter: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var paths: [String] = []
  func handle(_ request: URLRequest, _ protocolInstance: MockURLProtocol) {
    let path = request.url!.path
    lock.lock()
    paths.append("\(request.httpMethod ?? "") \(path)")
    lock.unlock()
    switch (request.httpMethod, path) {
    case ("GET", "/api/agents"):
      protocolInstance.respond(
        data: json(["data": [["id": "agent-1", "name": "reviewer"]]] as JSONValue))
    case ("POST", "/api/team/agent-1/schedules"):
      protocolInstance.respond(data: json(["data": ["id": "schedule-1"]] as JSONValue))
    case ("POST", "/api/team/agent-1/schedules/schedule-1/run"):
      protocolInstance.respond(data: json(["ok": true] as JSONValue))
    case ("GET", "/api/team/agent-1"):
      protocolInstance.respond(data: json(["data": ["id": "agent-1"]] as JSONValue))
    case ("POST", "/api/team/agent-1/messages"):
      protocolInstance.respond(data: json(["conversation_id": "conversation-1"] as JSONValue))
    case ("GET", "/api/conversations/conversation-1"):
      protocolInstance.respond(
        data: json(["data": ["id": "conversation-1", "status": "idle"]] as JSONValue))
    case ("GET", "/api/conversations/conversation-1/stream"):
      let body =
        "id: 1\nevent: stage\ndata: {\"kind\":\"stage\",\"stage\":\"turn\",\"state\":\"started\",\"data\":{\"turn_number\":1,\"turn_id\":\"turn-1\"}}\n\nid: 2\nevent: stage\ndata: {\"kind\":\"stage\",\"stage\":\"turn\",\"state\":\"done\",\"data\":{\"turn_number\":1,\"turn_id\":\"turn-1\"}}\n\n"
      protocolInstance.respond(
        headers: ["Content-Type": "text/event-stream"], data: Data(body.utf8))
    default: protocolInstance.respond(status: 404)
    }
  }
}

private final class RunOutcomeRouter: @unchecked Sendable {
  enum Mode { case failed, hanging }
  let mode: Mode
  init(mode: Mode) { self.mode = mode }
  func handle(_ request: URLRequest, _ protocolInstance: MockURLProtocol) {
    switch (request.httpMethod, request.url!.path) {
    case ("GET", "/api/agents"):
      protocolInstance.respond(
        data: json(["data": [["id": "agent-1", "name": "reviewer"]]] as JSONValue))
    case ("POST", "/api/conversations"):
      protocolInstance.respond(
        data: json(["data": ["id": "conversation-1", "status": "running"]] as JSONValue))
    case ("GET", "/api/conversations/conversation-1/stream"):
      let start =
        "id: 1\nevent: stage\ndata: {\"kind\":\"stage\",\"stage\":\"turn\",\"state\":\"started\",\"data\":{\"turn_number\":1,\"turn_id\":\"turn-1\"}}\n\nid: 2\nevent: output\ndata: {\"kind\":\"output\",\"stream\":\"acp\",\"turn_id\":\"turn-1\",\"blocks\":[{\"kind\":\"text\",\"body\":\"working\"}]}\n\n"
      if mode == .failed {
        let end =
          "id: 3\nevent: stage\ndata: {\"kind\":\"stage\",\"stage\":\"turn\",\"state\":\"failed\",\"data\":{\"turn_number\":1,\"turn_id\":\"turn-1\",\"reason\":\"boom\"}}\n\n"
        protocolInstance.respond(
          headers: ["Content-Type": "text/event-stream"], data: Data((start + end).utf8))
      } else {
        protocolInstance.respond(headers: ["Content-Type": "text/event-stream"], finish: false)
        protocolInstance.send(start)
      }
    case ("GET", "/api/conversations/conversation-1"):
      protocolInstance.respond(
        data: json(["data": ["id": "conversation-1", "status": "idle"]] as JSONValue))
    default: protocolInstance.respond(status: 404)
    }
  }
}

private final class CursorRouter: @unchecked Sendable {
  private let lock = NSLock()
  private var promptCount = 0
  private(set) var runCursors: [Int] = []
  func handle(_ request: URLRequest, _ protocolInstance: MockURLProtocol) {
    let path = request.url!.path
    if path == "/api/conversations/conversation-1/stream" {
      let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
      let isDiscovery =
        components?.queryItems?.contains(where: { $0.name == "streams" && $0.value == "stage" })
        == true
      if isDiscovery {
        protocolInstance.respond(
          headers: ["Content-Type": "text/event-stream"],
          data: Data("id: 5\nevent: stage\ndata: {\"kind\":\"stage\"}\n\n".utf8))
        return
      }
      let cursor = Int(request.value(forHTTPHeaderField: "Last-Event-ID") ?? "0") ?? 0
      lock.lock()
      runCursors.append(cursor)
      let turn = promptCount
      lock.unlock()
      let startID = turn == 1 ? 6 : 11
      let endID = turn == 1 ? 10 : 12
      let body =
        "id: \(startID)\nevent: stage\ndata: {\"kind\":\"stage\",\"stage\":\"turn\",\"state\":\"started\",\"data\":{\"turn_number\":\(turn),\"turn_id\":\"turn-\(turn)\"}}\n\nid: \(endID)\nevent: stage\ndata: {\"kind\":\"stage\",\"stage\":\"turn\",\"state\":\"done\",\"data\":{\"turn_number\":\(turn),\"turn_id\":\"turn-\(turn)\"}}\n\n"
      protocolInstance.respond(
        headers: ["Content-Type": "text/event-stream"], data: Data(body.utf8))
    } else if path.hasSuffix("/turns") {
      lock.lock()
      let count = promptCount
      lock.unlock()
      let rows: [JSONValue] = count > 0 ? (1...count).map { ["turn_number": .integer($0)] } : []
      let turns: JSONValue = .array(rows)
      protocolInstance.respond(data: json(["data": turns] as JSONValue))
    } else if path.hasSuffix("/prompts") {
      lock.lock()
      promptCount += 1
      lock.unlock()
      protocolInstance.respond()
    } else if path == "/api/conversations/conversation-1" {
      protocolInstance.respond(
        data: json(["data": ["id": "conversation-1", "status": "idle"]] as JSONValue))
    } else {
      protocolInstance.respond(status: 404)
    }
  }
}

private func eventLabels(_ stream: AsyncThrowingStream<RunEvent, Error>) async throws -> [String] {
  var output: [String] = []
  for try await event in stream {
    switch event {
    case .conversation: output.append("conversation")
    case .event: output.append("event")
    case .turnStart: output.append("turn-start")
    case .permission: output.append("permission")
    case .turnEnd: output.append("turn-end")
    default: output.append("other")
    }
  }
  return output
}

/// Models the server's channel contract: creation starts turn 1; resume does
/// not start anything until a separate prompt request arrives.
private final class ChannelRunRouter: @unchecked Sendable {
  private let lock = NSLock()
  private let resumed: Bool
  private let rejectPrompt: Bool
  private var currentTurn = 1
  private var capturedHistory = false
  private var capturedCursor = false
  private(set) var promptCount = 0
  private(set) var promptBody: JSONObject?

  init(resumed: Bool, rejectPrompt: Bool = false) {
    self.resumed = resumed
    self.rejectPrompt = rejectPrompt
  }

  func handle(_ request: URLRequest, _ instance: MockURLProtocol) {
    lock.lock()
    defer { lock.unlock() }
    switch (request.httpMethod, request.url?.path) {
    case ("POST", "/api/conversations"):
      instance.respond(
        status: resumed ? 200 : 201,
        data: json(
          [
            "data": ["id": "c1", "status": resumed ? "idle" : "running"],
            "meta": ["resumed": .bool(resumed)],
          ] as JSONValue))
    case ("GET", "/api/conversations/c1/turns"):
      capturedHistory = true
      instance.respond(data: json(["data": [["turn_number": .integer(currentTurn)]]] as JSONValue))
    case ("POST", "/api/conversations/c1/prompts"):
      #expect(capturedHistory && capturedCursor)
      promptCount += 1
      var data = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          data.append(contentsOf: buffer.prefix(count))
        }
      }
      promptBody = try? JSONDecoder().decode(JSONObject.self, from: data)
      if rejectPrompt {
        instance.respond(status: 400, data: json(["error": "conversation_busy"] as JSONValue))
      } else {
        currentTurn += 1
        instance.respond(data: json(["status": "queued"] as JSONValue))
      }
    case ("GET", "/api/conversations/c1/stream"):
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
      let discovery = query?.contains(where: { $0.name == "wait" && $0.value == "false" }) == true
      if discovery {
        capturedCursor = true
      } else if resumed {
        #expect(promptCount == 1 && !rejectPrompt)
        #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == "3")
      }
      let start = (currentTurn - 1) * 3 + 1
      let events = """
        id: \(start)
        event: stage
        data: {"id":\(start),"kind":"stage","stage":"turn","state":"started","data":"{\\"turn_number\\":\(currentTurn),\\"turn_id\\":\\"t\(currentTurn)\\"}"}

        id: \(start + 1)
        event: output
        data: {"id":\(start + 1),"kind":"output","stream":"acp","turn_id":"t\(currentTurn)","blocks":[{"kind":"text","body":"answer \(currentTurn)"}]}

        id: \(start + 2)
        event: stage
        data: {"id":\(start + 2),"kind":"stage","stage":"turn","state":"done","data":"{\\"turn_number\\":\(currentTurn),\\"turn_id\\":\\"t\(currentTurn)\\"}"}


        """
      instance.respond(
        headers: ["Content-Type": "text/event-stream"], data: Data(events.utf8), finish: discovery)
    case ("GET", "/api/conversations/c1"):
      instance.respond(data: json(["data": ["id": "c1", "status": "idle"]] as JSONValue))
    default:
      Issue.record("Unexpected channel request: \(request)")
      instance.respond(status: 500)
    }
  }
}
