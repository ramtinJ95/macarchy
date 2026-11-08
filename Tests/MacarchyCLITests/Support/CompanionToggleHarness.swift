import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

/// Runs one companion toggle event against recorders for SketchyBar and the launched command.
enum CompanionToggleHarness {
  static let accent = "0xffaabbcc"
  static let muted = "0xff585b70"
  static let stateRoot = URL(filePath: "/Users/me/.config/macarchy", directoryHint: .isDirectory)

  struct Run {
    let bar: [[String]]
    let launched: [[String]]
  }

  static func run(
    _ companion: SketchyBarClockCompanion, sender: String,
    muted: String? = CompanionToggleHarness.muted,
    read: @escaping () throws -> CompanionToggle
  ) throws -> Run {
    let bar = BarCalls()
    var launched: [[String]] = []
    try SketchyBarCompanionToggle(
      companion: companion, stateRoot: stateRoot,
      processRunner: ProcessRunner { request in
        #expect(request.executableURL == SketchyBarCoreRuntimeVerifier.controlURL)
        bar.value.withLock { $0.append(request.arguments) }
        return .init(terminationStatus: 0, output: "")
      },
      read: read, launch: { launched.append($0) }
    )
    .execute(sender: sender, accent: accent, muted: muted)
    return Run(bar: bar.value.withLock { $0 }, launched: launched)
  }

  private final class BarCalls: Sendable {
    let value = Mutex([[String]]())
  }
}
