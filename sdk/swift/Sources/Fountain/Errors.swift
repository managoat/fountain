import Foundation

public struct FountainError: Error, CustomStringConvertible, LocalizedError, Sendable {
  public enum Kind: String, Sendable {
    case api, authentication, subscriptionRequired, notFound, validation
    case rateLimit, conversationBusy, notReady, quotaExceeded
    case connection, resolution, timeout
  }

  public let kind: Kind
  public let message: String
  public let status: Int
  public let code: String?
  public let body: JSONValue?
  public let retryAfter: TimeInterval?
  public let conversationID: String?
  public let partialText: String?

  public init(
    _ kind: Kind,
    _ message: String,
    status: Int = 0,
    code: String? = nil,
    body: JSONValue? = nil,
    retryAfter: TimeInterval? = nil,
    conversationID: String? = nil,
    partialText: String? = nil
  ) {
    self.kind = kind
    self.message = message
    self.status = status
    self.code = code
    self.body = body
    self.retryAfter = retryAfter
    self.conversationID = conversationID
    self.partialText = partialText
  }

  public var description: String { message }
  public var errorDescription: String? { message }
  public var retryable: Bool {
    [
      "conversation_busy", "provisioning", "sprite_probe_failed", "sandbox_quota_exceeded",
      "sandbox_at_capacity", "rate_limited",
    ].contains(code)
      || status == 429 || (500..<600).contains(status)
  }

  public var fieldErrors: [String: [String]] {
    guard let errors = body?["errors"]?.objectValue else { return [:] }
    return errors.reduce(into: [:]) { output, pair in
      if let value = pair.value.stringValue {
        output[pair.key] = [value]
      } else if let values = pair.value.arrayValue {
        output[pair.key] = values.compactMap(\.stringValue)
      }
    }
  }

  public var upgradeURL: String? { body?["upgrade_url"]?.stringValue }
  public var activeSandboxes: Int? { body?["active_sandboxes"]?.intValue }
  public var limit: Int? { body?["limit"]?.intValue }
}

func fountainError(
  status: Int, body: JSONValue?, method: String, url: URL, headers: [AnyHashable: Any]
) -> FountainError {
  let code = body?["error"]?.stringValue
  let detail = body?["message"]?.stringValue ?? code
  let kind: FountainError.Kind
  switch code {
  case "conversation_busy": kind = .conversationBusy
  case "provisioning", "sprite_probe_failed", "fleet_full", "sandbox_unavailable": kind = .notReady
  case "sandbox_quota_exceeded": kind = .quotaExceeded
  case "subscription_required", "insufficient_credits": kind = .subscriptionRequired
  default:
    switch status {
    case 401: kind = .authentication
    case 402: kind = .subscriptionRequired
    case 404: kind = .notFound
    case 422: kind = .validation
    case 429: kind = .rateLimit
    default: kind = .api
    }
  }
  let hint: [Int: String] = [
    400: "bad request", 401: "unauthorized — check the API key",
    402: "payment required — the account is out of credit", 403: "forbidden",
    404: "not found", 409: "conflict", 422: "rejected", 429: "rate limited",
    503: "temporarily unavailable",
  ]
  let message = ["HTTP \(status)", hint[status], detail, "(\(method) \(url.absoluteString))"]
    .compactMap { $0 }.joined(separator: " ")
  let retryAfter = headers.first { String(describing: $0.key).lowercased() == "retry-after" }
    .flatMap { TimeInterval(String(describing: $0.value)) }
  return FountainError(
    kind, message, status: status, code: code, body: body, retryAfter: retryAfter)
}
