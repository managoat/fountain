import Foundation

/// `/api/admin/users` is the one endpoint with page-number pagination:
/// `meta` is `{page, per_page, total}`, not a cursor.
///
/// The wire keys live in the generated `AdminUserListResponse`; this type is
/// the roster convenience over it — `users` rather than `data`, and `hasMore`
/// computed from the page numbers.
public struct AdminUserPage: Sendable, Decodable {
  public var users: [AdminUser]
  public var page: Int
  public var perPage: Int
  public var total: Int

  public init(from decoder: any Decoder) throws {
    let response = try AdminUserListResponse(from: decoder)
    users = response.data
    page = response.meta.page
    perPage = response.meta.perPage
    total = response.meta.total
  }

  public var hasMore: Bool { page * perPage < total }
}
