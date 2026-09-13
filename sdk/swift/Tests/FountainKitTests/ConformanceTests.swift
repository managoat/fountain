import Foundation
import Testing

@testable import FountainKit

/// The shared SDK conformance suite, run against FountainKit.
///
/// `sdk/contract/` pins the *shape* of the wire; `sdk/conformance/scenarios`
/// pins the *behaviour*: which error class a 402 becomes, what a client does
/// with an SSE frame split across two writes, whether a dropped stream
/// resumes from the right cursor. The scenarios are the same files the
/// TypeScript, Python, Elixir and untyped-Swift clients run, and contain no
/// language-specific expectation — this file is the adapter, and holds no
/// expectations of its own.
///
/// `sdk/conformance/matrix.json` says which scenarios this client runs,
/// under the `swift-kit` column.
@Suite("Conformance")
struct ConformanceTests {
  @Test("scenario", .timeLimit(.minutes(1)), arguments: ConformanceSuite.runnable)
  func scenario(_ name: String) async throws {
    let scenario = try ConformanceSuite.scenario(named: name)
    let transport = ScriptedTransport(
      exchanges: scenario.http,
      holdQuietTail: scenario.name == "run-timeout-raises-and-keeps-partial-text")
    let observations = Observations()

    do {
      try await drive(scenario, transport: transport, into: observations)
    } catch {
      observations.error = error
    }

    let problems = check(scenario, observations: observations, transport: transport)
    if !problems.isEmpty {
      Issue.record(
        Comment(
          rawValue: """
            conformance FAILED for swift-kit / \(scenario.name)
              \(scenario.title)

            \(problems.map { "  \($0)" }.joined(separator: "\n\n"))
            """))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func timeoutKeepsTextWhenFirstFrameArrivesAfterTheOriginalDeadline() async throws {
    var scenario = try ConformanceSuite.scenario(
      named: "run-timeout-raises-and-keeps-partial-text")
    var exchange = try #require(scenario.http[1].objectValue)
    var response = try #require(exchange["respond"]?.objectValue)
    var frames = try #require(response["sse"]?.arrayValue)
    let first = try #require(frames[0].stringValue)
    // Reproduce the mechanism on every run: delivery takes twice the
    // scenario's 300 ms deadline before any output can be consumed.
    frames[0] = .object(["text": .string(first), "delay_ms": .number(600)])
    response["sse"] = .array(frames)
    exchange["respond"] = .object(response)
    scenario.http[1] = .object(exchange)
    let transport = ScriptedTransport(exchanges: scenario.http, holdQuietTail: true)
    let observations = Observations()
    do {
      try await drive(scenario, transport: transport, into: observations)
    } catch {
      observations.error = error
    }
    let problems = check(scenario, observations: observations, transport: transport)
    #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
  }

  @Test(.timeLimit(.minutes(1)))
  func publicClientDeadlineDoesNotWaitForOutput() async throws {
    var scenario = try ConformanceSuite.scenario(
      named: "run-timeout-raises-and-keeps-partial-text")
    var exchange = try #require(scenario.http[1].objectValue)
    var response = try #require(exchange["respond"]?.objectValue)
    response["sse"] = .array([.object(["text": .string(""), "delay_ms": .number(1000)])])
    exchange["respond"] = .object(response)
    scenario.http[1] = .object(exchange)
    let transport = ScriptedTransport(exchanges: scenario.http, holdQuietTail: true)
    let client = FountainClient(config: scenario.config, transport: transport)
    let run = try await client.run(
      "hello", agent: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", timeout: 0.01)
    do {
      _ = try await run.value()
      Issue.record("a silent stream must time out")
    } catch FountainError.timedOut(let partialText) {
      #expect(partialText.isEmpty)
    }
    #expect(transport.unmatched.isEmpty)
  }

  /// A scenario nobody has ruled on is a scenario nobody has read.
  /// `lint.py` enforces this too; this is the same rule, where a Swift
  /// developer will see it fail.
  @Test func everyScenarioHasAVerdict() {
    #expect(
      ConformanceSuite.unlisted.isEmpty,
      Comment(
        rawValue: "Add a swift-kit verdict to sdk/conformance/matrix.json for: "
          + ConformanceSuite.unlisted.joined(separator: ", "))
    )
  }

  /// Surfaces the documented deviations in the test log, so they stay
  /// visible instead of decaying into silence.
  @Test(
    .disabled("documented deviations, see sdk/conformance/matrix.json"),
    arguments: ConformanceSuite.deviations)
  func deviation(_ deviation: Deviation) {}
}

/// Start the scenario's deadline only after the consumer has observed output.
/// The timeout still expires through Run's real deadline/error path; this
/// removes the race between a loaded Swift executor and the first SSE frame.
/// Its matching quiet tail stays open until cancellation, so it cannot win
/// while the consumer is waiting to be scheduled. The scenario's one-minute
/// test limit makes missing output a bounded failure rather than a hang.
private final class ObservedOutputDeadline: Sendable {
  private let output: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (output, continuation) = AsyncStream.makeStream()
  }

  func outputObserved() {
    continuation.yield(())
    continuation.finish()
  }

  func sleep(nanoseconds: UInt64) async throws {
    for await _ in output { break }
    try Task.checkCancellation()
    try await Task.sleep(nanoseconds: nanoseconds)
  }
}

// MARK: - driving

private func drive(
  _ scenario: Scenario,
  transport: ScriptedTransport,
  into observations: Observations
) async throws {
  let deadline = ObservedOutputDeadline()
  var api = APIClient(config: scenario.config, transport: transport)
  if scenario.name == "run-timeout-raises-and-keeps-partial-text" {
    api.sleepForRunDeadline = { try await deadline.sleep(nanoseconds: $0) }
  }
  let client = FountainClient(api: api)

  for step in scenario.steps {
    guard let op = step["op"]?.stringValue else {
      throw Harness("a step has no op")
    }
    switch op {
    case "me":
      let me = try await client.auth.me()
      observations.value = .object(["id": .string(me.id), "email": .string(me.email)])

    case "list":
      switch step["resource"]?.stringValue {
      case "agents":
        observations.value = .array(try await client.agents.list().map(named))
      case "vaults":
        observations.value = .array(try await client.vaults.list().map(named))
      case "environments":
        observations.value = .array(try await client.environments.list().map(named))
      case let other:
        throw Harness("unsupported list resource \(other ?? "(none)")")
      }

    case "create_agent":
      let attributes = step["attrs"]?.objectValue ?? [:]
      let agent = try await client.agents.create(
        AgentInput(
          name: attributes["name"]?.stringValue,
          description: attributes["description"]?.stringValue,
          system: attributes["system"]?.stringValue,
          model: attributes["model"]?.stringValue
        ))
      observations.value = named(agent)

    case "get_conversation":
      let conversation = try await client.conversations.get(try id(step))
      observations.value = .object([
        "id": .string(conversation.id),
        "status": .string(conversation.status.rawValue),
      ])

    case "history":
      observations.eventIDs = try await client.conversations.history(try id(step)).compactMap(\.id)

    case "send":
      guard let prompt = step["prompt"]?.stringValue else { throw Harness("send has no prompt") }
      let run = try await client.conversations.run(try id(step), prompt: prompt)
      observations.result = project(try await run.value())

    case "run":
      guard let agent = step["agent"]?.stringValue,
        let prompt = step["prompt"]?.stringValue
      else { throw Harness("run has no agent or prompt") }
      let answers = step["answer_permissions"]?.objectValue ?? [:]
      let run = try await client.run(
        prompt,
        agent: agent,
        timeout: step["timeout_ms"]?.intValue.map { Double($0) / 1000 }
      )
      for try await event in run.events {
        if case .text = event { deadline.outputObserved() }
        observations.events.append(project(event))
        if case .permission(let request, _) = event,
          let option = (answers[request.requestID] ?? answers["*"])?.stringValue
        {
          try await run.answer(requestID: request.requestID, optionID: option)
        }
      }
      observations.result = project(try await run.value())

    default:
      throw Harness("this adapter has no op \(op)")
    }
  }
}

private func id(_ step: JSONValue) throws -> String {
  guard let value = step["conversation_id"]?.stringValue else {
    throw Harness("a step has no conversation_id")
  }
  return value
}

private func named(_ agent: Agent) -> JSONValue {
  .object(["id": .string(agent.id), "name": .string(agent.name)])
}

private func named(_ vault: Vault) -> JSONValue {
  .object(["id": .string(vault.id), "name": .string(vault.name)])
}

private func named(_ environment: FountainKit.Environment) -> JSONValue {
  .object(["id": .string(environment.id), "name": .string(environment.name)])
}

// MARK: - projecting FountainKit's types into the scenario vocabulary

private func project(_ result: RunResult) -> JSONValue {
  .object([
    "state": .string(result.state.rawValue),
    "text": .string(result.text),
    "tools_used": .array(result.toolsUsed.map(JSONValue.string)),
    "turn_number": .number(Double(result.turnNumber)),
    "exit_code": result.exitCode.map { .number(Double($0)) } ?? .null,
    "reason": result.reason.map(JSONValue.string) ?? .null,
    "conversation_id": .string(result.conversationID),
    "status": result.status.map { .string($0.rawValue) } ?? .null,
  ])
}

private func project(_ event: TurnEvent) -> JSONValue {
  switch event {
  case .conversation(let conversation, let url):
    .object([
      "type": .string("conversation"),
      "conversation_id": .string(conversation.id),
      "url": .string(url.absoluteString),
    ])
  case .turnStart(let turnNumber, let turnID):
    .object([
      "type": .string("turn-start"),
      "turn_number": .number(Double(turnNumber)),
      "turn_id": turnID.map(JSONValue.string) ?? .null,
    ])
  case .text(let text):
    .object(["type": .string("text"), "text": .string(text)])
  case .thinking(let text):
    .object(["type": .string("thinking"), "text": .string(text)])
  case .tool(let name, _):
    .object(["type": .string("tool"), "name": .string(name)])
  case .permission(let request, _):
    .object([
      "type": .string("permission"),
      "request_id": .string(request.requestID),
      "options": .array(request.options.compactMap { $0.optionID.map(JSONValue.string) }),
    ])
  case .block:
    .object(["type": .string("block")])
  case .turnEnd(let state, let exitCode, let reason):
    .object([
      "type": .string("turn-end"),
      "state": .string(state.rawValue),
      "exit_code": exitCode.map { .number(Double($0)) } ?? .null,
      "reason": reason.map(JSONValue.string) ?? .null,
    ])
  }
}

/// The suite's error vocabulary. Every language maps its own error type onto
/// these names; ours is `FountainError`.
private func project(_ error: any Error) -> JSONValue {
  guard let error = error as? FountainError else {
    return .object(["kind": .string("unknown"), "message": .string(String(describing: error))])
  }
  let kind: String =
    switch error {
    case .missingAPIKey, .unauthorized: "auth"
    case .insufficientCredits: "subscription"
    case .notFound: "not_found"
    case .validation: "validation"
    case .rateLimited: "rate_limited"
    case .conversationBusy: "busy"
    case .notReady: "not_ready"
    case .quotaExceeded: "quota"
    case .transport: "connection"
    case .resolution, .invalidBaseURL: "resolution"
    case .timedOut: "timeout"
    case .decoding, .api: "server"
    }
  var output: [String: JSONValue] = [
    "kind": .string(kind),
    "status": error.status.map { .number(Double($0)) } ?? .null,
    "code": error.code.map(JSONValue.string) ?? .null,
    "retryable": .bool(error.isRetryable),
    "retry_after": error.retryAfter.map(JSONValue.number) ?? .null,
    "field_errors": .object(error.fieldErrors.mapValues { .array($0.map(JSONValue.string)) }),
  ]
  if case .timedOut(let partial) = error { output["partial_text"] = .string(partial) }
  return .object(output)
}

// MARK: - checking

private func check(
  _ scenario: Scenario,
  observations: Observations,
  transport: ScriptedTransport
) -> [String] {
  var problems: [String] = []
  func fail(_ subject: String, _ detail: String) {
    problems.append("\(subject)\n      \(detail)")
  }

  for request in transport.unmatched {
    fail(
      "unanticipated request",
      "the client sent \(request.line), which no exchange in the scenario anticipated. "
        + "Either it should not have been sent, or the scenario needs it."
    )
  }

  let expect = scenario.expect
  if let expected = expect["error"] {
    guard let actual = observations.error else {
      return problems + ["error\n      expected \(show(expected)) but the call succeeded"]
    }
    let projected = project(actual)
    if !subset(expected, projected) {
      fail("error", "expected \(show(expected))\n      got \(show(projected))")
    }
  } else if let actual = observations.error {
    fail("error", "the call was not supposed to fail, and raised \(show(project(actual)))")
  }

  if let expected = expect["requests"]?.arrayValue {
    let actual = transport.requests
    if expect["requests_exactly"]?.boolValue == true, actual.count != expected.count {
      fail(
        "requests",
        "expected exactly \(expected.count), saw \(actual.count): "
          + actual.map(\.line).joined(separator: ", ")
      )
    }
    for (index, wanted) in expected.enumerated() {
      guard index < actual.count else {
        fail("requests[\(index)]", "expected \(show(wanted)), saw nothing")
        continue
      }
      checkRequest(wanted, actual[index], index: index, fail: fail)
    }
  }

  // Events are checked in order but not exhaustively: a client may surface
  // more than the scenario names.
  if let expected = expect["events"]?.arrayValue {
    var cursor = 0
    for wanted in expected {
      guard let hit = observations.events[cursor...].firstIndex(where: { subset(wanted, $0) })
      else {
        fail(
          "events",
          "expected \(show(wanted)) after index \(cursor), and the run emitted:\n      "
            + show(.array(observations.events))
        )
        break
      }
      cursor = hit + 1
    }
  }

  if let expected = expect["result"] {
    guard let actual = observations.result else {
      fail("result", "expected \(show(expected)) but there was no result")
      return problems
    }
    if !subset(expected, actual) {
      fail("result", "expected \(show(expected))\n      got \(show(actual))")
    }
  }

  if let expected = expect["value"] {
    let actual = observations.value ?? .null
    if !subset(expected, actual) {
      fail("value", "expected \(show(expected))\n      got \(show(actual))")
    }
  }

  if let expected = expect["event_ids"] {
    let actual = JSONValue.array((observations.eventIDs ?? []).map { .number(Double($0)) })
    if !subset(expected, actual) {
      fail("event_ids", "expected \(show(expected))\n      got \(show(actual))")
    }
  }

  return problems
}

private func checkRequest(
  _ expected: JSONValue,
  _ actual: RecordedRequest,
  index: Int,
  fail: (String, String) -> Void
) {
  guard expected["method"]?.stringValue == actual.method,
    expected["path"]?.stringValue == actual.path
  else {
    return fail(
      "requests[\(index)]",
      "expected \(expected["method"]?.stringValue ?? "?") \(expected["path"]?.stringValue ?? "?"), "
        + "saw \(actual.line)"
    )
  }
  for (key, value) in expected["query"]?.objectValue ?? [:] {
    if actual.query[key] != value.stringValue {
      fail(
        "requests[\(index)].query.\(key)",
        "expected \(show(value)), got \(actual.query[key].map { "\"\($0)\"" } ?? "nothing")"
      )
    }
  }
  for (key, value) in expected["headers"]?.objectValue ?? [:] {
    if actual.headers[key.lowercased()] != value.stringValue {
      fail(
        "requests[\(index)].headers.\(key)",
        "expected \(show(value)), got \(actual.headers[key.lowercased()].map { "\"\($0)\"" } ?? "nothing")"
      )
    }
  }
  for (key, value) in expected["header_prefixes"]?.objectValue ?? [:] {
    let header = actual.headers[key.lowercased()] ?? ""
    if let prefix = value.stringValue, !header.hasPrefix(prefix) {
      fail(
        "requests[\(index)].headers.\(key)",
        "expected it to start with \(show(value)), got \"\(header)\""
      )
    }
  }
  for absent in expected["headers_absent"]?.arrayValue ?? [] {
    if let key = absent.stringValue, let value = actual.headers[key.lowercased()] {
      fail("requests[\(index)].headers.\(key)", "expected no such header, got \"\(value)\"")
    }
  }
  if let body = expected["body"], !subset(body, actual.body ?? .null) {
    fail(
      "requests[\(index)].body",
      "expected \(show(body))\n      got \(show(actual.body ?? .null))"
    )
  }
}

/// Objects match on the keys the scenario names; arrays match element for
/// element; everything else matches exactly.
private func subset(_ expected: JSONValue, _ actual: JSONValue) -> Bool {
  switch (expected, actual) {
  case (.object(let expected), .object(let actual)):
    expected.allSatisfy { key, value in
      actual[key].map { subset(value, $0) } ?? false
    }
  case (.array(let expected), .array(let actual)):
    expected.count == actual.count && zip(expected, actual).allSatisfy(subset)
  default:
    expected == actual
  }
}

private func show(_ value: JSONValue) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  guard let data = try? encoder.encode(value) else { return String(describing: value) }
  return String(decoding: data, as: UTF8.self)
    .replacingOccurrences(of: "\n", with: "\n      ")
}

// MARK: - loading

/// One scenario file: bytes in, observations out.
struct Scenario: Sendable {
  var name: String
  var title: String
  var client: JSONValue
  var http: [JSONValue]
  var steps: [JSONValue]
  var expect: JSONValue

  /// The scenario's client settings, pointed at a host that resolves
  /// nowhere — every byte comes from `ScriptedTransport`.
  var config: FountainConfig {
    FountainConfig(
      baseURL: URL(
        string: "https://conformance.invalid" + (client["base_url_suffix"]?.stringValue ?? ""))!,
      apiKey: client["api_key"]?.stringValue,
      timeout: client["timeout_ms"]?.intValue.map { Double($0) / 1000 } ?? 5
    )
  }
}

struct Deviation: Sendable, CustomTestStringConvertible {
  var name: String
  var reason: String
  var testDescription: String { "\(name) — \(reason)" }
}

final class Observations: @unchecked Sendable {
  var events: [JSONValue] = []
  var result: JSONValue?
  var value: JSONValue?
  var eventIDs: [Int]?
  var error: (any Error)?
}

struct Harness: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

enum ConformanceSuite {
  /// This client's column in the shared matrix.
  static let sdk = "swift-kit"

  /// The suite lives at a fixed place in the repository, found by walking
  /// up from this file — the same way the untyped client's harness finds it.
  static let directory: URL = {
    var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while current.path != "/" {
      let candidate = current.appendingPathComponent("sdk/conformance")
      if FileManager.default.fileExists(
        atPath: candidate.appendingPathComponent("matrix.json").path)
      {
        return candidate
      }
      current = current.deletingLastPathComponent()
    }
    fatalError("Could not find sdk/conformance from \(#filePath)")
  }()

  static let names: [String] = {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory.appendingPathComponent("scenarios"),
        includingPropertiesForKeys: nil
      )) ?? []
    return files.filter { $0.pathExtension == "json" }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted()
  }()

  private static let verdicts: [String: JSONValue] = {
    let url = directory.appendingPathComponent("matrix.json")
    let value = (try? Data(contentsOf: url)).flatMap {
      try? JSONDecoder().decode(JSONValue.self, from: $0)
    }
    return value?["scenarios"]?.objectValue ?? [:]
  }()

  static let runnable: [String] = names.filter { verdicts[$0]?[sdk]?.stringValue == "yes" }

  static let deviations: [Deviation] = names.compactMap { name in
    guard let reason = verdicts[name]?[sdk]?["skip"]?.stringValue else { return nil }
    return Deviation(name: name, reason: reason)
  }

  static let unlisted: [String] = names.filter { verdicts[$0]?[sdk] == nil }

  static func scenario(named name: String) throws -> Scenario {
    let url = directory.appendingPathComponent("scenarios/\(name).json")
    let value = try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: url))
    guard let name = value["name"]?.stringValue,
      let title = value["title"]?.stringValue,
      let http = value["http"]?.arrayValue,
      let steps = value["steps"]?.arrayValue,
      let expect = value["expect"],
      let client = value["client"]
    else { throw Harness("malformed scenario at \(url.path)") }
    return Scenario(
      name: name, title: title, client: client, http: http, steps: steps, expect: expect)
  }
}
