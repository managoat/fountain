import Foundation
import FountainKit

let client = FountainClient(config: FountainConfig(
  baseURL: URL(string: ProcessInfo.processInfo.environment["FOUNTAIN_BASE_URL"]!)!, apiKey: "fixture"))
// futureFlag exists only in the temporary generated model for this probe.
var request = ConversationCreateRequest(
  agentID: "11111111-1111-1111-1111-111111111111", prompt: "fixture", title: "",
  images: [], fresh: false, futureFlag: false, labels: [:])
request.setNull(.vaultID)
request.permissionPolicyValues = ["ask_timeout": .number(0)]
do {
  _ = try await client.runRequest(request, timeout: 5).value()
  fatalError("fixture create should stop the run")
} catch let error as FountainError {
  precondition(error.status == 422 && error.code == "fixture_stop")
}
let conversation = try await client.conversations.get("c1")
precondition(conversation.futureFlag == false && conversation.sandbox == nil)
