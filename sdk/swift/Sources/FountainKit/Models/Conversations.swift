import Foundation

/// How a nullable conversation binding changes during a reapply. Three states,
/// because "leave it alone" and "remove it" are different requests and a plain
/// optional cannot tell them apart.
public enum ConversationBindingUpdate: Sendable, Equatable {
  /// Leave the current binding unchanged.
  case unchanged
  /// Remove the current binding.
  case clear
  /// Replace it with the resource identified by this id, or, for the model,
  /// with this `provider/model_id`.
  case use(String)
}

/// How a conversation's ACP session config options change during a reapply
/// (ADR 0062): the same three states as a binding, over a map of the
/// runtime's option ids to values.
public enum ConversationSessionConfigUpdate: Sendable, Equatable {
  /// Leave the current options unchanged.
  case unchanged
  /// Remove them; the conversation returns to its agent's options.
  case clear
  /// Replace them, for example `["effort": .string("high"), "fast": .bool(true)]`.
  case use([String: JSONValue])
}

/// `POST /api/conversations/{id}/reapply` body.
public struct ConversationReapplyRequest: Sendable, Encodable {
  public var agentID: String?
  public var environment: ConversationBindingUpdate
  public var vault: ConversationBindingUpdate
  /// The model override; `.clear` returns the conversation to its agent's model.
  public var model: ConversationBindingUpdate
  /// The session config options; `.clear` returns to the agent's.
  public var sessionConfig: ConversationSessionConfigUpdate

  public init(
    agentID: String? = nil,
    environment: ConversationBindingUpdate = .unchanged,
    vault: ConversationBindingUpdate = .unchanged,
    model: ConversationBindingUpdate = .unchanged,
    sessionConfig: ConversationSessionConfigUpdate = .unchanged
  ) {
    self.agentID = agentID
    self.environment = environment
    self.vault = vault
    self.model = model
    self.sessionConfig = sessionConfig
  }

  enum CodingKeys: String, CodingKey {
    case agentID = "agent_id"
    case environmentID = "environment_id"
    case vaultID = "vault_id"
    case model = "model"
    case sessionConfig = "session_config"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(agentID, forKey: .agentID)

    switch environment {
    case .unchanged: break
    case .clear: try container.encodeNil(forKey: .environmentID)
    case .use(let id): try container.encode(id, forKey: .environmentID)
    }

    switch vault {
    case .unchanged: break
    case .clear: try container.encodeNil(forKey: .vaultID)
    case .use(let id): try container.encode(id, forKey: .vaultID)
    }

    switch model {
    case .unchanged: break
    case .clear: try container.encodeNil(forKey: .model)
    case .use(let model): try container.encode(model, forKey: .model)
    }

    switch sessionConfig {
    case .unchanged: break
    case .clear: try container.encodeNil(forKey: .sessionConfig)
    case .use(let config): try container.encode(config, forKey: .sessionConfig)
    }
  }
}
