import Foundation

@testable import FountainKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// One request, as a scenario's expectations describe it.
struct RecordedRequest: Sendable {
  var method: String
  var path: String
  var query: [String: String]
  /// Lowercased names — HTTP headers are case-insensitive.
  var headers: [String: String]
  var body: JSONValue?

  var line: String { "\(method) \(path)" }
}

/// Serves a scenario's `http` exchanges through FountainKit's own transport
/// seam — no URL loading system, no sockets, so the whole client above
/// `HTTPTransport` runs exactly as it does in production.
///
/// Each exchange answers at most one request, first declared first used, so a
/// scenario can script two different answers for the same route (a stream
/// that drops, then its resume). Anything the scenario did not anticipate is
/// recorded and answered 599, which fails the scenario loudly rather than
/// hanging it.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
  private let exchanges: [JSONValue]
  private let holdQuietTail: Bool
  private let lock = NSLock()
  private var consumed = Set<Int>()
  private var seen: [RecordedRequest] = []
  private var unanticipated: [RecordedRequest] = []

  init(exchanges: [JSONValue], holdQuietTail: Bool = false) {
    self.exchanges = exchanges
    self.holdQuietTail = holdQuietTail
  }

  var requests: [RecordedRequest] {
    lock.withLock { seen }
  }

  var unmatched: [RecordedRequest] {
    lock.withLock { unanticipated }
  }

  // MARK: HTTPTransport

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (recorded, exchange) = take(request)
    guard let exchange else { return (Self.unmatchedBody, response(599, [:], recorded)) }
    let status = exchange["status"]?.intValue ?? 200
    var headers = Self.stringMap(exchange["headers"])
    let body = Self.body(of: exchange, headers: &headers)
    return (body, response(status, headers, recorded))
  }

  func bytes(for request: URLRequest) async throws -> (
    HTTPURLResponse, AsyncThrowingStream<Data, any Error>
  ) {
    let (recorded, exchange) = take(request)
    guard let exchange else {
      return (response(599, [:], recorded), Self.once(Self.unmatchedBody))
    }
    let status = exchange["status"]?.intValue ?? 200
    var headers = Self.stringMap(exchange["headers"])

    guard let chunks = exchange["sse"]?.arrayValue else {
      let body = Self.body(of: exchange, headers: &headers)
      return (response(status, headers, recorded), Self.once(body))
    }

    // A scripted stream: chunks arrive on the scenario's clock, and
    // `close: abort` breaks the connection the way a dropped stream does.
    let abort = exchange["close"]?.stringValue == "abort"
    let stream = AsyncThrowingStream<Data, any Error> { continuation in
      let task = Task {
        for chunk in chunks {
          let text = chunk.stringValue ?? chunk["text"]?.stringValue ?? ""
          if let delay = chunk["delay_ms"]?.intValue, delay > 0 {
            if self.holdQuietTail && text.isEmpty {
              // This fixture represents a stream that remains quiet beyond
              // the run deadline. Let cancellation end it, even if processing
              // the preceding output takes longer than its scripted delay.
              let quiet = AsyncStream<Void> { _ in }
              for await _ in quiet {}
            } else {
              try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
          }
          if Task.isCancelled { return continuation.finish() }
          if !text.isEmpty { continuation.yield(Data(text.utf8)) }
        }
        if abort {
          continuation.finish(throwing: URLError(.networkConnectionLost))
        } else {
          continuation.finish()
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return (response(status, headers, recorded), stream)
  }

  // MARK: matching

  private func take(_ request: URLRequest) -> (RecordedRequest, JSONValue?) {
    let recorded = Self.record(request)
    return lock.withLock {
      seen.append(recorded)
      for (index, exchange) in exchanges.enumerated() where !consumed.contains(index) {
        guard let match = exchange["match"], matches(match, recorded) else { continue }
        consumed.insert(index)
        return (recorded, exchange["respond"] ?? .object([:]))
      }
      unanticipated.append(recorded)
      return (recorded, nil)
    }
  }

  private func matches(_ match: JSONValue, _ request: RecordedRequest) -> Bool {
    guard match["method"]?.stringValue?.uppercased() == request.method,
      match["path"]?.stringValue == request.path
    else { return false }
    for (key, value) in Self.stringMap(match["query"]) where request.query[key] != value {
      return false
    }
    for (key, value) in Self.stringMap(match["headers"]) {
      if request.headers[key.lowercased()] != value { return false }
    }
    return true
  }

  // MARK: shaping

  private static let unmatchedBody = Data(#"{"error":"conformance_unanticipated_request"}"#.utf8)

  private func response(_ status: Int, _ headers: [String: String], _ request: RecordedRequest)
    -> HTTPURLResponse
  {
    HTTPURLResponse(
      url: URL(string: "https://conformance.invalid\(request.path)")!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
  }

  private static func once(_ data: Data) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(data)
      continuation.finish()
    }
  }

  private static func body(of exchange: JSONValue, headers: inout [String: String]) -> Data {
    if let json = exchange["json"] {
      headers["content-type"] = headers["content-type"] ?? "application/json"
      return (try? JSONEncoder().encode(json)) ?? Data()
    }
    if let text = exchange["body"]?.stringValue { return Data(text.utf8) }
    return Data()
  }

  private static func record(_ request: URLRequest) -> RecordedRequest {
    let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    var query: [String: String] = [:]
    for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
    var headers: [String: String] = [:]
    for (key, value) in request.allHTTPHeaderFields ?? [:] { headers[key.lowercased()] = value }
    let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    return RecordedRequest(
      method: request.httpMethod?.uppercased() ?? "GET",
      path: components?.path ?? "/",
      query: query,
      headers: headers,
      body: body
    )
  }

  private static func stringMap(_ value: JSONValue?) -> [String: String] {
    var output: [String: String] = [:]
    for (key, item) in value?.objectValue ?? [:] {
      if let text = item.stringValue { output[key] = text }
    }
    return output
  }
}

extension NSLock {
  func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
