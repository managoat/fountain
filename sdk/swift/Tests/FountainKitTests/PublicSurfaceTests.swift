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
    #expect(conversation == "c1" && agent == "a1" && event.kind == EventKind.output)
    #expect(event.stream == LogStream.stdout && event.stageData == nil)

    // The three-state binding API, reachable from outside the module.
    var request = ConversationReapplyRequest(agentID: "a1")
    request.environment = .clear
    request.vault = .use("v1")
    #expect(request.environment == .clear && request.vault == .use("v1"))
    #expect(try JSONEncoder().encode(request).isEmpty == false)
  }
}
