### Changed

- Swift SDK: `Catalog.sandboxAPIAccess` is now `[SandboxAPIAccess]?` rather
  than `[String]?`, matching `Conversation.sandboxAPIAccess`, which was already
  typed. Comparing an element to a bare `String` no longer compiles; a string
  literal still does, because `SandboxAPIAccess` is `ExpressibleByStringLiteral`
  (#2277).

### Fixed

- Swift SDK: three generator shapes that retyped a field in silence now fail
  generation and ask for an explicit decision — an inline object whose
  synthesized name collides with a real contract schema (the field used to take
  the unrelated schema's type), a node declaring both `additionalProperties` and
  `properties` (the declared properties used to be discarded for
  `[String: JSONValue]`), and an array of enum strings with no item type named
  (it used to lose the typing its scalar sibling kept). None was reachable on
  the current contract; each is now a generation-time error with a test (#2277).
