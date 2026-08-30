import Foundation
import Testing

let repositoryRoot = URL(filePath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

func jsonObject(_ output: String) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
}

func fixtureContents(_ path: String) throws -> String {
  try String(
    contentsOf: repositoryRoot.appending(path: "Tests/Fixtures/\(path)"),
    encoding: .utf8
  )
}
