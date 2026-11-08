import Foundation

extension HerdrAdapter {
  package static func parseVersion(_ output: String) -> [Int]? {
    AdapterVersionParser.parse(output, executableLabel: "herdr")
  }

  package func supportedVersion() throws -> String {
    try Self.supportedVersion(executableURL: executableURL, processRunner: processRunner)
  }

  package static func supportedVersion(
    executableURL: URL,
    processRunner: ProcessRunner
  ) throws -> String {
    try AdapterVersionParser.supportedVersion(
      executableURL: executableURL,
      executableLabel: "herdr",
      minimumVersion: Self.minimumVersion,
      processRunner: processRunner,
      invalid: HerdrAdapterError.invalidVersion,
      unsupported: HerdrAdapterError.unsupportedVersion
    )
  }

  package static func serverStatusIsConfirmedStopped(
    _ output: String, expectedSocket: String
  ) -> Bool {
    // Source-qualified 0.8.2–0.9.1 status server --json. Do not infer absence
    // from reload errors, a human-readable substring, or another session/socket.
    struct Flags: Decodable {
      let running: Bool
      let restartNeeded: Bool
      let serverBinaryStale: Bool?

      enum CodingKeys: String, CodingKey {
        case running
        case restartNeeded = "restart_needed"
        case serverBinaryStale = "server_binary_stale"
      }
    }
    let required: Set<String> = [
      "status", "running", "version", "protocol", "capabilities", "compatible",
      "socket", "session", "restart_needed",
    ]
    let allowed = required.union(["endpoint_compatible", "server_binary_stale"])
    let data = Data(output.utf8)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowed),
      object.keys.allSatisfy({ output.components(separatedBy: "\"\($0)\"").count == 2 }),
      object["status"] as? String == "not_running",
      object["socket"] as? String == expectedSocket,
      ["version", "protocol", "capabilities", "compatible", "session"].allSatisfy({
        object[$0] is NSNull
      }),
      object["endpoint_compatible"] == nil || object["endpoint_compatible"] is NSNull,
      let flags = try? JSONDecoder().decode(Flags.self, from: data),
      !flags.running, !flags.restartNeeded,
      object["server_binary_stale"] == nil || flags.serverBinaryStale == false
    else { return false }
    return true
  }

  package static func reloadResponseIsUnambiguousSuccess(_ output: String) -> Bool {
    let requiredFields = ["id", "result", "diagnostics", "status", "type"]
    guard
      requiredFields.allSatisfy({
        output.components(separatedBy: "\"\($0)\"").count == 2
      })
    else { return false }
    guard let data = output.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["id", "result"],
      object["id"] as? String == "cli:server:reload-config",
      let result = object["result"] as? [String: Any],
      Set(result.keys) == ["diagnostics", "status", "type"],
      result["type"] as? String == "config_reload",
      result["status"] as? String == "applied",
      (result["diagnostics"] as? [Any])?.isEmpty == true
    else { return false }
    return true
  }
}
