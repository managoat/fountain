import Foundation
import Testing

@testable import FountainKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Exercise the typed entry points, including streams and conveniences that
/// share an operation. The generic request escape hatch accepts arbitrary
/// paths, so it makes no operation claim. Keep this inventory beside new APIs.
private struct TypedOperation: Sendable, CustomTestStringConvertible {
  let operation: String
  let invoke: @Sendable (FountainClient) async throws -> Void
  var testDescription: String { operation }

  init(_ operation: String, _ invoke: @escaping @Sendable (FountainClient) async throws -> Void) {
    self.operation = operation
    self.invoke = invoke
  }

  static let all: [TypedOperation] = [
    TypedOperation("GET /api/agents") { _ = try await $0.agents.list() },
    TypedOperation("GET /api/agents/{id}") { _ = try await $0.agents.get("id") },
    TypedOperation("POST /api/agents") { _ = try await $0.agents.create(AgentInput()) },
    TypedOperation("PATCH /api/agents/{id}") { _ = try await $0.agents.update("id", AgentInput()) },
    TypedOperation("DELETE /api/agents/{id}") { _ = try await $0.agents.delete("id") },
    TypedOperation("GET /api/environments") { _ = try await $0.environments.list() },
    TypedOperation("GET /api/environments/{id}") { _ = try await $0.environments.get("id") },
    TypedOperation("POST /api/environments") {
      _ = try await $0.environments.create(EnvironmentInput())
    },
    TypedOperation("PATCH /api/environments/{id}") {
      _ = try await $0.environments.update("id", EnvironmentInput())
    },
    TypedOperation("DELETE /api/environments/{id}") { _ = try await $0.environments.delete("id") },
    TypedOperation("GET /api/vaults") { _ = try await $0.vaults.list() },
    TypedOperation("GET /api/vaults/{id}") { _ = try await $0.vaults.get("id") },
    TypedOperation("POST /api/vaults") { _ = try await $0.vaults.create(VaultInput()) },
    TypedOperation("PATCH /api/vaults/{id}") { _ = try await $0.vaults.update("id", VaultInput()) },
    TypedOperation("DELETE /api/vaults/{id}") { _ = try await $0.vaults.delete("id") },
    TypedOperation("GET /api/agents/{id}/versions") { _ = try await $0.agents.versions("id") },
    TypedOperation("GET /api/agents/{id}/versions/{version}") {
      _ = try await $0.agents.version("id", 1)
    },
    TypedOperation("GET /api/agents/{id}/avatar") { _ = try await $0.agents.avatar("id") },
    TypedOperation("GET /api/environments/{environment_id}/secrets") {
      _ = try await $0.environments.secrets("id")
    },
    TypedOperation("POST /api/environments/{environment_id}/secrets") {
      _ = try await $0.environments.setSecret("id", key: "key", value: "value")
    },
    TypedOperation("DELETE /api/environments/{environment_id}/secrets/{id}") {
      _ = try await $0.environments.deleteSecret("id", key: "key")
    },
    TypedOperation("GET /api/vaults/{vault_id}/secrets") { _ = try await $0.vaults.secrets("id") },
    TypedOperation("POST /api/vaults/{vault_id}/secrets") {
      _ = try await $0.vaults.setSecret("id", key: "key", value: "value")
    },
    TypedOperation("DELETE /api/vaults/{vault_id}/secrets/{id}") {
      _ = try await $0.vaults.deleteSecret("id", key: "key")
    },
    TypedOperation("GET /api/conversations") { _ = try await $0.conversations.list() },
    TypedOperation("GET /api/conversations/{id}") { _ = try await $0.conversations.get("id") },
    TypedOperation("POST /api/conversations") {
      _ = try await $0.conversations.create(ConversationCreateRequest(agentID: "agent"))
    },
    TypedOperation("DELETE /api/conversations/{id}") {
      _ = try await $0.conversations.delete("id")
    },
    TypedOperation("POST /api/conversations/{conversation_id}/reapply") {
      _ = try await $0.conversations.reapply("id")
    },
    TypedOperation("POST /api/conversations/{conversation_id}/prompts") {
      _ = try await $0.conversations.prompt("id", "hello")
    },
    TypedOperation("POST /api/conversations/{conversation_id}/interrupt") {
      _ = try await $0.conversations.interrupt("id")
    },
    TypedOperation("POST /api/conversations/{conversation_id}/terminate") {
      _ = try await $0.conversations.terminate("id")
    },
    TypedOperation("POST /api/conversations/{conversation_id}/read") {
      _ = try await $0.conversations.markRead("id")
    },
    TypedOperation("GET /api/conversations/{conversation_id}/turns") {
      _ = try await $0.conversations.turns("id")
    },
    TypedOperation("GET /api/conversations/{conversation_id}/tree") {
      _ = try await $0.conversations.tree("id")
    },
    TypedOperation("POST /api/conversations/{conversation_id}/requests/{request_id}") {
      _ = try await $0.conversations.answer("id", requestID: "request", optionID: "allow")
    },
    TypedOperation("GET /api/conversations/{conversation_id}/events") {
      _ = try await $0.conversations.events("id")
    },
    TypedOperation("GET /api/conversations/{conversation_id}/events") {
      _ = try await $0.conversations.history("id")
    },
    TypedOperation("GET /api/conversations/{conversation_id}/turns/{turn_id}/images/{position}") {
      _ = try await $0.conversations.turnImage("id", turnID: "turn", position: 0)
    },
    TypedOperation("GET /api/connections") { _ = try await $0.connections.list() },
    TypedOperation("GET /api/connections/providers") { _ = try await $0.connections.providers() },
    TypedOperation("DELETE /api/connections/{id}") { _ = try await $0.connections.delete("id") },
    TypedOperation("GET /api/team") { _ = try await $0.team.list() },
    TypedOperation("GET /api/team/{agent_id}") { _ = try await $0.team.get("agent") },
    TypedOperation("POST /api/team") { _ = try await $0.team.add("agent") },
    TypedOperation("PATCH /api/team/{agent_id}") {
      _ = try await $0.team.rename("agent", name: "name")
    },
    TypedOperation("DELETE /api/team/{agent_id}") { _ = try await $0.team.remove("agent") },
    TypedOperation("POST /api/team/{agent_id}/messages") {
      _ = try await $0.team.message("agent", "hello")
    },
    TypedOperation("GET /api/team/{agent_id}/conversations") {
      _ = try await $0.team.conversations("agent")
    },
    TypedOperation("POST /api/team/{agent_id}/conversations") {
      _ = try await $0.team.freshConversation("agent")
    },
    TypedOperation("GET /api/team/schedules") { _ = try await $0.team.allSchedules() },
    TypedOperation("GET /api/team/{agent_id}/schedules") {
      _ = try await $0.team.schedules("agent")
    },
    TypedOperation("POST /api/team/{agent_id}/schedules") {
      _ = try await $0.team.createSchedule("agent", TeamScheduleInput())
    },
    TypedOperation("PATCH /api/team/{agent_id}/schedules/{id}") {
      _ = try await $0.team.updateSchedule("agent", "id", TeamScheduleInput())
    },
    TypedOperation("DELETE /api/team/{agent_id}/schedules/{id}") {
      _ = try await $0.team.deleteSchedule("agent", "id")
    },
    TypedOperation("POST /api/team/{agent_id}/schedules/{id}/run") {
      _ = try await $0.team.runSchedule("agent", "id")
    },
    TypedOperation("GET /api/sandboxes") { _ = try await $0.sandboxes.list() },
    TypedOperation("GET /api/sandboxes/{id}") { _ = try await $0.sandboxes.get("id") },
    TypedOperation("DELETE /api/sandboxes/{id}") { _ = try await $0.sandboxes.reset("id") },
    TypedOperation("GET /api/runners") { _ = try await $0.runners.list() },
    TypedOperation("DELETE /api/runners/{id}") { _ = try await $0.runners.delete("id") },
    TypedOperation("GET /api/auth/me") { _ = try await $0.auth.me() },
    TypedOperation("GET /api/auth/api-keys") { _ = try await $0.auth.apiKeys() },
    TypedOperation("POST /api/auth/api-keys") { _ = try await $0.auth.createAPIKey(name: "test") },
    TypedOperation("DELETE /api/auth/api-keys/{id}") { _ = try await $0.auth.revokeAPIKey("id") },
    TypedOperation("POST /api/oauth/revoke") { _ = try await $0.auth.revokeToken() },
    TypedOperation("GET /api/audit") { _ = try await $0.audit.list() },
    TypedOperation("GET /api/search") { _ = try await $0.search.search("hello") },
    TypedOperation("GET /api/catalog") { _ = try await $0.catalog() },
    TypedOperation("POST /api/apply") { _ = try await $0.apply(resources: []) },
    TypedOperation("GET /api/admin/users") { _ = try await $0.admin.users() },
    TypedOperation("GET /api/admin/users/{id}") { _ = try await $0.admin.user("id") },
    TypedOperation("DELETE /api/admin/users/{id}") { _ = try await $0.admin.deleteUser("id") },
    TypedOperation("POST /api/admin/users/{id}/role") {
      _ = try await $0.admin.setRole("id", role: .admin)
    },
    TypedOperation("POST /api/admin/users/{id}/suspend") {
      _ = try await $0.admin.setSuspended("id", true)
    },
    TypedOperation("POST /api/admin/users/{id}/comp") {
      _ = try await $0.admin.setComped("id", true)
    },
    TypedOperation("POST /api/admin/users/{id}/credits") {
      _ = try await $0.admin.grantCredits("id", cents: 100)
    },
    TypedOperation("POST /api/admin/users/{id}/sandbox-limit") {
      _ = try await $0.admin.setSandboxLimit("id", limit: 2)
    },
    TypedOperation("GET /api/admin/sandboxes") { _ = try await $0.admin.sandboxes() },
    TypedOperation("POST /api/admin/sandboxes/{id}/reap") {
      _ = try await $0.admin.reap(sandboxID: "id")
    },
    TypedOperation("GET /api/admin/audit") { _ = try await $0.admin.audit() },
    TypedOperation("GET /api/admin/events") { _ = try await $0.admin.events() },
    TypedOperation("GET /api/conversations/{conversation_id}/stream") {
      for try await _ in $0.conversations.stream("id", StreamRequest(wait: false)) {}
    },
    TypedOperation("GET /api/events/stream") {
      for try await _ in $0.events.stream(StreamRequest(wait: false)) {}
    },
    TypedOperation("GET /api/team/stream") {
      for try await _ in $0.team.stream(StreamRequest(wait: false)) {}
    },
  ]
}

private func contractJSON(_ path: String) throws -> [String: Any] {
  var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  while directory.path != "/" {
    let file = directory.appendingPathComponent("sdk/contract/" + path)
    if FileManager.default.fileExists(atPath: file.path) {
      return try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    directory.deleteLastPathComponent()
  }
  throw NSError(
    domain: "FountainKitContractTests", code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Could not locate sdk/contract/\(path)"])
}

@Suite("FountainKitContractTests")
struct FountainKitContractTests {
  @Test(arguments: TypedOperation.all)
  fileprivate func typedOperationIsClaimed(_ scenario: TypedOperation) async throws {
    let manifest = try contractJSON("manifests/swift.json")
    let claims = try #require(manifest["operations"] as? [String])
    #expect(claims.contains(scenario.operation), "FountainKit operation missing from swift.json")

    let contract = try contractJSON("contract.json")
    let operations = try #require(contract["operations"] as? [String: Any])
    #expect(operations[scenario.operation] != nil, "The API no longer serves this operation")

    // Stop before decoding a response, without inventing model fixtures.
    // A 404 also terminates stream loops without retries or reconnections.
    let transport = FakeTransport(json: #"{"error":"not_found"}"#, status: 404)
    do {
      try await scenario.invoke(FountainClient.fake(transport))
    } catch FountainError.notFound {
      // Expected; avatar() deliberately turns this response into nil.
    }
    #expect(transport.requests.count == 1)
    let request = try #require(transport.lastRequest)
    let parts = scenario.operation.split(separator: " ", maxSplits: 1).map(String.init)
    #expect(request.httpMethod == parts[0])
    let actualPath = try #require(request.url?.path).split(separator: "/").map(String.init)
    let template = parts[1].split(separator: "/").map(String.init)
    #expect(actualPath.count == template.count)
    for (actual, expected) in zip(actualPath, template) {
      if !(expected.hasPrefix("{") && expected.hasSuffix("}")) {
        #expect(actual == expected, "Request path differs from the claimed operation")
      }
    }
  }
}
