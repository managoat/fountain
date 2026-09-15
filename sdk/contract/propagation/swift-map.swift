import Foundation
import Fountain

let fixture = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let client = try Fountain(apiKey: "fixture", baseURL: ProcessInfo.processInfo.environment["FOUNTAIN_BASE_URL"]!)
do {
  _ = try await client.runRequest(fixture["request"]!.objectValue!, timeout: 5, collectEvents: true).value()
  fatalError("fixture create should stop the run")
} catch let error as FountainError {
  precondition(error.status == 422 && error.code == "fixture_stop")
}
let response = try await client.request("GET", "/api/conversations/c1")
precondition(response["data"] == fixture["response"])
