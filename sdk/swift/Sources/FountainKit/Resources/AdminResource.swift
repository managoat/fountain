import Foundation

/// Admin-only surface (`role == admin`; everything here 403s otherwise).
/// User management, cross-tenant sandboxes, the cross-tenant audit feed and
/// the privilege trail.
public struct AdminResource: Sendable {
  let client: APIClient

  /// Search/filter/sort accounts. Page numbers start at 1; this is the
  /// one page-number-paginated endpoint in the API.
  public func users(
    query: String? = nil,
    role: UserRole? = nil,
    verified: Bool? = nil,
    sort: String? = nil,
    dir: String? = nil,
    page: Int = 1,
    perPage: Int = 50
  ) async throws -> AdminUserPage {
    try await client.request(
      .get, "/api/admin/users",
      options: .init(query: [
        "q": query,
        "role": role?.rawValue,
        "verified": verified.map(String.init),
        "sort": sort,
        "dir": dir,
        "page": String(page),
        "per_page": String(perPage),
      ]))
  }

  public func user(_ id: String) async throws -> AdminUser {
    try await client.data(.get, "/api/admin/users/\(id)")
  }

  /// Delete an entire account, tenant data included. The most destructive
  /// call in the API — the UI must confirm loudly.
  public func deleteUser(_ id: String) async throws {
    try await client.send(.delete, "/api/admin/users/\(id)", options: .init(timeout: 120))
  }

  public func setRole(_ id: String, role: UserRole) async throws -> AdminUser {
    try await client.data(.post, "/api/admin/users/\(id)/role", body: ["role": role.rawValue])
  }

  public func setSuspended(_ id: String, _ suspended: Bool) async throws -> AdminUser {
    try await client.data(.post, "/api/admin/users/\(id)/suspend", body: ["suspended": suspended])
  }

  public func setSandboxLimit(_ id: String, limit: Int) async throws -> AdminUser {
    try await client.data(.post, "/api/admin/users/\(id)/sandbox-limit", body: ["limit": limit])
  }

  /// Live sandboxes across all tenants.
  public func sandboxes() async throws -> [AdminSandbox] {
    try await client.data(.get, "/api/admin/sandboxes")
  }

  /// Force-terminate any tenant's sandbox.
  public func reap(sandboxID: String) async throws {
    try await client.send(
      .post, "/api/admin/sandboxes/\(sandboxID)/reap", options: .init(timeout: 120))
  }

  /// Cross-tenant audit events, newest first.
  public func audit(limit: Int = 100) async throws -> [AuditEvent] {
    try await client.data(.get, "/api/admin/audit", options: .init(query: ["limit": String(limit)]))
  }

  /// The privilege trail: admin actions on accounts, newest first.
  public func events(limit: Int = 100) async throws -> [AdminEvent] {
    try await client.data(
      .get, "/api/admin/events", options: .init(query: ["limit": String(limit)]))
  }
}
