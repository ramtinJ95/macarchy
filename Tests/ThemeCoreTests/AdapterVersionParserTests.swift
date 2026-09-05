import Foundation
import Testing

@testable import ThemeCore

struct AdapterVersionParserTests {
  @Test
  func acceptsLeadingZeroesWhitespaceAndRepresentableComponents() {
    for (suffix, expected) in [
      (" 000.0151.000\n", [0, 151, 0]),
      ("\t1.2.3\r\n", [1, 2, 3]),
      ("\n1.2.3", [1, 2, 3]),
      ("\u{00a0}1.2.3\u{2003}", [1, 2, 3]),
      (" \(Int.max).0.0", [Int.max, 0, 0]),
    ] {
      #expect(CodexAdapter.parseVersion(" \tcodex-cli" + suffix) == expected)
      #expect(HerdrAdapter.parseVersion(" \therdr" + suffix) == expected)
    }
  }

  @Test
  func rejectsExtraTokensEmptyComponentsAndNonIntegerTriplets() {
    for suffix in [
      "", " ", " 1.2.3 extra", " 1.2.3\nwarning", "1.2.3",
      " .2.3", " 1..3", " 1.2.", " 1.2.3.4",
      " v1.2.3", " +1.2.3", " 1.-2.3", " 1.2.3+build",
      " 1.2.3-rc.1", " 1.two.3", " ١.2.3", " １.2.3", " ².2.3",
      " \(Int.max)0.2.3", " 1.\(Int.max)0.3", " 1.2.\(Int.max)0",
    ] {
      #expect(CodexAdapter.parseVersion("codex-cli" + suffix) == nil)
      #expect(HerdrAdapter.parseVersion("herdr" + suffix) == nil)
    }
    for output in ["", "1.2.3", "prefix codex-cli 1.2.3", "prefix herdr 1.2.3"] {
      #expect(CodexAdapter.parseVersion(output) == nil)
      #expect(HerdrAdapter.parseVersion(output) == nil)
    }
    #expect(CodexAdapter.parseVersion("herdr 1.2.3") == nil)
    #expect(HerdrAdapter.parseVersion("codex-cli 1.2.3") == nil)
    #expect(CodexAdapter.parseVersion("Codex-cli 1.2.3") == nil)
    #expect(HerdrAdapter.parseVersion("Herdr 1.2.3") == nil)
  }

  @Test(arguments: ["codex-cli", "herdr"])
  func supportedVersionNormalizesAndPreservesProviderErrors(label: String) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let executable = root.appending(path: label)
    let provider = label == "codex-cli" ? "Codex" : "Herdr"
    let minimum = label == "codex-cli" ? "0.151.0" : "0.8.0"

    func supportedVersion(_ output: String, status: Int32 = 0) throws -> String {
      let runner = ProcessRunner { request in
        #expect(
          request
            == ProcessRequest(
              executableURL: executable, arguments: ["--version"], timeout: 2))
        return ProcessResult(terminationStatus: status, output: output)
      }
      if label == "codex-cli" {
        return try CodexAdapter(
          root: root, configurationDirectoryURL: root, executableURL: executable,
          controlIsAvailable: { true }, processRunner: runner
        ).supportedVersion()
      }
      return try HerdrAdapter(
        root: root, configurationURL: root.appending(path: "config.toml"),
        executableURL: executable, controlIsAvailable: { true }, processRunner: runner
      ).supportedVersion()
    }

    #expect(try supportedVersion("\t\(label) 0001.0002.0003\n") == "1.2.3")
    for (output, status, expected) in [
      ("\(label) nonsense\n", Int32(0), "\(provider) returned an unparseable version"),
      ("\(label) 1.2.3\n", Int32(1), "\(provider) returned an unparseable version"),
      ("\(label) 0.0.0\n", Int32(1), "\(provider) returned an unparseable version"),
      ("\(label) 000.000.000\n", Int32(0), "unsupported"),
    ] {
      do {
        _ = try supportedVersion(output, status: status)
        Issue.record("Expected version rejection for \(output)")
      } catch {
        #expect(label == "codex-cli" ? error is CodexAdapterError : error is HerdrAdapterError)
        let description = String(describing: error)
        #expect(
          description
            == (expected == "unsupported"
              ? "\(provider) \(output) is unsupported; version \(minimum) or newer is required"
              : "\(expected): \(output)"))
      }
    }
  }
}
