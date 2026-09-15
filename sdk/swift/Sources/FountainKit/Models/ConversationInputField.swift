/// Internal storage for the three wire states of an optional request field.
/// Public properties remain Optional for source compatibility.
enum ConversationInputField<Value: Encodable & Sendable>: Sendable {
  case omitted
  case null
  case value(Value)

  var value: Value? {
    if case .value(let value) = self { return value }
    return nil
  }

  func encode<Key: CodingKey>(
    into container: inout KeyedEncodingContainer<Key>, forKey key: Key
  ) throws {
    switch self {
    case .omitted: break
    case .null: try container.encodeNil(forKey: key)
    case .value(let value): try container.encode(value, forKey: key)
    }
  }
}

extension ConversationInputField: Equatable where Value: Equatable {}
extension ConversationInputField: Hashable where Value: Hashable {}

extension ConversationInputField where Value: Decodable {
  static func decode<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>, forKey key: Key
  ) throws -> Self {
    guard container.contains(key) else { return .omitted }
    if try container.decodeNil(forKey: key) { return .null }
    return .value(try container.decode(Value.self, forKey: key))
  }
}

/// A request cannot be followed as a run (blank prompt or queued creation).
public struct ConversationRunInputError: Error, Sendable {
  public let message: String
}
