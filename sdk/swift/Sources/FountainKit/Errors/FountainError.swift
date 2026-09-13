import Foundation

/// The Fountain API error body: `{"error": code, "message": ..., "errors": {...},
/// "upgrade_url": ..., "active_sandboxes": ..., "limit": ...}`.
/// `Retry-After` arrives as a response header, not in the body.
public struct APIErrorBody: Sendable, Equatable {
  /// The machine-readable code (the body's `error` field). Branch on this.
  public var code: String?
  public var message: String?
  /// Validation errors: field → messages. A bare string becomes a one-element array.
  public var fieldErrors: [String: [String]]
  public var upgradeURL: String?
  public var activeSandboxes: Int?
  public var limit: Int?
  /// The HTTP status this body arrived with, stamped by the client — the
  /// wire puts it on the response, not in the body, and a code that
  /// outranks its status (`conversation_busy` on a 400) would otherwise
  /// lose it.
  public var httpStatus: Int?

  public init(
    code: String? = nil,
    message: String? = nil,
    fieldErrors: [String: [String]] = [:],
    upgradeURL: String? = nil,
    activeSandboxes: Int? = nil,
    limit: Int? = nil,
    httpStatus: Int? = nil
  ) {
    self.code = code
    self.message = message
    self.fieldErrors = fieldErrors
    self.upgradeURL = upgradeURL
    self.activeSandboxes = activeSandboxes
    self.limit = limit
    self.httpStatus = httpStatus
  }
}

extension APIErrorBody: Decodable {
  enum CodingKeys: String, CodingKey {
    case code = "error"
    case message
    case reason
    case errors
    case upgradeURL = "upgrade_url"
    case activeSandboxes = "active_sandboxes"
    case limit
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try? container.decodeIfPresent(String.self, forKey: .code)
    message = try? container.decodeIfPresent(String.self, forKey: .message)
    // Auth failures invert the convention: `error` is prose, `reason` is
    // the machine code (`api_key_invalid`, `api_key_expired`, ...).
    if let reason = try? container.decodeIfPresent(String.self, forKey: .reason) {
      message = message ?? code
      code = reason
    }
    upgradeURL = try? container.decodeIfPresent(String.self, forKey: .upgradeURL)
    activeSandboxes = try? container.decodeIfPresent(Int.self, forKey: .activeSandboxes)
    limit = try? container.decodeIfPresent(Int.self, forKey: .limit)
    httpStatus = nil
    // `errors` values may be a string or an array of strings per field.
    if let map = try? container.decodeIfPresent([String: [String]].self, forKey: .errors) {
      fieldErrors = map
    } else if let map = try? container.decodeIfPresent([String: String].self, forKey: .errors) {
      fieldErrors = map.mapValues { [$0] }
    } else {
      fieldErrors = [:]
    }
  }
}

/// Server codes that are worth retrying after a delay.
let retryableCodes: Set<String> = [
  "conversation_busy", "provisioning", "sprite_probe_failed",
  "sandbox_quota_exceeded", "sandbox_at_capacity", "rate_limited",
]

/// Every failure FountainKit can produce. Branch on these — and for API
/// errors, on the server `code` — never on raw HTTP status.
public enum FountainError: Error, Sendable {
  /// The network layer failed before a response arrived.
  case transport(any Error)
  /// A response body did not decode as expected.
  case decoding(any Error, data: Data)
  /// No API key was configured.
  case missingAPIKey
  /// A base URL was named that is not an absolute http(s) URL.
  case invalidBaseURL(String)
  /// 401 — the key is missing, expired or revoked.
  case unauthorized(APIErrorBody?)
  /// `conversation_busy` — queue the message locally, flush on turn/done.
  case conversationBusy(APIErrorBody)
  /// `provisioning`, `sprite_probe_failed`, `fleet_full` — retry after `retryAfter` seconds.
  case notReady(APIErrorBody, retryAfter: Double?)
  /// `sandbox_quota_exceeded` (429) — carries active count and limit.
  case quotaExceeded(APIErrorBody)
  /// `insufficient_credits` / `subscription_required` (402) — carries the top-up URL.
  case insufficientCredits(APIErrorBody, upgradeURL: String?)
  /// 422 — per-field validation messages.
  case validation(APIErrorBody)
  /// 404 for the addressed resource.
  case notFound(APIErrorBody?)
  /// 429 with no more specific code.
  case rateLimited(APIErrorBody?, retryAfter: Double?)
  /// A name-or-id lookup failed (client-side).
  case resolution(String)
  /// A followed turn outran its client-side deadline. The turn is still
  /// running in the sandbox; `partialText` is what it had said by then.
  case timedOut(partialText: String)
  /// Any other API error; `code` and `status` carry the truth.
  case api(APIErrorBody?, status: Int)

  /// The server `code`, when one was returned.
  public var code: String? { body?.code }

  /// The HTTP status behind this error, when there was a response.
  public var status: Int? {
    switch self {
    case .transport, .decoding, .missingAPIKey, .invalidBaseURL, .resolution, .timedOut:
      return nil
    case .api(let body, let status):
      return body?.httpStatus ?? status
    default:
      break
    }
    // A code that outranks its status carries the real one on the body;
    // the constants are the status each case is defined by.
    if let stamped = body?.httpStatus { return stamped }
    switch self {
    case .unauthorized: return 401
    case .insufficientCredits: return 402
    case .notFound: return 404
    case .validation: return 422
    case .quotaExceeded, .rateLimited: return 429
    default: return nil
    }
  }

  /// The error body the server sent, when it sent one.
  public var body: APIErrorBody? {
    switch self {
    case .transport, .decoding, .missingAPIKey, .invalidBaseURL, .resolution, .timedOut: nil
    case .conversationBusy(let body), .notReady(let body, _), .quotaExceeded(let body),
      .insufficientCredits(let body, _), .validation(let body):
      body
    case .unauthorized(let body), .notFound(let body), .rateLimited(let body, _),
      .api(let body, _):
      body
    }
  }

  /// Seconds the server asked us to wait, from `Retry-After`.
  public var retryAfter: Double? {
    switch self {
    case .notReady(_, let after), .rateLimited(_, let after): after
    default: nil
    }
  }

  /// Per-field validation messages; empty for everything but a 422.
  public var fieldErrors: [String: [String]] { body?.fieldErrors ?? [:] }

  /// Whether waiting and retrying can help.
  public var isRetryable: Bool {
    switch self {
    case .notReady, .quotaExceeded, .rateLimited: true
    case .conversationBusy: true
    case .api(let body, let status):
      (body?.code).map(retryableCodes.contains) == true || (500..<600).contains(status)
    default: false
    }
  }
}

extension FountainError {
  /// Map a non-2xx response to a typed error. Codes win over status.
  static func from(status: Int, body rawBody: APIErrorBody?, retryAfter: Double? = nil)
    -> FountainError
  {
    var body = rawBody
    body?.httpStatus = status
    if let body {
      switch body.code {
      case "conversation_busy":
        return .conversationBusy(body)
      case "provisioning", "sprite_probe_failed", "sandbox_probe_failed",
        "fleet_full", "runner_offline", "sandbox_unavailable":
        return .notReady(body, retryAfter: retryAfter)
      case "sandbox_quota_exceeded":
        return .quotaExceeded(body)
      case "insufficient_credits", "subscription_required":
        return .insufficientCredits(body, upgradeURL: body.upgradeURL)
      default:
        break
      }
    }
    switch status {
    case 401: return .unauthorized(body)
    case 402: return .insufficientCredits(body ?? APIErrorBody(), upgradeURL: body?.upgradeURL)
    case 404: return .notFound(body)
    case 422: return .validation(body ?? APIErrorBody())
    case 429: return .rateLimited(body, retryAfter: retryAfter)
    default: return .api(body, status: status)
    }
  }
}

extension FountainError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .transport(let error):
      return "network failure: \(error.localizedDescription)"
    case .decoding(let error, _):
      return "unexpected response shape: \(error)"
    case .missingAPIKey:
      return "No Fountain API key. Add one in Settings."
    case .invalidBaseURL(let value):
      return "\(value) is not a server address. Include the scheme, as in https://managoat.com."
    case .unauthorized(let body):
      return body?.message ?? "Unauthorized — check the API key."
    case .conversationBusy(let body):
      return body.message ?? "The conversation is mid-turn."
    case .notReady(let body, let after):
      let wait = after.map { " Retry in \(Int($0))s." } ?? ""
      return (body.message ?? "The computer is still starting.") + wait
    case .quotaExceeded(let body):
      return body.message ?? "Sandbox quota exceeded."
    case .insufficientCredits(let body, _):
      return body.message ?? "The account is out of credit."
    case .validation(let body):
      if body.fieldErrors.isEmpty { return body.message ?? "The request was rejected." }
      return body.fieldErrors
        .map { "\($0.key): \($0.value.joined(separator: ", "))" }
        .sorted()
        .joined(separator: "; ")
    case .notFound(let body):
      return body?.message ?? "Not found — wrong id, or it belongs to another account."
    case .rateLimited(let body, _):
      return body?.message ?? "Rate limited."
    case .resolution(let message):
      return message
    case .timedOut(let partial):
      let said = partial.isEmpty ? "" : " It had said: \(partial)"
      return "The turn outran the time allowed; it is still running." + said
    case .api(let body, let status):
      return body?.message ?? body?.code ?? "HTTP \(status)"
    }
  }
}
