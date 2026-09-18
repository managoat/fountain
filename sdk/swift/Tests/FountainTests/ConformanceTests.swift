import Foundation
import Testing

@testable import Fountain

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private typealias JSONDictionary = [String: Any]

private struct ConformanceScenario {
  let name: String
  let title: String
  let client: JSONDictionary
  let exchanges: [JSONDictionary]
  let steps: [JSONDictionary]
  let expectation: JSONDictionary
}

private struct SkippedConformanceScenario: Sendable, CustomTestStringConvertible {
  let name: String
  let reason: String
  let issue: Int

  var testDescription: String { name }
}

private struct ConformanceCatalog: Sendable {
  let scenarioDirectory: URL
  let runnableNames: [String]
  let skipped: [SkippedConformanceScenario]

  var skipSummary: String {
    skipped.map { "\($0.name): #\($0.issue): \($0.reason)" }.joined(separator: "\n")
  }
}

private struct RecordedRequest: @unchecked Sendable {
  let method: String
  let path: String
  let query: [String: String]
  let headers: [String: String]
  let body: Any
}

private final class Observations: @unchecked Sendable {
  var events: [JSONDictionary] = []
  var result: JSONDictionary?
  var error: JSONDictionary?
  var value: Any = NSNull()
  var eventIDs: [Int]?
}

private final class ConformanceURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest, ConformanceURLProtocol) -> Void)?

  private let taskLock = NSLock()
  private var deliveryTask: Task<Void, Never>?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.handler?(request, self)
  }

  override func stopLoading() {
    taskLock.lock()
    let task = deliveryTask
    deliveryTask = nil
    taskLock.unlock()
    task?.cancel()
  }

  func respond(status: Int, headers: [String: String], data: Data, finish: Bool = true) {
    guard
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
    if finish { client?.urlProtocolDidFinishLoading(self) }
  }

  func deliver(chunks: [(text: String, delayMilliseconds: Int)], abort: Bool) {
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        for chunk in chunks {
          if chunk.delayMilliseconds > 0 {
            try await Task.sleep(
              nanoseconds: UInt64(chunk.delayMilliseconds) * 1_000_000)
          }
          try Task.checkCancellation()
          if !chunk.text.isEmpty {
            client?.urlProtocol(self, didLoad: Data(chunk.text.utf8))
          }
        }
        try Task.checkCancellation()
        if abort {
          // Give URLSession's delegate queue time to process the final didLoad
          // before it observes the broken connection.
          try await Task.sleep(nanoseconds: 10_000_000)
          client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
          client?.urlProtocolDidFinishLoading(self)
        }
      } catch is CancellationError {
        return
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }
    taskLock.lock()
    deliveryTask = task
    taskLock.unlock()
  }
}

private let conformanceMockSession: URLSession = {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ConformanceURLProtocol.self]
  return URLSession(configuration: configuration)
}()

private final class ScriptedTransport: @unchecked Sendable {
  private let lock = NSLock()
  private let exchanges: [JSONDictionary]
  private var consumed: [Bool]
  private var recordedRequests: [RecordedRequest] = []
  private var unmatchedRequests: [RecordedRequest] = []

  init(exchanges: [JSONDictionary]) {
    self.exchanges = exchanges
    self.consumed = exchanges.map { _ in false }
  }

  var requests: [RecordedRequest] {
    lock.withLock { recordedRequests }
  }

  var unmatched: [RecordedRequest] {
    lock.withLock { unmatchedRequests }
  }

  func handle(_ request: URLRequest, _ protocolInstance: ConformanceURLProtocol) {
    let recorded = record(request)
    let response: JSONDictionary? = lock.withLock {
      recordedRequests.append(recorded)
      guard let index = firstMatch(for: recorded) else {
        unmatchedRequests.append(recorded)
        return nil
      }
      consumed[index] = true
      return exchanges[index]["respond"] as? JSONDictionary
    }

    guard let response else {
      let body = try! JSONSerialization.data(
        withJSONObject: ["error": "conformance_unmatched_request"])
      protocolInstance.respond(
        status: 599, headers: ["content-type": "application/json"], data: body)
      return
    }
    serve(response, through: protocolInstance)
  }

  private func firstMatch(for request: RecordedRequest) -> Int? {
    for index in exchanges.indices where !consumed[index] {
      guard let match = exchanges[index]["match"] as? JSONDictionary else { continue }
      guard (match["method"] as? String)?.uppercased() == request.method else { continue }
      guard match["path"] as? String == request.path else { continue }
      guard stringSubset(match["query"], request.query) else { continue }
      guard stringSubset(match["headers"], request.headers, lowercaseKeys: true) else { continue }
      return index
    }
    return nil
  }

  private func serve(_ response: JSONDictionary, through protocolInstance: ConformanceURLProtocol) {
    let status = response["status"] as? Int ?? 200
    var headers = normalizedStringDictionary(response["headers"], lowercaseKeys: true)
    if let rawChunks = response["sse"] as? [Any] {
      let chunks = rawChunks.compactMap { raw -> (String, Int)? in
        if let text = raw as? String { return (text, 0) }
        guard let object = raw as? JSONDictionary, let text = object["text"] as? String else {
          return nil
        }
        return (text, object["delay_ms"] as? Int ?? 0)
      }
      protocolInstance.respond(status: status, headers: headers, data: Data(), finish: false)
      protocolInstance.deliver(chunks: chunks, abort: response["close"] as? String == "abort")
      return
    }

    let body: Data
    if let json = response["json"] {
      body = try! JSONSerialization.data(withJSONObject: json)
      if headers["content-type"] == nil { headers["content-type"] = "application/json" }
    } else if let text = response["body"] as? String {
      body = Data(text.utf8)
    } else {
      body = Data()
    }
    if !body.isEmpty { headers["content-length"] = String(body.count) }
    protocolInstance.respond(status: status, headers: headers, data: body)
  }

  private func record(_ request: URLRequest) -> RecordedRequest {
    let components = request.url.flatMap {
      URLComponents(url: $0, resolvingAgainstBaseURL: false)
    }
    let query = Dictionary(
      (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
      uniquingKeysWith: { _, last in last })
    let headers = Dictionary(
      (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) },
      uniquingKeysWith: { _, last in last })
    let body: Any
    if let data = requestBodyData(request), !data.isEmpty {
      body =
        (try? JSONSerialization.jsonObject(with: data)) ?? String(decoding: data, as: UTF8.self)
    } else {
      body = NSNull()
    }
    return RecordedRequest(
      method: request.httpMethod?.uppercased() ?? "GET",
      path: components?.path ?? request.url?.path ?? "/",
      query: query,
      headers: headers,
      body: body)
  }
}

private let conformanceCatalog: ConformanceCatalog = {
  do {
    let scenarioDirectory = try locateConformanceFile(
      "sdk/conformance/scenarios", from: #filePath, directory: true)
    let matrixURL = try locateConformanceFile(
      "sdk/conformance/matrix.json", from: #filePath)
    let matrix = try readJSONDictionary(matrixURL)
    let verdicts = matrix["scenarios"] as? JSONDictionary ?? [:]
    let names = try FileManager.default.contentsOfDirectory(
      at: scenarioDirectory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .map { $0.deletingPathExtension().lastPathComponent }
    .sorted()
    var runnable: [String] = []
    var skipped: [SkippedConformanceScenario] = []
    for name in names {
      let row = verdicts[name] as? JSONDictionary
      if row?["swift"] as? String == "yes" {
        runnable.append(name)
      } else if let skip = row?["swift"] as? JSONDictionary {
        skipped.append(
          SkippedConformanceScenario(
            name: name,
            reason: skip["skip"] as? String ?? "matrix entry has no reason",
            issue: skip["issue"] as? Int ?? 0))
      } else {
        fatalError("No Swift conformance verdict for \(name)")
      }
    }
    return ConformanceCatalog(
      scenarioDirectory: scenarioDirectory, runnableNames: runnable, skipped: skipped)
  } catch {
    fatalError("Could not load the Swift conformance catalog: \(error)")
  }
}()

@Suite("ConformanceTests", .serialized)
struct ConformanceTests {
  @Test("conformance", arguments: conformanceCatalog.runnableNames)
  func conformance(_ name: String) async {
    let scenario: ConformanceScenario
    do {
      scenario = try loadScenario(named: name)
    } catch {
      Issue.record(
        Comment(
          rawValue:
            "conformance FAILED for swift / \(name)\n  Could not load scenario\n\n  harness\n      \(error)"
        ))
      return
    }

    let transport = ScriptedTransport(exchanges: scenario.exchanges)
    let observations = Observations()
    let host = "\(scenario.name).conformance.invalid"
    ConformanceURLProtocol.handler = { request, protocolInstance in
      if request.url?.host == host {
        transport.handle(request, protocolInstance)
      } else {
        protocolInstance.respond(
          status: 599, headers: ["content-type": "application/json"], data: Data())
      }
    }
    defer { ConformanceURLProtocol.handler = nil }

    do {
      try await drive(
        scenario, baseURL: "https://\(host)", observations: observations)
    } catch {
      observations.error = normalizeError(error)
    }

    let problems = check(
      scenario, observations: observations, requests: transport.requests,
      unmatched: transport.unmatched)
    if !problems.isEmpty {
      let message =
        "conformance FAILED for swift / \(scenario.name)\n"
        + "  \(scenario.title)\n\n"
        + problems.map { "  \($0)" }.joined(separator: "\n\n")
        + "\n"
      Issue.record(Comment(rawValue: message))
    }
  }

  @Test(
    "matrix skip",
    .disabled(Comment(rawValue: conformanceCatalog.skipSummary)),
    arguments: conformanceCatalog.skipped)
  fileprivate func matrixSkip(_ scenario: SkippedConformanceScenario) {
    _ = scenario
  }
}

private func loadScenario(named name: String) throws -> ConformanceScenario {
  let url = conformanceCatalog.scenarioDirectory.appendingPathComponent("\(name).json")
  let object = try readJSONDictionary(url)
  guard let loadedName = object["name"] as? String,
    let title = object["title"] as? String,
    let client = object["client"] as? JSONDictionary,
    let exchanges = object["http"] as? [JSONDictionary],
    let steps = object["steps"] as? [JSONDictionary],
    let expectation = object["expect"] as? JSONDictionary
  else {
    throw harnessError("Malformed scenario at \(url.path)")
  }
  return ConformanceScenario(
    name: loadedName, title: title, client: client, exchanges: exchanges, steps: steps,
    expectation: expectation)
}

private func drive(
  _ scenario: ConformanceScenario, baseURL: String, observations: Observations
) async throws {
  let apiKey = scenario.client["api_key"] as? String
  let suffix = scenario.client["base_url_suffix"] as? String ?? ""
  let clientTimeout = TimeInterval(scenario.client["timeout_ms"] as? Int ?? 5_000) / 1_000
  let fountain = try Fountain(
    apiKey: apiKey,
    baseURL: "\(baseURL)\(suffix)",
    profile: apiKey == nil ? "__fountain_conformance_missing_key__" : nil,
    timeout: clientTimeout,
    session: conformanceMockSession)

  for step in scenario.steps {
    guard let operation = step["op"] as? String else {
      throw harnessError("A scenario step has no op")
    }
    switch operation {
    case "me":
      observations.value = jsonObject(try await fountain.me())
    case "list":
      let values: [JSONObject]
      switch step["resource"] as? String {
      case "agents": values = try await fountain.agents.list()
      case "vaults": values = try await fountain.vaults.list()
      case "environments": values = try await fountain.environments.list()
      default:
        throw harnessError("Unsupported list resource \(String(describing: step["resource"]))")
      }
      observations.value = values.map(jsonObject)
    case "create_agent":
      guard let attributes = step["attrs"] as? JSONDictionary else {
        throw harnessError("create_agent has no attrs")
      }
      observations.value = jsonObject(
        try await fountain.agents.create(try fountainJSON(attributes)))
    case "get_conversation":
      guard let id = step["conversation_id"] as? String else {
        throw harnessError("get_conversation has no conversation_id")
      }
      observations.value = jsonObject(try await fountain.resume(id).get())
    case "history":
      guard let id = step["conversation_id"] as? String else {
        throw harnessError("history has no conversation_id")
      }
      observations.eventIDs = try await fountain.resume(id).history().compactMap {
        $0["id"]?.intValue
      }
    case "send":
      guard let id = step["conversation_id"] as? String,
        let prompt = step["prompt"] as? String
      else {
        throw harnessError("send has no conversation_id or prompt")
      }
      observations.result = normalizeResult(
        try await fountain.resume(id).send(prompt).value())
    case "run":
      try await driveRun(step, fountain: fountain, observations: observations)
    default:
      throw harnessError("This adapter has no op \(operation)")
    }
  }
}

private func driveRun(
  _ step: JSONDictionary, fountain: Fountain, observations: Observations
) async throws {
  guard let agent = step["agent"] as? String, let prompt = step["prompt"] as? String else {
    throw harnessError("run has no agent or prompt")
  }
  let timeout = (step["timeout_ms"] as? Int).map { TimeInterval($0) / 1_000 }
  let answers = step["answer_permissions"] as? [String: String] ?? [:]
  let run = fountain.run(
    prompt, agent: agent, clientRequestID: step["client_request_id"] as? String,
    channelID: step["channel_id"] as? String, timeout: timeout)
  for try await event in run.events {
    observations.events.append(normalizeEvent(event))
    if case .permission(let request, _) = event,
      let option = answers[request.requestID] ?? answers["*"]
    {
      try await run.answer(requestID: request.requestID, optionID: option)
    }
  }
  observations.result = normalizeResult(try await run.value())
}

private func normalizeError(_ error: Error) -> JSONDictionary {
  guard let error = error as? FountainError else {
    return ["kind": "unknown", "message": String(describing: error)]
  }
  let kinds: [FountainError.Kind: String] = [
    .api: "server",
    .authentication: "auth",
    .insufficientCredits: "insufficient_credits",
    .notFound: "not_found",
    .validation: "validation",
    .rateLimit: "rate_limited",
    .conversationBusy: "busy",
    .notReady: "not_ready",
    .quotaExceeded: "quota",
    .connection: "connection",
    .resolution: "resolution",
    .timeout: "timeout",
  ]
  var output: JSONDictionary = [
    "kind": kinds[error.kind] ?? "unknown",
    "status": error.status,
    "code": error.code ?? NSNull(),
    "retryable": error.retryable,
    "retry_after": error.retryAfter ?? NSNull(),
    "field_errors": error.fieldErrors,
    "upgrade_url": error.upgradeURL ?? NSNull(),
  ]
  if error.kind == .timeout { output["partial_text"] = error.partialText ?? NSNull() }
  return output
}

private func normalizeEvent(_ event: RunEvent) -> JSONDictionary {
  switch event {
  case .conversation(let id, _, _):
    return ["type": "conversation", "conversation_id": id]
  case .turnStart(let turnNumber, let turnID):
    return [
      "type": "turn-start", "turn_number": turnNumber, "turn_id": turnID ?? NSNull(),
    ]
  case .text(let text):
    return ["type": "text", "text": text]
  case .thinking(let text):
    return ["type": "thinking", "text": text]
  case .tool(let name, _):
    return ["type": "tool", "name": name]
  case .permission(let request, _):
    return [
      "type": "permission",
      "request_id": request.requestID,
      "options": request.options.map(\.optionID),
    ]
  case .block:
    return ["type": "block"]
  case .event:
    return ["type": "event"]
  case .turnEnd(let state, let exitCode, let reason):
    return [
      "type": "turn-end",
      "state": state.rawValue,
      "exit_code": exitCode ?? NSNull(),
      "reason": reason ?? NSNull(),
    ]
  }
}

private func normalizeResult(_ result: RunResult) -> JSONDictionary {
  [
    "state": result.state.rawValue,
    "text": result.text,
    "tools_used": result.toolsUsed,
    "turn_number": result.turnNumber,
    "exit_code": result.exitCode ?? NSNull(),
    "reason": result.reason ?? NSNull(),
    "conversation_id": result.conversationID,
    "status": result.status ?? NSNull(),
  ]
}

private func check(
  _ scenario: ConformanceScenario,
  observations: Observations,
  requests: [RecordedRequest],
  unmatched: [RecordedRequest]
) -> [String] {
  var problems: [String] = []
  let expectation = scenario.expectation

  func fail(_ subject: String, _ detail: String) {
    problems.append("\(subject)\n      \(detail)")
  }

  for request in unmatched {
    fail(
      "unmatched request",
      "the client sent \(request.method) \(request.path), which no exchange in the scenario "
        + "anticipated. Either the client should not have sent it, or the scenario needs it.")
  }

  if let expectedError = expectation["error"] as? JSONDictionary {
    guard let actualError = observations.error else {
      fail("error", "expected \(show(expectedError)) but the call succeeded")
      return problems
    }
    if !dictionarySubset(expectedError, actualError) {
      fail("error", "expected \(show(expectedError))\n      got \(show(actualError))")
    }
  } else if let actualError = observations.error {
    fail("error", "the call was not supposed to fail, and raised \(show(actualError))")
  }

  if let wanted = expectation["requests"] as? [JSONDictionary] {
    if expectation["requests_exactly"] as? Bool == true, requests.count != wanted.count {
      fail(
        "requests",
        "expected exactly \(wanted.count) request(s), saw \(requests.count): "
          + requests.map { "\($0.method) \($0.path)" }.joined(separator: ", "))
    }
    for (index, expected) in wanted.enumerated() {
      guard requests.indices.contains(index) else {
        fail(
          "requests[\(index)]",
          "expected \(expected["method"] ?? "?") \(expected["path"] ?? "?"), saw nothing")
        continue
      }
      checkRequest(expected, actual: requests[index], index: index, fail: fail)
    }
  }

  if let expectedEvents = expectation["events"] as? [JSONDictionary] {
    var cursor = 0
    for expectedEvent in expectedEvents {
      guard
        let index = observations.events.indices.first(where: {
          $0 >= cursor && dictionarySubset(expectedEvent, observations.events[$0])
        })
      else {
        fail(
          "events",
          "expected \(show(expectedEvent)) after index \(cursor), and the run emitted:\n      "
            + show(observations.events))
        break
      }
      cursor = index + 1
    }
  }

  if let expectedResult = expectation["result"] as? JSONDictionary {
    if let actualResult = observations.result {
      if !dictionarySubset(expectedResult, actualResult) {
        fail("result", "expected \(show(expectedResult))\n      got \(show(actualResult))")
      }
    } else {
      fail("result", "expected \(show(expectedResult)) but there was no result")
    }
  }

  if let expectedValue = expectation["value"], !deepSubset(expectedValue, observations.value) {
    fail("value", "expected \(show(expectedValue))\n      got \(show(observations.value))")
  }

  if let expectedIDs = expectation["event_ids"],
    !deepSubset(expectedIDs, observations.eventIDs as Any)
  {
    fail(
      "event_ids", "expected \(show(expectedIDs))\n      got \(show(observations.eventIDs as Any))")
  }

  return problems
}

private func checkRequest(
  _ expected: JSONDictionary,
  actual: RecordedRequest,
  index: Int,
  fail: (_ subject: String, _ detail: String) -> Void
) {
  let expectedMethod = expected["method"] as? String
  let expectedPath = expected["path"] as? String
  guard expectedMethod == actual.method, expectedPath == actual.path else {
    fail(
      "requests[\(index)]",
      "expected \(expectedMethod ?? "?") \(expectedPath ?? "?"), saw \(actual.method) \(actual.path)"
    )
    return
  }
  if let query = expected["query"] as? JSONDictionary,
    !dictionarySubset(query, actual.query)
  {
    fail("requests[\(index)].query", "expected \(show(query))\n      got \(show(actual.query))")
  }
  if let headers = expected["headers"] as? JSONDictionary,
    !dictionarySubset(headers, actual.headers)
  {
    fail(
      "requests[\(index)].headers",
      "expected \(show(headers))\n      got \(show(actual.headers))")
  }
  for (header, prefix) in expected["header_prefixes"] as? [String: String] ?? [:] {
    let value = actual.headers[header] ?? ""
    if !value.hasPrefix(prefix) {
      fail(
        "requests[\(index)].headers.\(header)",
        "expected it to start with \(show(prefix)), got \(show(value))")
    }
  }
  for header in expected["headers_absent"] as? [String] ?? [] where actual.headers[header] != nil {
    fail(
      "requests[\(index)].headers.\(header)",
      "expected no such header, got \(show(actual.headers[header] as Any))")
  }
  if let body = expected["body"], !deepSubset(body, actual.body) {
    fail("requests[\(index)].body", "expected \(show(body))\n      got \(show(actual.body))")
  }
}

private func dictionarySubset(_ expected: JSONDictionary, _ actual: Any) -> Bool {
  guard let actual = actual as? JSONDictionary else { return false }
  return expected.allSatisfy { key, value in
    guard let actualValue = actual[key] else { return false }
    return deepSubset(value, actualValue)
  }
}

private func deepSubset(_ expected: Any, _ actual: Any) -> Bool {
  if let expected = expected as? OptionalProtocol {
    guard let wrapped = expected.wrapped else { return actual is NSNull }
    return deepSubset(wrapped, actual)
  }
  if let actual = actual as? OptionalProtocol {
    guard let wrapped = actual.wrapped else { return expected is NSNull }
    return deepSubset(expected, wrapped)
  }
  if expected is NSNull { return actual is NSNull }
  if let expected = expected as? JSONDictionary {
    return dictionarySubset(expected, actual)
  }
  if let expected = expected as? [Any] {
    guard let actual = actual as? [Any], expected.count == actual.count else { return false }
    return zip(expected, actual).allSatisfy(deepSubset)
  }
  if let expected = expected as? String { return expected == actual as? String }
  if let expected = expected as? NSNumber, let actual = actual as? NSNumber {
    return expected.compare(actual) == .orderedSame
  }
  if let expected = expected as? Bool { return expected == actual as? Bool }
  return String(describing: expected) == String(describing: actual)
}

private func stringSubset(
  _ rawExpected: Any?, _ actual: [String: String], lowercaseKeys: Bool = false
) -> Bool {
  let expected = normalizedStringDictionary(rawExpected, lowercaseKeys: lowercaseKeys)
  return expected.allSatisfy { actual[$0.key] == $0.value }
}

private func normalizedStringDictionary(
  _ value: Any?, lowercaseKeys: Bool
) -> [String: String] {
  guard let dictionary = value as? JSONDictionary else { return [:] }
  return Dictionary(
    uniqueKeysWithValues: dictionary.compactMap { key, value in
      guard let value = value as? String else { return nil }
      return (lowercaseKeys ? key.lowercased() : key, value)
    })
}

private func jsonObject(_ object: JSONObject) -> JSONDictionary {
  object.mapValues(jsonValue)
}

private func jsonValue(_ value: JSONValue) -> Any {
  switch value {
  case .null: return NSNull()
  case .bool(let value): return value
  case .number(let value): return NSDecimalNumber(decimal: value)
  case .string(let value): return value
  case .array(let value): return value.map(jsonValue)
  case .object(let value): return value.mapValues(jsonValue)
  }
}

private func fountainJSON(_ value: Any) throws -> JSONObject {
  let data = try JSONSerialization.data(withJSONObject: value)
  guard let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
    throw harnessError("Expected a JSON object")
  }
  return object
}

private func requestBodyData(_ request: URLRequest) -> Data? {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return nil }
  stream.open()
  defer { stream.close() }
  var output = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count <= 0 { break }
    output.append(buffer, count: count)
  }
  return output
}

private func show(_ value: Any) -> String {
  let unwrapped: Any
  if let optional = value as? OptionalProtocol {
    unwrapped = optional.wrapped ?? NSNull()
  } else {
    unwrapped = value
  }
  guard JSONSerialization.isValidJSONObject(unwrapped),
    let data = try? JSONSerialization.data(
      withJSONObject: unwrapped, options: [.prettyPrinted, .sortedKeys])
  else {
    return String(describing: unwrapped)
  }
  return String(decoding: data, as: UTF8.self)
}

private protocol OptionalProtocol {
  var wrapped: Any? { get }
}

extension Optional: OptionalProtocol {
  fileprivate var wrapped: Any? { self }
}

private func locateConformanceFile(
  _ relativePath: String, from sourceFile: String, directory: Bool = false
) throws -> URL {
  var current = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
  while true {
    let candidate = relativePath.split(separator: "/").reduce(current) {
      $0.appendingPathComponent(String($1))
    }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
      !directory || isDirectory.boolValue
    {
      return candidate
    }
    let parent = current.deletingLastPathComponent()
    if parent.path == current.path {
      throw harnessError("Could not locate \(relativePath) from \(sourceFile)")
    }
    current = parent
  }
}

private func readJSONDictionary(_ url: URL) throws -> JSONDictionary {
  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
  guard let object = value as? JSONDictionary else {
    throw harnessError("Expected a JSON object in \(url.path)")
  }
  return object
}

private func harnessError(_ message: String) -> NSError {
  NSError(
    domain: "FountainConformanceTests", code: 1,
    userInfo: [NSLocalizedDescriptionKey: message])
}

extension NSLock {
  fileprivate func withLock<Value>(_ body: () -> Value) -> Value {
    lock()
    defer { unlock() }
    return body()
  }
}
