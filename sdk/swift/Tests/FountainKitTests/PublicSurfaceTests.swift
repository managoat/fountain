// Deliberately NOT `@testable`: every other file in this target imports the
// module that way, so nothing compiled against the public API alone. A
// generated model that loses a property, gains one, or changes optionality
// breaks a consumer at compile time and no test here would have said so
// (#2269). The release workflow builds a real external consumer; this is the
// same question asked per PR, for the families the generation campaign moved.
import Foundation
import FountainKit
import Testing

@Suite("PublicSurfaceTests")
struct PublicSurfaceTests {
  /// Reading each property is the assertion: this file fails to compile if a
  /// name or its optionality changes.
  @Test func migratedModelsKeepTheirPublicProperties() throws {
    let me = try JSONDecoder().decode(
      AuthMe.self, from: Data(#"{"id":"u1","email":"u@example.test"}"#.utf8))
    let role: UserRole? = me.role
    let verified: Bool? = me.emailVerified
    #expect(role == nil && verified == nil && me.id == "u1")

    let page = try JSONDecoder().decode(
      AdminUserPage.self,
      from: Data(#"{"data":[],"meta":{"page":1,"per_page":10,"total":0}}"#.utf8))
    let users: [AdminUser] = page.users
    #expect(users.isEmpty && page.hasMore == false && page.perPage == 10)

    let event = try JSONDecoder().decode(
      LogEvent.self,
      from: Data(
        #"{"kind":"output","stream":"stdout","conversation_id":"c1","agent_id":"a1"}"#.utf8))
    let id: Int? = event.id
    let duration: Int? = event.durationMS
    let conversation: String? = event.conversationID
    let agent: String? = event.agentID
    let blocks: [Block]? = event.blocks
    #expect(id == nil && duration == nil && blocks == nil)

    // PageMeta moved into generation in #2300 and kept its three cursor
    // members Optional; `offset` moved to the search page's own meta.
    let cursor = try JSONDecoder().decode(
      PageMeta.self, from: Data(#"{"has_more":true,"limit":1000,"next_cursor":42}"#.utf8))
    let hasMore: Bool? = cursor.hasMore
    let limit: Int? = cursor.limit
    let nextCursor: Int? = cursor.nextCursor
    #expect(hasMore == true && limit == 1000 && nextCursor == 42)
    let searchMeta = try JSONDecoder().decode(
      SearchResponse.Meta.self, from: Data(#"{"has_more":false,"limit":20,"offset":40}"#.utf8))
    let offset: Int = searchMeta.offset
    #expect(offset == 40 && searchMeta.hasMore == false)
    // `Page` has no public initializer, so a consumer only ever reads one; the
    // two-parameter spelling is what `events`, `audit.list` and `search` return.
    let next: (Page<[LogEvent], PageMeta>) -> Int? = { $0.meta?.nextCursor }
    let offsetOf: (Page<[SearchHit], SearchResponse.Meta>) -> Int? = { $0.meta?.offset }
    #expect(type(of: next) != type(of: offsetOf))
    #expect(conversation == "c1" && agent == "a1" && event.kind == EventKind.output)
    #expect(event.stream == LogStream.stdout && event.stageData == nil)

    // The three-state binding API, reachable from outside the module.
    var request = ConversationReapplyRequest(agentID: "a1")
    request.environment = .clear
    request.vault = .use("v1")
    #expect(request.environment == .clear && request.vault == .use("v1"))
    #expect(try JSONEncoder().encode(request).isEmpty == false)

    // APIErrorBody reads the generated payload since #2324 and keeps every
    // member it published, Optional as before; `reason` is new.
    let refusal = try JSONDecoder().decode(
      APIErrorBody.self,
      from: Data(
        #"{"error":"sandbox_quota_exceeded","message":"m","active_sandboxes":3,"limit":3}"#.utf8))
    let errorCode: String? = refusal.code
    let errorMessage: String? = refusal.message
    let errorReason: String? = refusal.reason
    let fields: [String: [String]] = refusal.fieldErrors
    let upgrade: String? = refusal.upgradeURL
    let active: Int? = refusal.activeSandboxes
    let quota: Int? = refusal.limit
    let status: Int? = refusal.httpStatus
    #expect(errorCode == "sandbox_quota_exceeded" && errorMessage == "m" && errorReason == nil)
    #expect(fields.isEmpty && upgrade == nil && active == 3 && quota == 3 && status == nil)
    // Both initializers are public: the v0.19.0 signature, which a consumer may
    // hold as a function value, and the one that also takes `reason`.
    let makeError = APIErrorBody.init(
      code:message:fieldErrors:upgradeURL:activeSandboxes:limit:httpStatus:)
    let built = makeError("conversation_busy", nil, [:], nil, nil, nil, 400)
    let narrowed = APIErrorBody(code: "broker_unavailable", reason: "timeout")
    #expect(built.code == "conversation_busy" && built.reason == nil && built.httpStatus == 400)
    #expect(narrowed.reason == "timeout" && APIErrorBody() == APIErrorBody(reason: nil))
    let payload = try JSONDecoder().decode(
      APIErrorPayload.self, from: Data(#"{"errors":{"detail":"Not Acceptable"}}"#.utf8))
    let rawCode: String? = payload.error
    let rawErrors: JSONValue? = payload.errors
    #expect(rawCode == nil && rawErrors?["detail"]?.stringValue == "Not Acceptable")
  }
}
