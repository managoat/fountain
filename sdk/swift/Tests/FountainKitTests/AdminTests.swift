import Foundation
import Testing

@testable import FountainKit

@Suite("Admin resource")
struct AdminTests {
  @Test func usersPageDecodesPageNumberMeta() async throws {
    let transport = FakeTransport(
      json: #"""
        {"data": [
            {"id": "u1", "email": "a@example.com", "role": "admin", "suspended": false,
             "active_sandboxes": 2,
             "max_concurrent_sandboxes": 5, "sandbox_limit_override": 10}
        ], "meta": {"page": 1, "per_page": 50, "total": 120}}
        """#)
    let page = try await FountainClient.fake(transport).admin.users(
      query: "example", role: .admin, verified: true, page: 1, perPage: 50
    )

    #expect(page.users.count == 1)
    #expect(page.users[0].email == "a@example.com")
    #expect(page.users[0].role == .admin)
    #expect(page.users[0].sandboxLimitOverride == 10)
    #expect(page.page == 1)
    #expect(page.total == 120)
    #expect(page.hasMore)

    let url = try #require(transport.lastRequest?.url)
    #expect(url.path == "/api/admin/users")
    let query = try #require(url.query)
    #expect(query.contains("q=example"))
    #expect(query.contains("role=admin"))
    #expect(query.contains("verified=true"))
    #expect(query.contains("per_page=50"))
  }

  @Test func lastPageHasNoMore() throws {
    let json = #"{"data": [], "meta": {"page": 3, "per_page": 50, "total": 120}}"#
    let page = try APIClient.decode(AdminUserPage.self, from: Data(json.utf8))
    #expect(!page.hasMore)
  }

  @Test func mutationsPostTheRightBodiesAndUnwrap() async throws {
    let userJSON = #"{"data": {"id": "u1", "email": "a@example.com", "suspended": true}}"#
    let transport = FakeTransport([
      .init(json: userJSON),
      .init(json: userJSON),
    ])
    let client = FountainClient.fake(transport)

    let suspended = try await client.admin.setSuspended("u1", true)
    #expect(suspended.suspended == true)
    var request = try #require(transport.lastRequest)
    #expect(request.url?.path == "/api/admin/users/u1/suspend")
    #expect(request.httpMethod == "POST")
    var body = try #require(request.httpBody.map { String(decoding: $0, as: UTF8.self) })
    #expect(body == #"{"suspended":true}"#)

    _ = try await client.admin.setSandboxLimit("u1", limit: 3)
    request = try #require(transport.lastRequest)
    #expect(request.url?.path == "/api/admin/users/u1/sandbox-limit")
    body = try #require(request.httpBody.map { String(decoding: $0, as: UTF8.self) })
    #expect(body == #"{"limit":3}"#)
  }

  @Test func reapPostsToTheSandbox() async throws {
    let transport = FakeTransport(json: #"{"data": {"id": "sb1", "status": "terminated"}}"#)
    try await FountainClient.fake(transport).admin.reap(sandboxID: "sb1")
    let request = try #require(transport.lastRequest)
    #expect(request.url?.path == "/api/admin/sandboxes/sb1/reap")
    #expect(request.httpMethod == "POST")
  }

  @Test func privilegeTrailDecodes() async throws {
    let transport = FakeTransport(
      json: #"""
        {"data": [{"id": 7, "event_type": "admin.account.suspended",
                   "actor_user_id": "u9", "target_user_id": "u1",
                   "inserted_at": "2026-08-31T12:00:00Z"}]}
        """#)
    let events = try await FountainClient.fake(transport).admin.events()
    #expect(events.count == 1)
    #expect(events[0].eventType == "admin.account.suspended")
    #expect(events[0].actorUserID == "u9")
    #expect(events[0].targetUserID == "u1")
  }
}
