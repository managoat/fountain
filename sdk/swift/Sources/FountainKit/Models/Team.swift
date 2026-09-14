import Foundation

/// A hired agent: the roster row on `/api/team`.
public struct Teammate: Sendable, Decodable, Identifiable, Hashable {
  public var agentID: String
  public var name: String
  public var agent: Agent
  public var conversation: Conversation
  public var presence: Presence
  public var unread: Bool
  public var usageTotal: Usage?
  public var lastTurn: LastTurn?
  public var preview: Preview?

  public var id: String { agentID }

  public struct Presence: Sendable, Decodable, Hashable {
    public var state: PresenceState
    public var label: String?
  }

  public struct LastTurn: Sendable, Decodable, Hashable {
    public var id: String?
    public var turnNumber: Int?
    public var prompt: String?
    public var status: TurnStatus?
    public var insertedAt: Date?
    public var usage: Usage?

    enum CodingKeys: String, CodingKey {
      case id, prompt, status, usage
      case turnNumber = "turn_number"
      case insertedAt = "inserted_at"
    }
  }

  public struct Preview: Sendable, Decodable, Hashable {
    /// `you | them | typing`.
    public var kind: String?
    public var text: String?
  }

  enum CodingKeys: String, CodingKey {
    case name, agent, conversation, presence, unread, preview
    case agentID = "agent_id"
    case usageTotal = "usage_total"
    case lastTurn = "last_turn"
  }
}

/// A cron-driven prompt to a teammate. `cron` is 5 fields, UTC.
public struct TeamSchedule: Sendable, Decodable, Identifiable, Hashable {
  public var id: String
  public var agentID: String
  public var name: String?
  public var cron: String
  public var prompt: String
  public var oneOff: Bool?
  public var enabled: Bool?
  public var nextRunAt: Date?
  public var lastRunAt: Date?
  public var lastConversationID: String?
  public var lastError: String?
  public var insertedAt: Date?
  public var updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, name, cron, prompt, enabled
    case agentID = "agent_id"
    case oneOff = "one_off"
    case nextRunAt = "next_run_at"
    case lastRunAt = "last_run_at"
    case lastConversationID = "last_conversation_id"
    case lastError = "last_error"
    case insertedAt = "inserted_at"
    case updatedAt = "updated_at"
  }
}

public struct TeamScheduleInput: Sendable, Encodable {
  public var cron: String?
  public var prompt: String?
  public var name: String?
  public var oneOff: Bool?
  public var enabled: Bool?

  public init(
    cron: String? = nil,
    prompt: String? = nil,
    name: String? = nil,
    oneOff: Bool? = nil,
    enabled: Bool? = nil
  ) {
    self.cron = cron
    self.prompt = prompt
    self.name = name
    self.oneOff = oneOff
    self.enabled = enabled
  }

  enum CodingKeys: String, CodingKey {
    case cron, prompt, name, enabled
    case oneOff = "one_off"
  }
}
