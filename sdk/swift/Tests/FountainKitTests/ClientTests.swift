import Foundation
import Testing

@testable import FountainKit

@Suite struct RequestBuildingTests {
  @Test func conversationCreatePreservesSandboxAPIAccessAndOmitsTheDefault() throws {
    for access: SandboxAPIAccess? in [nil, SandboxAPIAccess.none, .owner] {
      let request = ConversationCreateRequest(agentID: "agent", sandboxAPIAccess: access)
      let data = try JSONEncoder().encode(request)
      let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(wire["sandbox_api_access"] as? String == access?.rawValue)
      if access == nil { #expect(wire["sandbox_api_access"] == nil) }
    }
  }

  @Test func setsAuthAcceptAndUserAgent() async throws {
    let transport = FakeTransport(json: #"{"data": []}"#)
    let client = FountainClient.fake(transport)
    _ = try await client.agents.list()

    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ftn_live_test")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(
      request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("fountain-sdk-swiftkit/") == true)
    #expect(request.url?.absoluteString == "https://fountain.test/api/agents")
  }

  @Test func missingKeyThrowsBeforeAnyIO() async throws {
    let transport = FakeTransport(json: "{}")
    let client = FountainClient(
      config: FountainConfig(baseURL: URL(string: "https://fountain.test")!),
      transport: transport
    )
    await #expect(throws: FountainError.self) {
      _ = try await client.agents.list()
    }
    #expect(transport.requests.isEmpty)
  }

  @Test func skipsEmptyQueryValues() async throws {
    let transport = FakeTransport(json: #"{"data": []}"#)
    let client = FountainClient.fake(transport)
    _ = try await client.conversations.list(rootsOnly: true)

    let url = try #require(transport.lastRequest?.url?.absoluteString)
    #expect(url == "https://fountain.test/api/conversations?roots_only=true")
  }

  // The minimal Teammate payload the contract requires (see
  // ResourceWireTests.payloadsFromAnOlderServerStillDecode's Teammate fixture),
  // wrapped in the `{ "data": … }` envelope `rename` decodes.
  private static let teammateEnvelopeJSON = #"""
    {"data":{"agent":{"id":"a1","name":"agent","runtime":"acp"},"agent_id":"a1",
     "conversation":{"id":"c1","runtime":"acp","status":"idle"},"name":"agent",
     "presence":{"state":"online"},"unread":false}}
    """#

  @Test func renameSendsAnExplicitNullForANilNameRatherThanOmittingTheKey() async throws {
    let transport = FakeTransport(json: Self.teammateEnvelopeJSON)
    _ = try await FountainClient.fake(transport).team.rename("a1", name: nil)

    let sent = try JSONDecoder().decode(
      JSONValue.self, from: #require(transport.lastRequest?.httpBody))
    #expect(sent == .object(["name": .null]))
  }

  @Test func renameSendsTheGivenNameWhenPresent() async throws {
    let transport = FakeTransport(json: Self.teammateEnvelopeJSON)
    _ = try await FountainClient.fake(transport).team.rename("a1", name: "Bob")

    let sent = try JSONDecoder().decode(
      JSONValue.self, from: #require(transport.lastRequest?.httpBody))
    #expect(sent == .object(["name": .string("Bob")]))
  }
}

@Suite struct DecodingTests {
  @Test func decodesSandboxAPIAccess() throws {
    let data = Data(
      #"{"id":"c-1","runtime":"claude","status":"idle","sandbox_api_access":"none"}"#.utf8)
    let conversation = try JSONDecoder().decode(Conversation.self, from: data)
    #expect(conversation.sandboxAPIAccess == SandboxAPIAccess.none)
  }

  @Test func decodesAccountingWithoutInventingMissingCounts() throws {
    let bytes = Data(
      #"{"accounting":{"version":1,"source":"codex/thread-token-usage-delta","scope":"root_thread_prompt","completeness":"partial"}}"#
        .utf8)
    let usage = try JSONDecoder().decode(Usage.self, from: bytes)
    #expect(usage.input == nil)
    #expect(usage.output == nil)
    #expect(usage.accounting?.version == 1)
    #expect(usage.accounting?.scope == "root_thread_prompt")
    #expect(usage.accounting?.completeness == "partial")
    let legacy = try JSONDecoder().decode(Usage.self, from: Data(#"{"input":1,"output":2}"#.utf8))
    #expect(legacy.accounting == nil)
    #expect(legacy.input == 1)
  }

  // Shape verified against GET /api/agents on 2026-08-31.
  static let agentJSON = """
    {"id":"66a4e14f-7ecd-42d2-9136-6a4829383d47","name":"cantor","description":null,
     "system":"You are Cantor.","model":"anthropic/claude-sonnet-5","runtime":"claude",
     "acp":true,"sandbox_provider":null,"sandbox_mode":"persistent",
     "environment_id":"48c6a7a1-4a8f-4f19-84d5-66b8c735365f","permission_policy":{},
     "skills":[],"mcp_servers":{},"metadata":{},"allowed_vault_ids":null,
     "allowed_environment_ids":null,"conversation_count":7,"avatar_media_type":null,
     "inserted_at":"2026-08-30T20:57:19Z","updated_at":"2026-08-30T20:57:19Z"}
    """

  @Test func decodesAgentFromEnvelope() async throws {
    let transport = FakeTransport(json: #"{"data": \#(Self.agentJSON)}"#)
    let client = FountainClient.fake(transport)
    let agent = try await client.agents.get("66a4e14f-7ecd-42d2-9136-6a4829383d47")
    #expect(agent.name == "cantor")
    #expect(agent.runtime == .claude)
    #expect(agent.sandboxMode == .persistent)
    #expect(agent.insertedAt != nil)
  }

  /// An `acp` agent carries no model, and the wire sends an explicit null
  /// rather than dropping the key (#1634). A non-optional `model` made this
  /// throw `valueNotFound`, and because a page is decoded whole, one such
  /// agent in the account broke `agents.list()` for every caller.
  @Test func decodesAnAgentWithNoModel() async throws {
    let json = """
      {"id":"a1","name":"converger","description":null,"system":null,
       "model":null,"runtime":"acp","runtime_command":"chant acp --env prod",
       "acp":true,"sandbox_provider":null,"sandbox_mode":"persistent",
       "environment_id":null,"permission_policy":null,"skills":[],
       "mcp_servers":{},"metadata":{},"allowed_vault_ids":null,
       "allowed_environment_ids":null,"conversation_count":0,
       "avatar_media_type":null,"inserted_at":"2026-09-10T09:00:00Z",
       "updated_at":"2026-09-10T09:00:00Z"}
      """
    let transport = FakeTransport(json: #"{"data": \#(json)}"#)
    let client = FountainClient.fake(transport)
    let agent = try await client.agents.get("a1")

    #expect(agent.model == nil)
    #expect(agent.runtime == .acp)
    #expect(agent.runtimeCommand == "chant acp --env prod")
  }

  /// The other half: a page with one acp agent beside a model-driven one.
  @Test func decodesAPageMixingAcpAndModelAgents() async throws {
    let acp = """
      {"id":"a1","name":"converger","model":null,"runtime":"acp",
       "runtime_command":"chant acp"}
      """
    let transport = FakeTransport(json: #"{"data": [\#(acp), \#(Self.agentJSON)]}"#)
    let client = FountainClient.fake(transport)
    let agents = try await client.agents.list()

    #expect(agents.count == 2)
    #expect(agents.first?.model == nil)
    #expect(agents.last?.model == "anthropic/claude-sonnet-5")
  }

  /// A command is sent on create, and omitted entirely when there is none.
  @Test func encodesRuntimeCommandOnInput() throws {
    let input = AgentInput(name: "converger", runtime: .acp, runtimeCommand: "chant acp")
    let body = try JSONEncoder().encode(input)
    let wire = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(wire["runtime_command"] as? String == "chant acp")
    #expect(wire["model"] == nil)

    let plain = AgentInput(name: "c", model: "anthropic/claude-sonnet-5", runtime: .claude)
    let plainBody = try JSONEncoder().encode(plain)
    let plainWire = try #require(
      JSONSerialization.jsonObject(with: plainBody) as? [String: Any])
    #expect(plainWire["runtime_command"] == nil)
  }

  /// Omitted keeps a binding, `.clear` removes it, and the two have to stay
  /// distinguishable all the way to the wire.
  @Test func encodesTheThreeBindingStatesOnReapply() throws {
    let refresh = try JSONEncoder().encode(ConversationReapplyRequest())
    let refreshWire = try #require(
      JSONSerialization.jsonObject(with: refresh) as? [String: Any])
    #expect(refreshWire.isEmpty)

    let selection = ConversationReapplyRequest(
      agentID: "a-1", environment: .use("e-1"), vault: .clear)
    let body = try JSONEncoder().encode(selection)
    let wire = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(wire["agent_id"] as? String == "a-1")
    #expect(wire["environment_id"] as? String == "e-1")
    #expect(wire["vault_id"] is NSNull)
  }

  @Test func unknownEnumValuesSurvive() throws {
    let json = Data(#"{"id":"x","name":"n","model":"m","runtime":"zed","status":"paused"}"#.utf8)
    struct Row: Decodable {
      var runtime: Runtime
      var status: ConversationStatus
    }
    let row = try JSONDecoder().decode(Row.self, from: json)
    #expect(row.runtime.rawValue == "zed")
    #expect(row.status.rawValue == "paused")
    #expect(row.status != .running)
  }

  @Test func decodesLogEventPage() async throws {
    // Shape verified against GET .../events?blocks=true on 2026-08-31:
    // stage events carry stream:"" and blocks:[]; ts has fractional seconds.
    let transport = FakeTransport(
      json: """
        {"data":[
          {"data":"{}","id":219889,"stream":"","state":"started","blocks":[],"kind":"stage",
           "ts":"2026-08-29T08:17:57.000000Z","stage":"provision","turn_id":null,"duration_ms":null},
          {"data":"hello","id":219890,"stream":"acp","state":null,"kind":"output",
           "ts":"2026-08-29T08:17:58.000000Z","stage":null,"turn_id":"t1","duration_ms":null,
           "blocks":[{"kind":"text","body":"hello"},
                     {"kind":"tool_use","id":"c1","name":"Bash","summary":"ls","novel_field":{"x":1}}]}
        ],"meta":{"limit":3,"has_more":true,"next_cursor":219891}}
        """)
    let client = FountainClient.fake(transport)
    let page = try await client.conversations.events("c-1", after: 0, limit: 3)

    #expect(page.items.count == 2)
    #expect(page.meta?.hasMore == true)
    #expect(page.meta?.nextCursor == 219891)
    #expect(page.items[0].kind == .stage)
    #expect(page.items[0].stage == "provision")

    let blocks = try #require(page.items[1].blocks)
    #expect(blocks[0].kind == .text)
    #expect(blocks[0].body == "hello")
    #expect(blocks[1].kind == .toolUse)
    #expect(blocks[1].name == "Bash")
    #expect(blocks[1].extra["novel_field"] != nil)

    let url = try #require(transport.lastRequest?.url?.absoluteString)
    #expect(url.contains("blocks=true"))
  }

  @Test func authMeIsUnenveloped() async throws {
    // Shape verified against GET /api/auth/me on 2026-08-31 (no envelope);
    // `onboarding_state` left with #1393, which dropped the column.
    let transport = FakeTransport(
      json: """
        {"id":"50e06232-0000-0000-0000-000000000000","email":"user@example.com","role":"admin",
         "email_verified":true,"comped":false,"brokered":true,
         "onboarding_completed":true,"connections_enabled":false,"connections_manageable":true}
        """)
    let me = try await FountainClient.fake(transport).auth.me()
    #expect(me.email == "user@example.com")
    #expect(me.brokered == true)
    #expect(me.connectionsEnabled == false)
    #expect(me.connectionsManageable == true)
  }

  @Test func permissionRequestNeedsIdAndUsableOption() throws {
    let decoder = JSONDecoder()
    let answerable = try decoder.decode(
      Block.self,
      from: Data(
        """
        {"kind":"permission_request","request_id":"r1","summary":"Run ls?",
         "options":[{"optionId":"allow","kind":"allow_once"}]}
        """.utf8))
    #expect(PermissionRequest(block: answerable)?.requestID == "r1")

    let notice = try decoder.decode(
      Block.self,
      from: Data(
        """
        {"kind":"permission_request","summary":"FYI","options":[]}
        """.utf8))
    #expect(PermissionRequest(block: notice) == nil)
  }
}

@Suite struct ErrorMappingTests {
  @Test func conversationBusyByCode() async throws {
    let transport = FakeTransport(
      json: #"{"error":"conversation_busy","message":"mid-turn"}"#, status: 400
    )
    do {
      try await FountainClient.fake(transport).conversations.prompt("c-1", "hi")
      Issue.record("expected throw")
    } catch let error as FountainError {
      guard case .conversationBusy = error else {
        Issue.record("wrong case: \(error)")
        return
      }
    }
  }

  @Test func notReadyCarriesRetryAfterHeader() async throws {
    let transport = FakeTransport(
      json: #"{"error":"provisioning","message":"starting"}"#,
      status: 503,
      headers: ["Retry-After": "30"]
    )
    do {
      _ = try await FountainClient.fake(transport).team.message("a-1", "hi")
      Issue.record("expected throw")
    } catch let error as FountainError {
      guard case .notReady(_, let retryAfter) = error else {
        Issue.record("wrong case: \(error)")
        return
      }
      #expect(retryAfter == 30)
    }
  }

  @Test func validationErrorsMapIsDecoded() async throws {
    let transport = FakeTransport(
      json: #"{"errors":{"name":["can't be blank"],"cron":["is invalid"]}}"#, status: 422
    )
    do {
      _ = try await FountainClient.fake(transport).vaults.create(VaultInput(name: ""))
      Issue.record("expected throw")
    } catch let error as FountainError {
      guard case .validation(let body) = error else {
        Issue.record("wrong case: \(error)")
        return
      }
      #expect(body.fieldErrors["name"] == ["can't be blank"])
    }
  }

  @Test func authReasonBecomesTheCode() async throws {
    // Auth failures invert the convention: error is prose, reason is the code.
    let transport = FakeTransport(
      json: #"{"error":"Invalid or missing API key","reason":"api_key_expired"}"#, status: 401
    )
    do {
      _ = try await FountainClient.fake(transport).auth.me()
      Issue.record("expected throw")
    } catch let error as FountainError {
      #expect(error.code == "api_key_expired")
      #expect(error.body?.message == "Invalid or missing API key")
    }
  }

  @Test func aCodedErrorKeepsItsCodeWhenReasonNarrowsIt() async throws {
    // `reason` only takes over when `error` is a sentence. Here both are
    // codes and `reason` narrows `error`, so the code stays (#2324).
    let transport = FakeTransport(
      json:
        #"{"error":"credential_set_is_default","message":"m","reason":"is_default"}"#,
      status: 422
    )
    do {
      try await FountainClient.fake(transport).vaults.delete("v-1")
      Issue.record("expected throw")
    } catch let error as FountainError {
      #expect(error.code == "credential_set_is_default")
      #expect(error.body?.reason == "is_default" && error.body?.message == "m")
    }
  }

  @Test func aBodyWithoutErrorStillDecodes() async throws {
    // Phoenix's own error pages and the 406 send `errors` alone, as a
    // detail string rather than field -> messages. `error` is pinned
    // Optional in the generated payload so these still reach the caller.
    let transport = FakeTransport(json: #"{"errors":{"detail":"Not Acceptable"}}"#, status: 406)
    do {
      _ = try await FountainClient.fake(transport).auth.me()
      Issue.record("expected throw")
    } catch let error as FountainError {
      #expect(error.status == 406 && error.code == nil)
      #expect(error.fieldErrors == ["detail": ["Not Acceptable"]])
    }
  }

  @Test func insufficientCreditsCarriesUpgradeURL() async throws {
    let transport = FakeTransport(
      json: #"{"error":"insufficient_credits","upgrade_url":"/account/billing"}"#, status: 402
    )
    do {
      _ = try await FountainClient.fake(transport).conversations.create(
        ConversationCreateRequest(agentID: "a-1", prompt: "hi")
      )
      Issue.record("expected throw")
    } catch let error as FountainError {
      guard case .insufficientCredits(_, let url) = error else {
        Issue.record("wrong case: \(error)")
        return
      }
      #expect(url == "/account/billing")
    }
  }
}

@Suite struct StreamTests {
  @Test func decodesEventsAndSignals() async throws {
    let sse = """
      : connected\n\n\
      id: 100\nevent: output\ndata: {"id":100,"kind":"output","stream":"acp","ts":"2026-08-29T08:17:58.000000Z","blocks":[{"kind":"text","body":"hi"}]}\n\n\
      event: team\ndata: {"reason":"changed"}\n\n\
      id: 101\nevent: stage\ndata: {"id":101,"kind":"stage","stage":"turn","state":"done","ts":"2026-08-29T08:17:59.000000Z"}\n\n
      """
    let transport = FakeTransport(json: sse)
    let client = FountainClient.fake(transport)

    var logs: [LogEvent] = []
    var signals: [String] = []
    for try await event in client.team.stream(StreamRequest(wait: false)) {
      switch event {
      case .log(let log): logs.append(log)
      case .signal(let name): signals.append(name)
      }
    }
    #expect(logs.map(\.id) == [100, 101])
    #expect(signals == ["team"])
    #expect(logs[1].stage == "turn")
    #expect(logs[1].state == .done)

    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    #expect(request.url?.query?.contains("wait=false") == true)
  }

  @Test func resumeSendsLastEventID() async throws {
    let transport = FakeTransport(json: "")
    let client = FountainClient.fake(transport)
    for try await _ in client.conversations.stream("c-1", StreamRequest(after: 42, wait: false)) {}
    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == "42")
  }

  @Test func fourXXThrowsWithoutRetry() async throws {
    let transport = FakeTransport(json: #"{"error":"not_found"}"#, status: 404)
    let client = FountainClient.fake(transport)
    do {
      for try await _ in client.conversations.stream("c-1") {}
      Issue.record("expected throw")
    } catch is FountainError {
      // one request, no retries against a 4xx
      #expect(transport.requests.count == 1)
    }
  }
}
