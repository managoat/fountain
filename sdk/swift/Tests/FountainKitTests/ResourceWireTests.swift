import Foundation
import Testing

@testable import FountainKit

@Suite struct ResourceWireTests {
  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try APIClient.decode(type, from: Data(json.utf8))
  }

  private func body(_ value: some Encodable) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  @Test func agentRetainsTypedEnumsJSONValuesAndNumericPolicy() throws {
    let agent = try decode(
      Agent.self,
      #"{"id":"a1","name":"Agent","runtime":"future_runtime","model":null,"sandbox_provider":"future_provider","permission_policy":{"default":"ask","ask_timeout":0},"skills":[{"name":"guide","content":"hello"}],"mcp_servers":{"local":{"command":"tool"}},"allowed_vault_ids":[],"allowed_inference_credential_ids":["i1"],"inserted_at":"2026-09-15T10:00:00Z"}"#
    )
    #expect(agent.runtime.rawValue == "future_runtime")
    #expect(agent.sandboxProvider?.rawValue == "future_provider")
    #expect(agent.permissionPolicy == ["default": "ask"])
    #expect(agent.permissionPolicyValues?["ask_timeout"] == .number(0))
    #expect(agent.model == nil && agent.insertedAt != nil)
    #expect(agent.allowedVaultIDs == [] && agent.allowedInferenceCredentialIDs == ["i1"])
    #expect(agent.mcpServers?["local"]?["command"] == .string("tool"))
    let skill: Skill? = agent.skills?.first
    #expect(skill?.content == "hello")
    #expect(
      try body(Skill(name: "guide", content: "hello"))
        == .object(["name": .string("guide"), "content": .string("hello")]))
    let version = try decode(
      AgentVersion.self, #"{"id":"av1","agent_id":"a1","version":2,"config":{"model":null}}"#)
    #expect(version.version == 2 && version.config?["model"] == .null && version.insertedAt == nil)
  }

  @Test func inputsPreserveOrderingOmissionNullAndFalse() throws {
    var input = AgentInput(
      name: "", environmentID: "e1", permissionPolicy: ["default": "ask"], skills: [],
      metadata: .object([:]), allowedVaultIDs: [])
    input.permissionPolicyValues?["ask_timeout"] = .number(0)
    input.setNull(.environmentID)
    let encoded = try body(input)
    #expect(encoded["environment_id"] == .null && encoded["name"] == .string(""))
    #expect(encoded["permission_policy"]?["ask_timeout"] == .number(0))
    #expect(encoded["allowed_vault_ids"] == .array([]) && encoded["runtime"] == nil)
    input.environmentID = nil
    #expect(try body(input)["environment_id"] == nil)
    let environment = EnvironmentInput(
      name: "env", packages: .object([:]), envVars: ["EMPTY": ""], setupTimeoutSeconds: 0,
      networkingType: .init(rawValue: "future_network"), repositories: [], metadata: .object([:]))
    #expect(try body(environment)["setup_timeout_seconds"] == .number(0))
    #expect(try body(environment)["networking_type"] == .string("future_network"))
    #expect(
      try body(VaultInput(name: "vault", description: "", metadata: .object([:])))["description"]
        == .string(""))
    var schedule = TeamScheduleInput(
      cron: "* * * * *", prompt: "go", name: "name", oneOff: false, enabled: false)
    schedule.setNull(.name)
    #expect(try body(schedule)["name"] == .null)
    #expect(try body(schedule)["enabled"] == .bool(false))
    schedule.name = nil
    #expect(try body(schedule)["name"] == nil)
  }

  @Test func environmentAndVaultSecretsShareOnePublicModel() throws {
    let environment = try decode(
      Environment.self,
      #"{"id":"e1","name":"env","env_vars":{"A":""},"networking_type":"future_network","packages":{"apt":[]},"repositories":[{"url":"repo"}],"metadata":null}"#
    )
    #expect(environment.envVars == ["A": ""] && environment.metadata == nil)
    #expect(environment.networkingType?.rawValue == "future_network")
    #expect(environment.repositories?.first?["url"] == .string("repo"))
    let vault = try decode(
      Vault.self, #"{"id":"v1","name":"vault","description":null,"secret_count":0}"#)
    #expect(vault.description == nil && vault.secretCount == 0)
    let envSecret = try decode(
      Secret.self,
      #"{"id":"s1","key":"TOKEN","environment_id":"e1","inserted_at":"2026-09-15T10:00:00Z"}"#)
    let vaultSecret = try decode(
      Secret.self, #"{"id":"s2","key":"TOKEN","vault_id":"v1","expires_at":"2026-09-16T10:00:00Z"}"#
    )
    #expect(
      envSecret.environmentID == "e1" && envSecret.vaultID == nil && envSecret.insertedAt != nil)
    #expect(
      vaultSecret.vaultID == "v1" && vaultSecret.environmentID == nil
        && vaultSecret.expiresAt != nil)
    #expect(throws: (any Error).self) { try decode(Secret.self, #"{"id":"s3"}"#) }
  }

  @Test func nestedTeamTypesAndConnectionsKeepUnknownValues() throws {
    let presence = try decode(Teammate.Presence.self, #"{"state":"future_state"}"#)
    let lastTurn = try decode(
      Teammate.LastTurn.self,
      #"{"id":"t1","turn_number":2,"status":"future_status","inserted_at":"2026-09-15T10:00:00Z","usage":{"input":0}}"#
    )
    #expect(presence.state.rawValue == "future_state" && presence.label == nil)
    #expect(lastTurn.status?.rawValue == "future_status" && lastTurn.insertedAt != nil)
    #expect(lastTurn.usage?.input == 0)
    let connection = try decode(
      Connection.self,
      #"{"id":"c1","provider":"github","status":"future_status","scopes":[],"account_email":null}"#)
    #expect(connection.status?.rawValue == "future_status" && connection.scopes == [])
    let provider = try decode(
      ConnectionProvider.self,
      #"{"id":"github","configured":false,"kind":"oauth","platform":false,"redirect_uri":"https://example.test/callback","scopes":[],"token_hosts":[]}"#
    )
    #expect(provider.configured == false && provider.name == nil)
    #expect(provider.redirectURI == "https://example.test/callback")
    #expect(provider.kind == "oauth" && provider.platform == false && provider.tokenHosts == [])
    let schedule = try decode(
      TeamSchedule.self,
      #"{"id":"s1","agent_id":"a1","cron":"* * * * *","prompt":"go","enabled":false,"next_run_at":"2026-09-16T10:00:00Z","last_error":null}"#
    )
    #expect(schedule.enabled == false && schedule.nextRunAt != nil && schedule.lastError == nil)
  }

  @Test func accountApplyAndAdminShapesRetainNamesDatesAndMetadata() throws {
    let key = try decode(
      APIKey.self,
      #"{"id":"k1","name":"key","created_at":"2026-09-15T10:00:00Z","expires_at":null}"#)
    let created = try decode(CreatedAPIKey.self, #"{"id":"k1","key":"fixture-key"}"#)
    #expect(key.createdAt != nil && key.expiresAt == nil && created.name == nil)
    let event = try decode(
      AuditEvent.self,
      #"{"id":1,"action":"vault.secret.write","request_ip":"127.0.0.1","metadata":{"changed":false}}"#
    )
    #expect(event.requestIP == "127.0.0.1" && event.metadata?["changed"] == .bool(false))
    let hit = try decode(SearchHit.self, #"{"kind":"future_kind","conversation_id":"c1"}"#)
    #expect(hit.kind.rawValue == "future_kind" && hit.ts == nil)
    let applied = try decode(
      ApplyResult.self,
      #"{"kind":"Vault","name":"vault","action":"error","errors":{"name":["invalid"]},"secrets":[{"key":"TOKEN","action":"error","errors":["invalid"]}]}"#
    )
    let secret: ApplyResult.SecretResult? = applied.secrets?.first
    #expect(secret?.errors == .array([.string("invalid")]))
    let page = try decode(
      AdminUserPage.self,
      #"{"data":[{"id":"u1","email":"user@example.test","role":"future_role"}],"meta":{"page":1,"per_page":10,"total":11}}"#
    )
    // Each number named, not just `hasMore`: with 1/10/11 a page/perPage swap
    // still computes `hasMore`, so the convenience alone proves no mapping.
    #expect(page.page == 1 && page.perPage == 10 && page.total == 11)
    #expect(page.hasMore && page.users.first?.role?.rawValue == "future_role")
    let lastPage = try decode(
      AdminUserPage.self, #"{"data":[],"meta":{"page":2,"per_page":10,"total":11}}"#)
    #expect(lastPage.hasMore == false && lastPage.users.isEmpty)
    let sandbox = try decode(
      AdminSandbox.self, #"{"id":"s1","status":"future_status","provider":"future_provider"}"#)
    #expect(sandbox.status?.rawValue == "future_status")
    let admin = try decode(
      AdminEvent.self,
      #"{"event_type":"future_event","metadata":{"count":0},"inserted_at":"2026-09-15T10:00:00Z"}"#)
    #expect(admin.insertedAt != nil && admin.metadata?["count"] == .number(0))
  }

  /// An older server omits keys this SDK now exposes. The resource pins in the
  /// generator's OPTIONAL_COMPAT decode from their absence here, so dropping one
  /// fails here rather than at a consumer's whole response. Sandbox and runner
  /// pins are covered the same way in SandboxWireTests. This is not the whole
  /// table: when you add a pin, add the omission that proves it, because a pin
  /// whose key some fixture still supplies can be deleted with every gate green.
  ///
  /// It is also not what decides whether a property needs a pin at all — that is
  /// the generator's own compatibility guard, because a fixture list only covers
  /// the types someone remembered. `Teammate` is here because it was the type
  /// nobody did (#2284).
  @Test func payloadsFromAnOlderServerStillDecode() throws {
    // The second entry and the empty sandbox_providers object decode the nested
    // types with every pinned key absent; a supplied key proves nothing here.
    let catalog = try decode(
      Catalog.self,
      #"{"runtimes":["claude"],"mcp_servers":[{"slug":"m1"},{}],"sandbox_providers":{}}"#)
    #expect(catalog.firstRequest == nil && catalog.apps == nil && catalog.models == nil)
    #expect(catalog.packageManagers == nil)
    #expect(catalog.sandboxProviders?.default == nil)
    #expect(catalog.sandboxProviders?.enabled == nil)
    #expect(catalog.mcpServers?.first?.slug == "m1")
    #expect(catalog.mcpServers?.first?.verifiedOn == nil && catalog.mcpServers?.first?.dcr == nil)
    #expect(catalog.mcpServers?.first?.name == nil && catalog.mcpServers?.first?.url == nil)
    #expect(catalog.mcpServers?.last?.slug == nil)
    let bareCatalog = try decode(Catalog.self, "{}")
    #expect(bareCatalog.firstRequest == nil && bareCatalog.sandboxProviders == nil)
    #expect(bareCatalog.mcpServers == nil && bareCatalog.runtimes == nil)

    let provider = try decode(
      ConnectionProvider.self,
      #"{"id":"github","name":"GitHub","slug":"github","configured":true,"env_key":"GITHUB_TOKEN","mcp_url":"https://mcp.example.test","connect_url":"https://connect.example.test"}"#
    )
    #expect(provider.configured == true && provider.mcpURL == "https://mcp.example.test")
    #expect(provider.kind == nil && provider.platform == nil && provider.redirectURI == nil)
    #expect(provider.scopes == nil && provider.tokenHosts == nil)
    let bareProvider = try decode(ConnectionProvider.self, #"{"id":"github"}"#)
    #expect(bareProvider.name == nil && bareProvider.slug == nil)
    #expect(bareProvider.configured == nil && bareProvider.envKey == nil)
    #expect(bareProvider.connectURL == nil)

    let connection = try decode(Connection.self, #"{"id":"c1","provider":"github"}"#)
    #expect(connection.scopes == nil && connection.status == nil && connection.envKey == nil)
    let key = try decode(APIKey.self, #"{"id":"k1","name":"key"}"#)
    #expect(key.createdAt == nil && key.prefix == nil)
    let schedule = try decode(
      TeamSchedule.self, #"{"id":"s1","agent_id":"a1","cron":"* * * * *","prompt":"go"}"#)
    #expect(schedule.enabled == nil && schedule.oneOff == nil)

    // `role` and `email_verified` are required by the contract and pinned,
    // because every AuthMe this SDK has published had them Optional. The
    // `onboarding_state` key is here because a server older than #1393 still
    // sends it and this SDK no longer has the property: an unknown key is
    // ignored, a missing pinned one would not be.
    let me = try decode(
      AuthMe.self,
      #"{"id":"u1","email":"user@example.test","onboarding_state":"completed"}"#)
    #expect(me.id == "u1" && me.email == "user@example.test")
    #expect(me.role == nil && me.emailVerified == nil)
    #expect(me.comped == nil && me.brokered == nil && me.expiresAt == nil)
    #expect(me.connectionsEnabled == nil && me.connectionsManageable == nil)
    #expect(me.onboardingCompleted == nil)

    // Four public TeamResource methods return this, and a missing key fails all
    // of them, not one property. The payload carries only what the contract
    // requires of Teammate, Agent and Conversation; presence.label is pinned and
    // omitted here to prove its pin too.
    let teammate = try decode(
      Teammate.self,
      #"""
      {"agent":{"id":"a1","name":"agent","runtime":"acp"},"agent_id":"a1",
       "conversation":{"id":"c1","runtime":"acp","status":"idle"},"name":"agent",
       "presence":{"state":"online"},"unread":false}
      """#
    )
    #expect(teammate.id == "a1" && teammate.name == "agent" && teammate.unread == false)
    #expect(teammate.presence.state == .online && teammate.presence.label == nil)
    #expect(teammate.usageTotal == nil && teammate.lastTurn == nil && teammate.preview == nil)
    #expect(teammate.agent.model == nil && teammate.conversation.title == nil)
  }
}
