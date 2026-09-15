import Foundation
import FountainKit

let client = FountainClient(config: FountainConfig(
  baseURL: URL(string: ProcessInfo.processInfo.environment["FOUNTAIN_BASE_URL"]!)!, apiKey: "fixture"))
// These object models exist only in the temporary generated contract.
// This separate module proves their initializers are public.
var request = ConversationCreateRequest(
  agentID: "11111111-1111-1111-1111-111111111111", prompt: "fixture", title: "",
  images: [], fresh: false,
  futureOptions: .init(
    byName: ["first": .init(detail: .init(enabled: false))], enabled: false,
    items: [.init(detail: .init(enabled: true))], nested: .init(label: ""),
    selected: .init(detail: .init(enabled: false))),
  labels: [:])
request.setNull(.vaultID)
request.permissionPolicyValues = ["ask_timeout": .number(0)]
do {
  _ = try await client.runRequest(request, timeout: 5).value()
  fatalError("fixture create should stop the run")
} catch let error as FountainError {
  precondition(error.status == 422 && error.code == "fixture_stop")
}
let conversation = try await client.conversations.get("c1")
precondition(conversation.sandbox == nil)
precondition(conversation.futureOptions?.enabled == false)
precondition(conversation.futureOptions?.nested?.label == "")
precondition(conversation.futureOptions?.nested?.omitted == nil)
precondition(conversation.futureOptions?.selected?.detail?.enabled == false)
precondition(conversation.futureOptions?.items?.first?.detail?.enabled == true)
precondition(conversation.futureOptions?.byName?["first"]?.detail?.enabled == false)
