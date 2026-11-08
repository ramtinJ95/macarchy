import Foundation

/// Starts `executableURL` and returns without waiting for it or capturing its output. A nil
/// environment or standard stream is inherited from this process unchanged.
@discardableResult
package func launchDetachedProcess(
  _ executableURL: URL,
  arguments: [String],
  environment: [String: String]? = nil,
  standardInput: FileHandle? = nil,
  standardOutput: FileHandle? = nil,
  standardError: FileHandle? = nil
) throws -> Process {
  let process = Process()
  process.executableURL = executableURL
  process.arguments = arguments
  if let environment { process.environment = environment }
  if let standardInput { process.standardInput = standardInput }
  if let standardOutput { process.standardOutput = standardOutput }
  if let standardError { process.standardError = standardError }
  try process.run()
  return process
}
