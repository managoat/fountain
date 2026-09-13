import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum HTTPMethod: String, Sendable {
  case get = "GET"
  case post = "POST"
  case put = "PUT"
  case patch = "PATCH"
  case delete = "DELETE"
}

/// The absence of a request body, as a type. `Never` would do it from
/// macOS 14, and this client supports macOS 12.
public struct NoBody: Encodable, Sendable {}

/// Per-call options.
public struct RequestOptions: Sendable {
  public var query: [String: String?]
  public var headers: [String: String]
  public var timeout: TimeInterval?
  public var accept: String

  public init(
    query: [String: String?] = [:],
    headers: [String: String] = [:],
    timeout: TimeInterval? = nil,
    accept: String = "application/json"
  ) {
    self.query = query
    self.headers = headers
    self.timeout = timeout
    self.accept = accept
  }
}

/// The one HTTP door for the whole SDK: URL building, auth headers, JSON
/// coding, the `{data: …}` envelope, and error mapping. Resources sit on top.
public struct APIClient: Sendable {
  public let config: FountainConfig
  let transport: any HTTPTransport
  // Per-client seam for deterministic deadline tests; public clients always
  // use Task.sleep, with the timeout starting when Run begins following.
  var sleepForRunDeadline: @Sendable (UInt64) async throws -> Void = {
    try await Task.sleep(nanoseconds: $0)
  }

  static let userAgent = "fountain-sdk-swiftkit/\(fountainKitVersion)"

  public init(config: FountainConfig, transport: any HTTPTransport = URLSessionTransport()) {
    self.config = config
    self.transport = transport
  }

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    // Fountain timestamps are ISO8601 with fractional seconds.
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: value) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: value) { return date }
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "unrecognized date: \(value)"
        ))
    }
    return decoder
  }()

  static let encoder = JSONEncoder()

  // MARK: request building

  func urlRequest(
    _ method: HTTPMethod,
    _ path: String,
    options: RequestOptions,
    bodyData: Data?
  ) throws -> URLRequest {
    guard let apiKey = config.apiKey, !apiKey.isEmpty else {
      throw FountainError.missingAPIKey
    }
    // String concatenation, not appending(path:), so pre-encoded path
    // components (a secret key with a `/`) aren't double-encoded. The
    // base is trimmed first: a configured `https://host/` would otherwise
    // build `//api/...`, which is a protocol-relative URL, not a path.
    let base = config.baseURL.absoluteString.trimmingTrailingSlashes()
    guard var components = URLComponents(string: base + path) else {
      throw FountainError.transport(URLError(.badURL))
    }
    let items = options.query.compactMap { key, value -> URLQueryItem? in
      guard let value, !value.isEmpty else { return nil }
      return URLQueryItem(name: key, value: value)
    }
    if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }

    var request = URLRequest(url: components.url!)
    request.httpMethod = method.rawValue
    request.timeoutInterval = options.timeout ?? config.timeout
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(options.accept, forHTTPHeaderField: "Accept")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    if let parent = config.parentConversationID {
      request.setValue(parent, forHTTPHeaderField: "X-Fountain-Parent-Conversation-Id")
    }
    for (key, value) in options.headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    if let bodyData {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = bodyData
    }
    return request
  }

  // MARK: core calls

  /// Perform a call and return the raw bytes of a 2xx response.
  @discardableResult
  public func raw(
    _ method: HTTPMethod,
    _ path: String,
    body: (some Encodable & Sendable)? = nil as NoBody?,
    options: RequestOptions = RequestOptions()
  ) async throws -> (Data, HTTPURLResponse) {
    let bodyData = try body.map { try Self.encoder.encode($0) }
    let request = try urlRequest(method, path, options: options, bodyData: bodyData)
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.data(for: request)
    } catch let error as FountainError {
      throw error
    } catch {
      throw FountainError.transport(error)
    }
    guard (200..<300).contains(response.statusCode) else {
      throw Self.error(status: response.statusCode, data: data, response: response)
    }
    return (data, response)
  }

  /// Perform a call and decode the whole (unenveloped) response body.
  public func request<T: Decodable & Sendable>(
    _ method: HTTPMethod,
    _ path: String,
    body: (some Encodable & Sendable)? = nil as NoBody?,
    options: RequestOptions = RequestOptions()
  ) async throws -> T {
    let (data, _) = try await raw(method, path, body: body, options: options)
    return try Self.decode(T.self, from: data)
  }

  /// Perform a call and unwrap the `{ "data": … }` envelope.
  public func data<T: Decodable & Sendable>(
    _ method: HTTPMethod,
    _ path: String,
    body: (some Encodable & Sendable)? = nil as NoBody?,
    options: RequestOptions = RequestOptions()
  ) async throws -> T {
    let envelope: Envelope<T> = try await request(method, path, body: body, options: options)
    return envelope.data
  }

  /// Perform a call expecting no meaningful response body.
  public func send(
    _ method: HTTPMethod,
    _ path: String,
    body: (some Encodable & Sendable)? = nil as NoBody?,
    options: RequestOptions = RequestOptions()
  ) async throws {
    _ = try await raw(method, path, body: body, options: options)
  }

  /// Open an SSE stream; the caller consumes raw bytes.
  func openStream(
    _ path: String,
    options: RequestOptions
  ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
    var streamOptions = options
    streamOptions.accept = "text/event-stream"
    streamOptions.timeout = 86_400  // streams are never timed out; reconnect handles drops
    let request = try urlRequest(.get, path, options: streamOptions, bodyData: nil)
    do {
      return try await transport.bytes(for: request)
    } catch let error as FountainError {
      throw error
    } catch {
      throw FountainError.transport(error)
    }
  }

  // MARK: decoding

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try decoder.decode(type, from: data)
    } catch {
      throw FountainError.decoding(error, data: data)
    }
  }

  static func error(status: Int, data: Data, response: HTTPURLResponse) -> FountainError {
    let body = try? decoder.decode(APIErrorBody.self, from: data)
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
    return FountainError.from(status: status, body: body, retryAfter: retryAfter)
  }
}

/// The `{ "data": … }` wrapper most endpoints use. `meta` carries pagination.
struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
  var data: T
  var meta: PageMeta?
}

/// Pagination metadata as returned in list envelopes.
public struct PageMeta: Sendable, Decodable, Equatable {
  public var hasMore: Bool?
  public var nextCursor: Int?
  public var limit: Int?
  public var offset: Int?

  enum CodingKeys: String, CodingKey {
    case hasMore = "has_more"
    case nextCursor = "next_cursor"
    case limit
    case offset
  }
}

/// Wrapper for calls that need the pagination meta alongside the data.
public struct Page<T: Sendable>: Sendable {
  public var items: T
  public var meta: PageMeta?
}
