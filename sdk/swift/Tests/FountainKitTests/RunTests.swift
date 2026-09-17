import Foundation
import Testing

@testable import FountainKit

/// The behaviour the cross-language conformance scenarios don't describe:
/// how `Run` shares one followed turn between several readers.
@Suite struct RunTests {
  private static let stream = """
    id: 1
    event: stage
    data: {"id":1,"kind":"stage","stage":"turn","state":"started","stream":"stage","data":"{\\"turn_number\\": 1, \\"turn_id\\": \\"t1\\"}"}

    id: 2
    event: output
    data: {"id":2,"kind":"output","stream":"acp","turn_id":"t1","blocks":[{"kind":"tool_use","name":"grep"}]}

    id: 3
    event: output
    data: {"id":3,"kind":"output","stream":"acp","turn_id":"t1","blocks":[{"kind":"text","body":"Found it."}]}

    id: 4
    event: stage
    data: {"id":4,"kind":"stage","stage":"turn","state":"done","stream":"stage","data":"{\\"turn_number\\": 1, \\"turn_id\\": \\"t1\\", \\"stop_reason\\": \\"end_turn\\"}"}


    """

  private func startedRun(appURL: URL? = nil) async throws -> Run {
    let transport = FakeTransport([
      .init(
        status: 201, json: #"{"data": {"id": "c1", "status": "running", "runtime": "claude"}}"#),
      .init(json: Self.stream),
      .init(json: #"{"data": {"id": "c1", "status": "idle", "runtime": "claude"}}"#),
    ])
    return try await FountainClient(
      config: FountainConfig(
        baseURL: URL(string: "https://fountain.test")!, apiKey: "ftn_live_test", appURL: appURL),
      transport: transport
    ).run("hello", agent: "a1")
  }

  @Test func runRequestForwardsTheGeneratedBodyAndFollowsTheTurn() async throws {
    let transport = FakeTransport([
      .init(status: 201, json: #"{"data":{"id":"c1","status":"running","runtime":"claude"}}"#),
      .init(json: Self.stream),
      .init(json: #"{"data":{"id":"c1","status":"idle","runtime":"claude"}}"#),
    ])
    var request = ConversationCreateRequest(agentID: "a1", prompt: "hello", fresh: false)
    request.labels = ["origin": "test"]
    request.inferenceCredentialID = "credential"
    request.setNull(.vaultID)
    let expected = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
    let run = try await FountainClient.fake(transport).runRequest(request, timeout: 5)
    request.labels = ["origin": "changed after launch"]
    #expect(try await run.value().text == "Found it.")
    let sent = try JSONDecoder().decode(
      JSONValue.self, from: #require(transport.requests.first?.httpBody))
    #expect(sent == expected)
    #expect(sent["timeout"] == nil)
    #expect(transport.requests.first?.url?.path == "/api/conversations")
  }

  @Test func legacyEmptyValuesReachServerValidation() async throws {
    let transport = FakeTransport(json: #"{"error":"unprocessable_entity"}"#, status: 422)
    do {
      _ = try await FountainClient.fake(transport).run(
        "", agent: "a1", title: "", images: [], fresh: false, timeout: 1)
      Issue.record("Expected server validation failure")
    } catch let error as FountainError {
      #expect(error.status == 422)
    }
    #expect(transport.requests.count == 1)
    let body = try JSONDecoder().decode(
      JSONValue.self, from: #require(transport.requests.first?.httpBody))
    #expect(
      body
        == .object([
          "agent_id": .string("a1"), "prompt": .string(""), "title": .string(""),
          "images": .array([]), "fresh": .bool(false),
        ]))
  }

  @Test(arguments: [false, true], [false, true])
  func runRequestFollowsNewChannelTurnOne(fresh: Bool, legacy: Bool) async throws {
    let transport = FakeTransport([
      .init(
        status: 201,
        json:
          #"{"data":{"id":"c1","status":"running","runtime":"claude"},"meta":{"resumed":false}}"#),
      .init(json: Self.stream),
      .init(json: #"{"data":{"id":"c1","status":"idle","runtime":"claude"}}"#),
    ])
    let request = ConversationCreateRequest(
      agentID: "a1", prompt: "hello", channelID: "chat", fresh: fresh)
    let client = FountainClient.fake(transport)
    let run =
      legacy
      ? try await client.run(
        request.prompt!, agent: "a1", images: request.images, channelID: "chat",
        fresh: request.fresh, timeout: 1)
      : try await client.runRequest(request, timeout: 1)
    let result = try await run.value()
    #expect(result.turnNumber == 1)
    #expect(result.text == "Found it.")
    #expect(!transport.requests.contains { $0.url?.path.hasSuffix("/prompts") == true })
  }

  @Test(arguments: [false, true])
  func runRequestDispatchesResumedPromptAndImagesOnce(legacy: Bool) async throws {
    var nextStream = Self.stream
      .replacingOccurrences(of: "t1", with: "t2")
      .replacingOccurrences(of: "turn_number\\\": 1", with: "turn_number\\\": 2")
    for id in 1...4 {
      nextStream =
        nextStream
        .replacingOccurrences(of: "id: \(id)\n", with: "id: \(id + 4)\n")
        .replacingOccurrences(of: "\"id\":\(id),", with: "\"id\":\(id + 4),")
    }
    let transport = FakeTransport([
      .init(
        json: #"{"data":{"id":"c1","status":"idle","runtime":"claude"},"meta":{"resumed":true}}"#),
      .init(json: "id: 4\nevent: stage\ndata: {\"id\":4,\"kind\":\"stage\"}\n\n"),
      .init(json: #"{"data":[{"id":"t1","prompt":"old","turn_number":1,"status":"completed"}]}"#),
      .init(json: #"{"status":"queued"}"#),
      .init(json: #"{"data":{"id":"c1","status":"running","runtime":"claude"}}"#),
      .init(json: nextStream),
      .init(json: #"{"data":{"id":"c1","status":"idle","runtime":"claude"}}"#),
    ])
    let request = ConversationCreateRequest(
      agentID: "a1", prompt: "next",
      images: [ImageInput(data: "aGVsbG8=", mediaType: "image/png")], channelID: "chat")
    let client = FountainClient.fake(transport)
    let run =
      legacy
      ? try await client.run(
        request.prompt!, agent: "a1", images: request.images, channelID: "chat",
        fresh: request.fresh, timeout: 1)
      : try await client.runRequest(request, timeout: 1)
    let result = try await run.value()
    #expect(result.turnNumber == 2)
    #expect(result.text == "Found it.")
    #expect(
      transport.requests.map { $0.url!.path } == [
        "/api/conversations", "/api/conversations/c1/stream", "/api/conversations/c1/turns",
        "/api/conversations/c1/prompts", "/api/conversations/c1",
        "/api/conversations/c1/stream", "/api/conversations/c1",
      ])
    let body = try JSONDecoder().decode(
      JSONValue.self, from: #require(transport.requests[3].httpBody))
    #expect(
      body
        == .object([
          "prompt": .string("next"),
          "images": .array([
            .object(["data": .string("aGVsbG8="), "media_type": .string("image/png")])
          ]),
        ]))
    #expect(transport.requests[5].value(forHTTPHeaderField: "Last-Event-ID") == "4")
  }

  // #1406: a caller names its submission and reads the name back off the turn,
  // instead of guessing which turn is its own from turn order. On a channel
  // resume the request that opens the turn is the second one, so a typed field
  // on `ConversationCreateRequest` is dropped unless the resume branch repeats
  // it, and nothing else would notice.
  @Test(arguments: [false, true])
  func resumedPromptCarriesClientRequestID(legacy: Bool) async throws {
    let transport = FakeTransport([
      .init(
        json: #"{"data":{"id":"c1","status":"idle","runtime":"claude"},"meta":{"resumed":true}}"#),
      .init(json: ""),
      .init(json: #"{"data":[]}"#),
      .init(status: 400, json: #"{"error":"conversation_busy"}"#),
    ])
    let request = ConversationCreateRequest(
      agentID: "a1", prompt: "next", channelID: "chat",
      clientRequestID: "salon-execution-44")
    let client = FountainClient.fake(transport)
    // The prompt is refused, which is the shortest way to the one request
    // this test is about without scripting a whole second turn.
    _ =
      try? await
      (legacy
      ? client.run(
        "next", agent: "a1", clientRequestID: "salon-execution-44", channelID: "chat", timeout: 1)
      : client.runRequest(request, timeout: 1))

    let create = try JSONDecoder().decode(
      JSONValue.self, from: #require(transport.requests.first?.httpBody))
    #expect(create["client_request_id"] == .string("salon-execution-44"))

    let prompt = try #require(transport.requests.last)
    #expect(prompt.url?.path == "/api/conversations/c1/prompts")
    let body = try JSONDecoder().decode(JSONValue.self, from: #require(prompt.httpBody))
    #expect(
      body
        == .object([
          "prompt": .string("next"),
          "client_request_id": .string("salon-execution-44"),
        ]))
  }

  // A caller that names nothing must put no key on the wire: an explicit null
  // would be a different request from the one every older caller sends.
  @Test
  func promptWithoutAClientRequestIDSendsNoKey() async throws {
    let transport = FakeTransport([.init(json: #"{"status":"queued"}"#)])
    let client = FountainClient.fake(transport)
    try await client.conversations.prompt("c1", "next")
    let body = try JSONDecoder().decode(
      JSONValue.self, from: #require(transport.lastRequest?.httpBody))
    #expect(body == .object(["prompt": .string("next")]))
  }

  @Test
  func conversationsPromptCarriesClientRequestID() async throws {
    let transport = FakeTransport([.init(json: #"{"status":"queued"}"#)])
    let client = FountainClient.fake(transport)
    try await client.conversations.prompt(
      "c1", "next", clientRequestID: "salon-execution-43")
    let body = try JSONDecoder().decode(
      JSONValue.self, from: #require(transport.lastRequest?.httpBody))
    #expect(
      body
        == .object([
          "prompt": .string("next"),
          "client_request_id": .string("salon-execution-43"),
        ]))
  }

  @Test(arguments: [false, true])
  func runRequestSurfacesResumedPromptRejection(legacy: Bool) async throws {
    let transport = FakeTransport([
      .init(
        json: #"{"data":{"id":"c1","status":"idle","runtime":"claude"},"meta":{"resumed":true}}"#),
      .init(json: ""),
      .init(json: #"{"data":[]}"#),
      .init(status: 400, json: #"{"error":"conversation_busy"}"#),
    ])
    let request = ConversationCreateRequest(agentID: "a1", prompt: "next", channelID: "chat")
    do {
      let client = FountainClient.fake(transport)
      _ =
        legacy
        ? try await client.run("next", agent: "a1", channelID: "chat", timeout: 1)
        : try await client.runRequest(request, timeout: 1)
      Issue.record("A rejected prompt must fail the run")
    } catch let error as FountainError {
      guard case .conversationBusy = error else {
        Issue.record("Unexpected prompt error: \(error)")
        return
      }
    }
    #expect(transport.requests.last?.url?.path == "/api/conversations/c1/prompts")
    #expect(transport.requests.count == 4)
  }

  @Test(arguments: [false, true])
  func runTranscriptLinksUseTheAppOrDashboard(configured: Bool) async throws {
    let appURL = configured ? URL(string: "https://talk.fountain.test/base/")! : nil
    let expected =
      configured
      ? "https://talk.fountain.test/base/#/c/c1" : "https://fountain.test/dashboard"
    let run = try await startedRun(appURL: appURL)
    let result = try await run.value()

    #expect(run.url.absoluteString == expected)
    #expect(result.url.absoluteString == expected)
    var conversationURLs: [String] = []
    for try await event in run.events {
      if case .conversation(_, let url) = event {
        conversationURLs.append(url.absoluteString)
      }
    }
    #expect(conversationURLs == [expected])
  }

  @Test func valueIsTheSameAnswerHoweverOftenItIsAsked() async throws {
    let run = try await startedRun()
    let first = try await run.value()
    let second = try await run.value()

    #expect(first == second)
    #expect(first.text == "Found it.")
    #expect(first.toolsUsed == ["grep"])
    #expect(first.state == .done)
    #expect(first.status == .idle)
    #expect(first.turnNumber == 1)
    #expect(!first.isFailure)
  }

  /// A view that subscribes after the turn finished still gets the whole
  /// transcript — a late reader must not see an empty stream.
  @Test func aLateSubscriberGetsEveryEventReplayed() async throws {
    let run = try await startedRun()
    _ = try await run.value()

    var seen: [String] = []
    for try await event in run.events {
      switch event {
      case .conversation(let conversation, _): seen.append("conversation:\(conversation.id)")
      case .turnStart(let number, _): seen.append("start:\(number)")
      case .tool(let name, _): seen.append("tool:\(name)")
      case .text(let text): seen.append("text:\(text)")
      case .turnEnd(let state, _, _): seen.append("end:\(state.rawValue)")
      default: break
      }
    }
    #expect(seen == ["conversation:c1", "start:1", "tool:grep", "text:Found it.", "end:done"])
  }

  /// Two readers of one run see the same turn, and neither starts a second
  /// stream — the app tails a conversation in a window and a menu bar item
  /// at once.
  @Test func twoSubscribersSeeTheSameTurn() async throws {
    let run = try await startedRun()

    async let first = collectText(run)
    async let second = collectText(run)
    let (left, right) = try await (first, second)

    #expect(left == "Found it.")
    #expect(right == left)
    #expect(try await run.value().text == left)
  }

  /// The sandbox can go away mid-turn, and then the turn-end never comes.
  /// Waiting for it is the hang this avoids.
  @Test func aConversationThatDiesUnderTheTurnEndsTheRun() async throws {
    let dying = """
      id: 1
      event: stage
      data: {"id":1,"kind":"stage","stage":"turn","state":"started","stream":"stage","data":"{\\"turn_number\\": 1, \\"turn_id\\": \\"t1\\"}"}

      id: 2
      event: output
      data: {"id":2,"kind":"output","stream":"acp","turn_id":"t1","blocks":[{"kind":"text","body":"Half an answer"}]}

      id: 3
      event: stage
      data: {"id":3,"kind":"stage","stage":"sandbox","state":"failed","stream":"stage","data":"{\\"message\\": \\"the sandbox went away\\"}"}


      """
    let failed = #"{"data": {"id": "c1", "status": "failed", "runtime": "claude"}}"#
    let transport = FakeTransport([
      .init(
        status: 201, json: #"{"data": {"id": "c1", "status": "running", "runtime": "claude"}}"#),
      .init(json: dying),
      .init(json: failed),  // the check that the conversation really died
      .init(json: failed),  // the final status read
    ])

    let result = try await FountainClient.fake(transport).run("hello", agent: "a1").value()
    #expect(result.state == .failed)
    #expect(result.text == "Half an answer")
    #expect(result.reason == "sandbox/failed: the sandbox went away")
    #expect(result.status == .failed)
    #expect(result.isFailure)
  }

  private func collectText(_ run: Run) async throws -> String {
    var text = ""
    for try await event in run.events {
      if case .text(let chunk) = event { text += chunk }
    }
    return text
  }
}
