import Foundation
import FountainKit

let client = FountainClient(config: FountainConfig(
  baseURL: URL(string: ProcessInfo.processInfo.environment["FOUNTAIN_BASE_URL"]!)!, apiKey: "fixture"))
// These object models exist only in the temporary generated contract.
// This separate module proves their initializers are public.
func checkEncoding<T: Encodable>(_ value: T, _ expected: JSONValue) throws {
  let actual = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  precondition(actual == expected)
}

var detail = FutureDetail(enabled: false)
detail.setNull(.enabled)
detail.setNull(.omitted)
detail.omitted = nil
try checkEncoding(detail, .object(["enabled": .null]))
let decodedNull = try JSONDecoder().decode(FutureDetail.self, from: Data(#"{"enabled":null}"#.utf8))
let decodedOmitted = try JSONDecoder().decode(FutureDetail.self, from: Data("{}".utf8))
let decodedValue = try JSONDecoder().decode(FutureDetail.self, from: Data(#"{"enabled":false}"#.utf8))
precondition(decodedNull == detail)
try checkEncoding(decodedNull, .object(["enabled": .null]))
try checkEncoding(decodedOmitted, .object([:]))
try checkEncoding(decodedValue, .object(["enabled": .bool(false)]))
precondition(Set([decodedNull, decodedOmitted, decodedValue]).count == 3)
var changed = decodedNull
changed.enabled = true
try checkEncoding(changed, .object(["enabled": .bool(true)]))
changed.enabled = nil
precondition(changed == decodedOmitted)

var nested = ConversationCreateRequestFutureOptionsNested(label: "")
nested.setNull(.label)
var request = ConversationCreateRequest(
  agentID: "11111111-1111-1111-1111-111111111111", prompt: "fixture", title: "",
  images: [], fresh: false,
  futureOptions: .init(
    byName: ["first": .init(detail: decodedOmitted)], enabled: false,
    items: [.init(detail: .init(enabled: true))], nested: nested,
    selected: .init(detail: detail)),
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
precondition(conversation.futureOptions?.nested?.label == nil)
precondition(conversation.futureOptions?.nested?.omitted == nil)
precondition(conversation.futureOptions?.selected?.detail == decodedNull)
precondition(conversation.futureOptions?.items?.first?.detail?.enabled == true)
precondition(conversation.futureOptions?.byName?["first"]?.detail == decodedOmitted)
try checkEncoding(conversation.futureOptions!.selected!.detail!, .object(["enabled": .null]))
