import Foundation

/// `LogEvent` itself is generated from the contract. Two of its properties are
/// not in the contract and come from the generator's `EXTRA_PROPERTIES`: the
/// team and events streams add `conversation_id`, and the team stream adds
/// `agent_id`. The three SSE operations declare `text/event-stream` with a bare
/// string schema, so the frame shape is documented in prose rather than typed.
extension LogEvent {
  /// Decoded stage metadata (the `data` field of a stage event is JSON).
  ///
  /// Computed, which is why it survives here: a Swift extension can add a
  /// computed property to a generated type but never a stored one.
  public var stageData: JSONValue? {
    guard kind == .stage, let data, let bytes = data.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: bytes)
  }
}

/// One parsed block of agent output — what `?blocks=true` folds every runtime
/// dialect into. Open-shaped: unknown keys are preserved in `extra`.
public struct Block: Sendable, Decodable, Hashable {
  public var kind: BlockKind
  public var body: String?
  /// plan only: the full ordered checklist from the wire `body` array.
  public var planEntries: [JSONValue]?
  public var summary: String?
  /// tool_use / permission_request: the tool name.
  public var name: String?
  /// tool_use: the call id; tool_result pairs on `toolID`.
  public var id: String?
  public var toolID: String?
  public var raw: String?
  public var isError: Bool?
  /// permission_request only.
  public var requestID: String?
  public var options: [PermissionOption]?
  /// Everything the known fields didn't claim.
  public var extra: [String: JSONValue]

  enum CodingKeys: String, CodingKey {
    case kind, body, summary, name, id, raw, options
    case toolID = "tool_id"
    case isError = "error"
    case requestID = "request_id"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(BlockKind.self, forKey: .kind)
    body = try? container.decodeIfPresent(String.self, forKey: .body)
    planEntries =
      kind == .plan
      ? try? container.decodeIfPresent([JSONValue].self, forKey: .body) : nil
    summary = try? container.decodeIfPresent(String.self, forKey: .summary)
    name = try? container.decodeIfPresent(String.self, forKey: .name)
    id = try? container.decodeIfPresent(String.self, forKey: .id)
    toolID = try? container.decodeIfPresent(String.self, forKey: .toolID)
    raw = try? container.decodeIfPresent(String.self, forKey: .raw)
    isError = try? container.decodeIfPresent(Bool.self, forKey: .isError)
    requestID = try? container.decodeIfPresent(String.self, forKey: .requestID)
    options = try? container.decodeIfPresent([PermissionOption].self, forKey: .options)

    let known = Set([
      "kind", "body", "summary", "name", "id", "tool_id", "raw", "error", "request_id", "options",
    ])
    let open = try decoder.container(keyedBy: AnyCodingKey.self)
    var extras: [String: JSONValue] = [:]
    for key in open.allKeys where !known.contains(key.stringValue) {
      extras[key.stringValue] = try? open.decode(JSONValue.self, forKey: key)
    }
    extra = extras
  }
}

/// One offered answer to a permission request. Never synthesise one the agent
/// did not offer — the server rejects unknown options.
public struct PermissionOption: Sendable, Decodable, Hashable {
  public var optionID: String?
  /// `allow_once | allow_always | reject_once | reject_always` (open set).
  public var kind: String?
  public var name: String?
  public var extra: [String: JSONValue]

  enum CodingKeys: String, CodingKey {
    case optionID = "optionId"
    case optionIDSnake = "option_id"
    case kind, name
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Both spellings appear in the wild.
    optionID =
      (try? container.decodeIfPresent(String.self, forKey: .optionID))
      ?? (try? container.decodeIfPresent(String.self, forKey: .optionIDSnake))
    kind = try? container.decodeIfPresent(String.self, forKey: .kind)
    name = try? container.decodeIfPresent(String.self, forKey: .name)

    let known = Set(["optionId", "option_id", "kind", "name"])
    let open = try decoder.container(keyedBy: AnyCodingKey.self)
    var extras: [String: JSONValue] = [:]
    for key in open.allKeys where !known.contains(key.stringValue) {
      extras[key.stringValue] = try? open.decode(JSONValue.self, forKey: key)
    }
    extra = extras
  }
}

/// An answerable permission request extracted from a `permission_request`
/// block. `nil` when the block has no request id or no usable option (then
/// it's a notice, not a question).
public struct PermissionRequest: Sendable, Hashable {
  public var requestID: String
  public var summary: String?
  public var toolName: String?
  public var toolID: String?
  public var options: [PermissionOption]

  public init?(block: Block) {
    guard block.kind == .permissionRequest,
      let requestID = block.requestID,
      let options = block.options,
      options.contains(where: { $0.optionID != nil })
    else { return nil }
    self.requestID = requestID
    self.summary = block.summary ?? block.body
    self.toolName = block.name
    self.toolID = block.toolID
    self.options = options
  }
}

struct AnyCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }

  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
