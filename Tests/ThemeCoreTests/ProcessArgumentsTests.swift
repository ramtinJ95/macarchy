import Darwin
import Foundation
import Testing

@testable import ThemeCore

struct ProcessArgumentsTests {
  @Test func decodesOnlyArgvIncludingEmptyArguments() throws {
    let arguments = ["yabai", "-m", "", "config", "left_padding", "5"]
    #expect(try decodedProcessArguments(buffer(arguments)) == arguments)
  }

  @Test func invalidBuffersFailInsteadOfGuessingAProcessMode() {
    var badUTF8 = buffer(["yabai", "-m"], environment: false)
    badUTF8[badUTF8.count - 2] = 255
    let cases: [[UInt8]] = [
      [], [0, 0, 0, 0], buffer(["yabai"], count: 2, environment: false),
      Array(buffer(["yabai"], environment: false).dropLast()),
      badUTF8,
    ]
    for bytes in cases {
      #expect(throws: (any Error).self) { try decodedProcessArguments(bytes) }
    }
  }

  @Test func readsCurrentProcessArguments() throws {
    #expect(try processArguments(getpid()) == CommandLine.arguments)
  }

  private func buffer(
    _ arguments: [String], count: Int32? = nil, environment: Bool = true
  ) -> [UInt8] {
    var argc = count ?? Int32(arguments.count)
    var bytes = withUnsafeBytes(of: &argc) { Array($0) }
    bytes += Array("/resolved/executable".utf8) + [0, 0, 0]
    for argument in arguments { bytes += Array(argument.utf8) + [0] }
    if environment { bytes += Array("NOT_AN_ARGUMENT=-m".utf8) + [0] }
    return bytes
  }
}
